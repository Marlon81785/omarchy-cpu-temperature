import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.marlon.cpu-temperature"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var samples: []
  property real currentTemperature: NaN
  property int currentTimestamp: 0
  property string selectedRange: "24h"
  property int updateIntervalSeconds: 2
  property string errorMessage: ""
  property string processOutput: ""
  property string processError: ""
  property int processExitCode: -1
  property bool processExited: false
  property bool outputDone: false
  property bool errorDone: false
  property bool sampling: false

  readonly property string helperPath: String(Qt.resolvedUrl("temperature-history.py")).replace(/^file:\/\//, "")
  readonly property string temperatureLabel: isNaN(currentTemperature)
    ? "CPU —"
    : "CPU " + Math.round(currentTemperature) + "°"
  readonly property string tooltipText: errorMessage !== ""
    ? errorMessage
    : "Current CPU temperature"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string rangeLabel: selectedRange === "live" ? "LIVE · 15 MIN"
    : selectedRange === "15m" ? "15 MINUTES"
    : selectedRange === "7d" ? "7 DAYS"
    : selectedRange === "30d" ? "30 DAYS" : "24 HOURS"
  readonly property real yAxisStep: temperatureAxisStep()
  readonly property real lowestTemperature: temperatureAxisBound(false)
  readonly property real highestTemperature: temperatureAxisBound(true)
  readonly property int chartWindowSeconds: selectedRange === "live"
    ? liveWindowSeconds
    : selectedRange === "15m" ? 15 * 60
    : selectedRange === "7d" ? 7 * 24 * 60 * 60
    : selectedRange === "30d" ? 30 * 24 * 60 * 60
    : 24 * 60 * 60
  readonly property int liveWindowSeconds: !samples || samples.length === 0
    ? updateIntervalSeconds * 10
    : Math.min(15 * 60, Math.max(updateIntervalSeconds * 10,
        currentTimestamp - Number(samples[0].timestamp)))
  readonly property var barIdentity: hostWidget || root

  function temperatureExtent(highest) {
    if (!samples || samples.length === 0) return isNaN(currentTemperature) ? 100 : currentTemperature
    var value = Number(samples[0].temperature)
    for (var i = 1; i < samples.length; i++) {
      var candidate = Number(samples[i].temperature)
      value = highest ? Math.max(value, candidate) : Math.min(value, candidate)
    }
    return value
  }

  function temperatureAxisStep() {
    var minimum = temperatureExtent(false)
    var maximum = temperatureExtent(true)
    var padding = Math.max(2, (maximum - minimum) * 0.1)
    var targetMinimum = minimum < 35 ? minimum - padding : Math.max(35, minimum - padding)
    var targetMaximum = maximum + padding
    var rawStep = Math.max(0.5, (targetMaximum - targetMinimum) / 4)
    var magnitude = Math.pow(10, Math.floor(Math.log(rawStep) / Math.LN10))
    var fraction = rawStep / magnitude
    var niceFraction = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10
    var step = niceFraction * magnitude
    var lower = minimum < 35
      ? Math.floor(targetMinimum / step) * step
      : Math.max(35, Math.floor(targetMinimum / step) * step)
    while (lower + step * 4 < targetMaximum) {
      var nextFraction = step / magnitude
      var nextNiceFraction = nextFraction < 1 ? 1
        : nextFraction < 2 ? 2
        : nextFraction < 2.5 ? 2.5
        : nextFraction < 5 ? 5 : 10
      if (nextNiceFraction <= nextFraction) {
        magnitude *= 10
        step = magnitude
      } else {
        step = nextNiceFraction * magnitude
      }
      lower = minimum < 35
        ? Math.floor(targetMinimum / step) * step
        : Math.max(35, Math.floor(targetMinimum / step) * step)
    }
    return step
  }

  function temperatureAxisBound(highest) {
    var minimum = temperatureExtent(false)
    var maximum = temperatureExtent(true)
    var step = yAxisStep
    var padding = Math.max(2, (maximum - minimum) * 0.1)
    var targetMinimum = minimum - padding
    var lower = minimum < 35
      ? Math.floor(targetMinimum / step) * step
      : Math.max(35, Math.floor(targetMinimum / step) * step)
    return highest ? lower + step * 4 : lower
  }

  function temperatureAxisLabel(index) {
    var value = highestTemperature - yAxisStep * index
    return (yAxisStep % 1 !== 0 ? value.toFixed(1) : value.toFixed(0)) + "°"
  }

  function formatAxisTime(seconds) {
    var totalSeconds = Math.max(0, Math.floor(seconds))
    var minutes = Math.floor(totalSeconds / 60)
    var remainingSeconds = totalSeconds % 60
    if (minutes >= 60) {
      var hours = Math.floor(minutes / 60)
      var remainingMinutes = minutes % 60
      return hours + "h" + (remainingMinutes > 0 ? String(remainingMinutes).padStart(2, "0") : "")
    }
    return minutes > 0 ? minutes + "m" + String(remainingSeconds).padStart(2, "0") : totalSeconds + "s"
  }

  function resetProcess() {
    processOutput = ""
    processError = ""
    processExitCode = -1
    processExited = false
    outputDone = false
    errorDone = false
  }

  function setRange(value) {
    if (selectedRange === value) return
    selectedRange = value
    refresh()
  }

  function setUpdateInterval(value) {
    var seconds = Number(value)
    if (!isFinite(seconds) || seconds < 1 || seconds > 10) return
    updateIntervalSeconds = seconds
    if (selectedRange === "live") refresh()
  }

  function refresh() {
    if (sampling || helperPath === "") return
    sampling = true
    errorMessage = ""
    resetProcess()
    sampleProcess.command = [
      "python3",
      helperPath,
      selectedRange,
      selectedRange === "live" ? "live" : "",
      String(updateIntervalSeconds)
    ]
    sampleProcess.running = true
  }

  function finishSample() {
    if (!processExited || !outputDone || !errorDone) return
    sampling = false
    if (processExitCode !== 0) {
      errorMessage = processError.trim() || processOutput.trim() || "Could not read CPU temperature."
      return
    }
    try {
      var result = JSON.parse(processOutput)
      if (!result || !result.current || !Array.isArray(result.history))
        throw new Error("Invalid response from the temperature reader.")
      var temperature = Number(result.current.temperature)
      if (!isFinite(temperature)) throw new Error("Invalid temperature reading.")
      currentTemperature = temperature
      currentTimestamp = Number(result.current.timestamp) || 0
      samples = result.history
      errorMessage = ""
    } catch (error) {
      errorMessage = String(error)
    }
  }

  function open() {
    root.controller.show()
    refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.updateIntervalSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: sampleProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.processOutput = String(text || "")
        root.outputDone = true
        root.finishSample()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.processError = String(text || "")
        root.errorDone = true
        root.finishSample()
      }
    }
    onExited: function(exitCode) {
      root.processExitCode = exitCode
      root.processExited = true
      root.finishSample()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - 44
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "CPU Temperature"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              text: root.errorMessage !== "" ? root.errorMessage
                : root.selectedRange === "live" ? "LIVE CAPTURE · EVERY " + root.updateIntervalSeconds + " SECONDS"
                : "HISTORY · " + root.rangeLabel
              color: root.errorMessage !== "" ? Color.urgent : Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(2)

          PanelSectionHeader {
            width: parent.width
            text: "RANGE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item {
            width: parent.width
            implicitHeight: rangeButtons.implicitHeight
            ButtonGroup {
              id: rangeButtons
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(2)
              options: [
                { value: "live", label: "LIVE" },
                { value: "15m", label: "15m" },
                { value: "24h", label: "24h" },
                { value: "7d", label: "7d" },
                { value: "30d", label: "30d" }
              ]
              value: root.selectedRange
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: false
              onChanged: function(value) { root.setRange(value) }
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(updateLabel.implicitHeight, intervalButtons.implicitHeight)

          PanelSectionHeader {
            id: updateLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "UPDATE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            id: intervalButtons
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            options: [
              { value: "1", label: "1s" },
              { value: "2", label: "2s" },
              { value: "5", label: "5s" },
              { value: "10", label: "10s" }
            ]
            value: String(root.updateIntervalSeconds)
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            focusable: false
            onChanged: function(value) { root.setUpdateInterval(value) }
          }
        }

        Row {
          width: parent.width

          Column {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "NOW"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
            Text {
              text: isNaN(root.currentTemperature) ? "— °C" : root.currentTemperature.toFixed(1) + " °C"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: Style.space(42)
            height: graph.height

            Repeater {
              model: 5

              Text {
                required property int index
                width: parent.width
                height: Style.space(16)
                y: 8 + (graph.height - 16) * index / 4 - height / 2
                text: root.temperatureAxisLabel(index)
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          Canvas {
            id: graph
            width: parent.width - Style.space(50)
            height: Style.space(170)

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)

              var top = 8
              var bottom = height - 8
              var range = root.highestTemperature - root.lowestTemperature
              ctx.lineWidth = 1
              ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18).toString()
              for (var grid = 0; grid < 5; grid++) {
                var y = top + (bottom - top) * grid / 4
                ctx.beginPath()
                ctx.moveTo(0, y)
                ctx.lineTo(width, y)
                ctx.stroke()
                var x = width * grid / 4
                ctx.beginPath()
                ctx.moveTo(x, top)
                ctx.lineTo(x, bottom)
                ctx.stroke()
              }

              if (!root.samples || root.samples.length === 0) return
              var now = Math.floor(Date.now() / 1000)
              var duration = root.chartWindowSeconds
              var start = now - duration
              var points = root.samples
              var coordinates = []
              for (var i = 0; i < points.length; i++) {
                var x = Math.max(0, Math.min(width,
                  (Number(points[i].timestamp) - start) / duration * width))
                var value = Number(points[i].temperature)
                var pointY = bottom - (value - root.lowestTemperature) / range * (bottom - top)
                coordinates.push({ x: x, y: pointY })
              }

              function traceSmoothLine() {
                ctx.moveTo(coordinates[0].x, coordinates[0].y)
                for (var pointIndex = 0; pointIndex < coordinates.length - 1; pointIndex++) {
                  var previous = coordinates[Math.max(0, pointIndex - 1)]
                  var first = coordinates[pointIndex]
                  var second = coordinates[pointIndex + 1]
                  var next = coordinates[Math.min(coordinates.length - 1, pointIndex + 2)]
                  var tension = 0.4 / 6
                  ctx.bezierCurveTo(
                    first.x + (second.x - previous.x) * tension,
                    first.y + (second.y - previous.y) * tension,
                    second.x - (next.x - first.x) * tension,
                    second.y - (next.y - first.y) * tension,
                    second.x,
                    second.y
                  )
                }
              }

              ctx.beginPath()
              traceSmoothLine()
              ctx.lineTo(coordinates[coordinates.length - 1].x, bottom)
              ctx.lineTo(coordinates[0].x, bottom)
              ctx.closePath()
              var gradient = ctx.createLinearGradient(0, top, 0, bottom)
              gradient.addColorStop(0, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3).toString())
              gradient.addColorStop(1, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.015).toString())
              ctx.fillStyle = gradient
              ctx.fill()

              ctx.beginPath()
              traceSmoothLine()
              ctx.strokeStyle = root.foreground.toString()
              ctx.lineWidth = 2
              ctx.lineJoin = "round"
              ctx.lineCap = "round"
              ctx.stroke()
            }

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections {
              target: root
              function onSamplesChanged() { graph.requestPaint() }
              function onLowestTemperatureChanged() { graph.requestPaint() }
              function onHighestTemperatureChanged() { graph.requestPaint() }
            }
          }
        }

        Row {
          width: parent.width
          spacing: 0

          Item { width: Style.space(50); height: 1 }

          Row {
            id: timeLabels
            width: parent.width - Style.space(50)
            spacing: 0

          Text {
            id: startLabel
            width: parent.width / 3
            text: "-" + root.formatAxisTime(root.chartWindowSeconds)
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width / 3
            horizontalAlignment: Text.AlignHCenter
            text: "-" + root.formatAxisTime(root.chartWindowSeconds / 2)
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: endLabel
            width: parent.width / 3
            horizontalAlignment: Text.AlignRight
            text: "now"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          }
        }
      }
    }
  }
}
