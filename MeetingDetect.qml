pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The OS-aware half of the plugin: one shared poller and one prompt.
//
// A bar widget exists once per monitor, so the poller and the prompt live in a
// singleton. When another application opens the microphone, a meeting is
// probably starting, so the prompt asks whether to record. No calendar, no
// account, no configuration: the signal is the OS's own capture stream. The
// detection itself is in bin/meeting-active; this file only decides when to
// ask.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  readonly property string helperPath:
    Qt.resolvedUrl("bin/meeting-active").toString().replace(/^file:\/\//, "")
  readonly property string startHelperPath:
    Qt.resolvedUrl("bin/start-recording").toString().replace(/^file:\/\//, "")
  readonly property string enginePath:
    Qt.resolvedUrl("bin/granola-engine").toString().replace(/^file:\/\//, "")

  // Set by the panel: use Granola's app instead of the local recorder.
  property bool useGranola: false

  property string recorderState: "off"
  property bool recorderAvailable: true

  property bool detected: false
  property string appLabel: ""
  property bool promptOpen: false
  property bool seen: false

  // Two polls in a row: a real call keeps the microphone open, while a blip
  // from an audio settings page should not open the prompt.
  property int streak: 0
  readonly property int confirmPolls: 2

  onRecorderStateChanged: root.evaluate()

  readonly property bool recordingBusy:
    recorderState === "recording" || recorderState === "paused"
      || recorderState === "stopping" || recorderState === "transcribing"

  readonly property var targetScreen: {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function poll() {
    if (!probe.running) probe.running = true
  }

  function apply(raw) {
    var active = false
    var label = ""
    try {
      var data = JSON.parse(String(raw || "{}"))
      active = !!(data && data.active)
      label = String((data && data.label) || "")
    } catch (e) {
      active = false
    }
    root.streak = active ? root.streak + 1 : 0
    root.detected = active && root.streak >= root.confirmPolls
    if (label !== "") root.appLabel = label
    root.evaluate()
  }

  function evaluate() {
    if (!root.detected) {
      root.promptOpen = false
      root.seen = false
      return
    }
    if (root.recordingBusy) {
      root.promptOpen = false
      return
    }
    if (!root.seen) {
      root.seen = true
      root.promptOpen = true
    }
  }

  function dismiss() {
    root.promptOpen = false
    root.seen = true
  }

  function startRecording() {
    recordProc.command = root.useGranola
      ? ["/usr/bin/env", "node", root.enginePath, "start"]
      : ["/usr/bin/env", "bash", root.startHelperPath]
    recordProc.running = true
    root.dismiss()
  }

  Process {
    id: probe
    command: ["/usr/bin/python3", root.helperPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  Process { id: recordProc; command: ["true"] }

  Process {
    id: whichProc
    running: true
    command: ["which", "omarchy-meeting-recorder"]
    onExited: function (exitCode) { root.recorderAvailable = exitCode === 0 }
  }

  Timer {
    interval: 30000
    running: !root.recorderAvailable
    repeat: true
    onTriggered: {
      if (!whichProc.running) {
        whichProc.running = false
        whichProc.running = true
      }
    }
  }

  Timer {
    id: pollTimer
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  PanelWindow {
    id: prompt
    screen: root.targetScreen
    visible: root.promptOpen && root.detected && root.targetScreen !== null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-meeting-notes-prompt"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    mask: Region { item: card }

    BorderSurface {
      id: card
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut + Style.space(8)
      anchors.rightMargin: Style.gapsOut + Style.space(8)
      width: Style.space(420)
      height: content.implicitHeight + Style.space(24)
      color: Commons.Color.popups.background
      borderSpec: Border.surfaceSpec(
        "popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.space(12)
      radius: Style.cornerRadius

      Column {
        id: content
        x: Style.space(12)
        y: Style.space(12)
        width: parent.width - Style.space(24)
        spacing: Style.space(6)

        Text {
          text: "MEETING DETECTED"
          textFormat: Text.PlainText
          color: Qt.darker(Commons.Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.appLabel !== ""
            ? root.appLabel + " is using the microphone"
            : "An app is using the microphone"
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.useGranola
            ? "Granola will transcribe and summarize this meeting."
            : "Start recording this meeting? Nothing leaves this machine."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Qt.darker(Commons.Color.popups.text, 1.25)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: !root.recorderAvailable
          text: "Meeting Recorder is not installed"
          textFormat: Text.PlainText
          color: Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: root.useGranola ? "Start Granola" : "Start recording"
            iconText: "\uF04B"
            foreground: Commons.Color.popups.text
            accent: Commons.Color.accent
            fontFamily: Style.font.family
            bordered: true
            enabled: root.recorderAvailable
            onClicked: root.startRecording()
          }

          Button {
            text: "Dismiss"
            foreground: Commons.Color.popups.text
            fontFamily: Style.font.family
            bordered: false
            onClicked: root.dismiss()
          }
        }
      }
    }
  }
}
