#!/usr/bin/env python3
import json
import math
import os
from pathlib import Path
import sys
import time


HISTORY_SECONDS = 30 * 24 * 60 * 60
LIVE_HISTORY_SECONDS = 30 * 60
MAX_GRAPH_POINTS = 1800
RANGE_SECONDS = {
    "live": LIVE_HISTORY_SECONDS,
    "30m": 30 * 60,
    "24h": 24 * 60 * 60,
    "7d": 7 * 24 * 60 * 60,
    "30d": 30 * 24 * 60 * 60,
}
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
STATE_DIR /= "omarchy/plugins/io.github.marlon.cpu-temperature"
HISTORY_FILE = STATE_DIR / "history.jsonl"
PRUNED_FILE = STATE_DIR / "last-pruned"
LIVE_HISTORY_FILE = STATE_DIR / "live-history.jsonl"
LIVE_PRUNED_FILE = STATE_DIR / "live-last-pruned"


def valid_temperature(value):
    return math.isfinite(value) and -40 <= value <= 150


def cpu_temperature():
    zones = sorted(Path("/sys/class/thermal").glob("thermal_zone*"))
    candidates = []
    for zone in zones:
        try:
            zone_type = (zone / "type").read_text().strip().lower()
            temperature = int((zone / "temp").read_text().strip()) / 1000
        except (OSError, ValueError):
            continue
        if not valid_temperature(temperature):
            continue
        if "x86_pkg_temp" in zone_type or ("cpu" in zone_type and "pkg" in zone_type):
            return round(temperature, 1)
        if "cpu" in zone_type:
            candidates.append(temperature)
    if candidates:
        return round(candidates[0], 1)

    hwmon_candidates = []
    for label_file in Path("/sys/class/hwmon").glob("hwmon*/temp*_label"):
        try:
            label = label_file.read_text().strip().lower()
            input_file = label_file.with_name(label_file.name.removesuffix("_label") + "_input")
            temperature = int(input_file.read_text().strip()) / 1000
        except (OSError, ValueError):
            continue
        if not valid_temperature(temperature):
            continue
        priority = next(
            (rank for rank, marker in enumerate(("package", "tctl", "cpu")) if marker in label),
            None,
        )
        if priority is not None:
            hwmon_candidates.append((priority, temperature))
    if hwmon_candidates:
        hwmon_candidates.sort()
        return round(hwmon_candidates[0][1], 1)

    raise RuntimeError("Nenhum sensor de temperatura da CPU foi encontrado em sysfs.")


def read_history(path):
    records = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as history_file:
        for line_number, line in enumerate(history_file, 1):
            try:
                record = json.loads(line)
                timestamp = int(record["timestamp"])
                temperature = float(record["temperature"])
            except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
                raise RuntimeError(f"Histórico inválido na linha {line_number}: {error}") from error
            if not valid_temperature(temperature):
                raise RuntimeError(f"Temperatura inválida na linha {line_number}.")
            records.append({"timestamp": timestamp, "temperature": temperature})
    return records


def prune_history(path, marker_path, records, now, retention):
    cutoff = now - retention
    records = [record for record in records if cutoff <= record["timestamp"] <= now]
    temporary_file = path.with_suffix(".tmp")
    with temporary_file.open("w", encoding="utf-8") as history_file:
        for record in records:
            history_file.write(json.dumps(record, separators=(",", ":")) + "\n")
    temporary_file.replace(path)
    marker_path.write_text(str(now), encoding="utf-8")
    return records


def graph_points(records):
    if len(records) <= MAX_GRAPH_POINTS:
        return records
    last_index = len(records) - 1
    return [records[round(i * last_index / (MAX_GRAPH_POINTS - 1))] for i in range(MAX_GRAPH_POINTS)]


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    now = int(time.time())
    temperature = cpu_temperature()
    selected_range = sys.argv[1] if len(sys.argv) > 1 else "24h"
    if selected_range not in RANGE_SECONDS:
        raise RuntimeError(f"Período de histórico inválido: {selected_range}")
    live_capture = len(sys.argv) > 2 and sys.argv[2] == "live"
    history_path = LIVE_HISTORY_FILE if selected_range in ("live", "30m") else HISTORY_FILE
    marker_path = LIVE_PRUNED_FILE if history_path == LIVE_HISTORY_FILE else PRUNED_FILE
    retention = LIVE_HISTORY_SECONDS if history_path == LIVE_HISTORY_FILE else HISTORY_SECONDS
    records = read_history(history_path)

    minimum_interval = 1 if live_capture else 9
    if (live_capture or history_path == HISTORY_FILE) and (
        not records or now - records[-1]["timestamp"] >= minimum_interval
    ):
        record = {"timestamp": now, "temperature": temperature}
        with history_path.open("a", encoding="utf-8") as history_file:
            history_file.write(json.dumps(record, separators=(",", ":")) + "\n")
        records.append(record)

    try:
        last_pruned = int(marker_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        last_pruned = 0
    if now - last_pruned >= 3600:
        records = prune_history(history_path, marker_path, records, now, retention)
    elif history_path == LIVE_HISTORY_FILE and (not records or now - records[0]["timestamp"] > retention):
        records = prune_history(history_path, marker_path, records, now, retention)

    cutoff = now - RANGE_SECONDS[selected_range]
    selected_records = [record for record in records if record["timestamp"] >= cutoff]
    print(json.dumps({
        "current": {"timestamp": now, "temperature": temperature},
        "history": graph_points(selected_records),
    }, separators=(",", ":")))


try:
    main()
except (OSError, RuntimeError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
