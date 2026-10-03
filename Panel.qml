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
    : "Temperatura atual da CPU"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string rangeLabel: selectedRange === "live" ? "AO VIVO · 30 MIN"
    : selectedRange === "30m" ? "30 MINUTOS"
    : selectedRange === "7d" ? "7 DIAS"
    : selectedRange === "30d" ? "30 DIAS" : "24 HORAS"
  readonly property int lowestTemperature: Math.max(0, Math.floor(temperatureExtent(false) - 5))
  readonly property int highestTemperature: Math.ceil(temperatureExtent(true) + 5)
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

  function refresh() {
    if (sampling || helperPath === "") return
    sampling = true
    errorMessage = ""
    resetProcess()
    sampleProcess.command = ["python3", helperPath, selectedRange, selectedRange === "live" ? "live" : ""]
    sampleProcess.running = true
  }

  function finishSample() {
    if (!processExited || !outputDone || !errorDone) return
    sampling = false
    if (processExitCode !== 0) {
      errorMessage = processError.trim() || processOutput.trim() || "Não foi possível ler a temperatura da CPU."
      return
    }
    try {
      var result = JSON.parse(processOutput)
      if (!result || !result.current || !Array.isArray(result.history))
        throw new Error("Resposta inválida do leitor de temperatura.")
      var temperature = Number(result.current.temperature)
      if (!isFinite(temperature)) throw new Error("Leitura de temperatura inválida.")
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
    interval: root.selectedRange === "live" ? 1000 : 10000
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
              text: "Temperatura da CPU"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              text: root.errorMessage !== "" ? root.errorMessage
                : root.selectedRange === "live" ? "CAPTURA AO VIVO · 1 AMOSTRA POR SEGUNDO"
                : "HISTÓRICO · " + root.rangeLabel
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

        ButtonGroup {
          id: rangeButtons
          width: parent.width
          options: [
            { value: "live", label: "AO VIVO" },
            { value: "30m", label: "30 MIN" },
            { value: "24h", label: "24 H" }
          ]
          value: root.selectedRange
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(value) { root.setRange(value) }
        }

        ButtonGroup {
          width: parent.width
          options: [
            { value: "7d", label: "7 DIAS" },
            { value: "30d", label: "30 DIAS" }
          ]
          value: root.selectedRange
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(value) { root.setRange(value) }
        }

        Row {
          width: parent.width

          Column {
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "AGORA"
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

          Column {
            width: Style.space(34)
            height: graph.height
            Text {
              text: root.highestTemperature + "°"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item { width: 1; height: parent.height - Style.space(24) }
            Text {
              text: root.lowestTemperature + "°"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Canvas {
            id: graph
            width: parent.width - Style.space(42)
            height: Style.space(170)

            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)

              var top = 8
              var bottom = height - 8
              var range = Math.max(10, root.highestTemperature - root.lowestTemperature)
              ctx.lineWidth = 1
              ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18).toString()
              for (var grid = 0; grid < 4; grid++) {
                var y = top + (bottom - top) * grid / 3
                ctx.beginPath()
                ctx.moveTo(0, y)
                ctx.lineTo(width, y)
                ctx.stroke()
              }

              if (!root.samples || root.samples.length === 0) return
              var now = Math.floor(Date.now() / 1000)
              var duration = root.selectedRange === "live" || root.selectedRange === "30m" ? 30 * 60
                : root.selectedRange === "7d" ? 7 * 24 * 60 * 60
                : root.selectedRange === "30d" ? 30 * 24 * 60 * 60
                : 24 * 60 * 60
              var start = now - duration
              var points = root.samples
              ctx.beginPath()
              for (var i = 0; i < points.length; i++) {
                var x = Math.max(0, Math.min(width,
                  (Number(points[i].timestamp) - start) / duration * width))
                var value = Number(points[i].temperature)
                var pointY = bottom - (value - root.lowestTemperature) / range * (bottom - top)
                if (i === 0) ctx.moveTo(x, pointY)
                else ctx.lineTo(x, pointY)
              }
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
          id: timeLabels
          width: parent.width
          Text {
            id: startLabel
            width: Style.space(60)
            text: root.selectedRange === "live" || root.selectedRange === "30m" ? "30m atrás"
              : root.selectedRange === "7d" ? "7d atrás"
              : root.selectedRange === "30d" ? "30d atrás" : "24h atrás"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Item { width: Math.max(0, timeLabels.width - startLabel.width - endLabel.width); height: 1 }
          Text {
            id: endLabel
            width: Style.space(40)
            horizontalAlignment: Text.AlignRight
            text: "agora"
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
