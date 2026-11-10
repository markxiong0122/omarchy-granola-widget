import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Meetings, in the bar: the recent ones on the left, the enhanced note on the
// right, and the recorder's start/stop controls on top. The text is whatever
// Meeting Recorder wrote; this panel only reads it. The one thing it creates is
// a request to the recorder, never a file of its own.
BarWidget {
  id: root
  moduleName: "markxiong.granola"

  // Touching the singleton is what creates it; it watches the microphone and
  // shows the prompt even while this popup is closed.
  readonly property var detectService: MeetingDetect


  // ---- Data -------------------------------------------------------------

  property var meetings: []
  property int selected: 0
  property bool loaded: false
  property string indexError: ""
  property string query: ""
  property bool askOpen: false

  property string askQuestion: ""
  property string askAnswer: ""
  property bool asking: false
  property string askError: ""
  property string noteText: ""

  // The pane already shows the meeting's title, date and kind, so drop the
  // file's own leading heading and meta line rather than printing them twice.
  readonly property string noteBody: {
    var lines = String(root.noteText || "").split("\n")
    var i = 0
    if (lines.length > 0 && /^#\s/.test(lines[0])) {
      i = 1
      while (i < lines.length && lines[i].trim() === "") i++
      if (i < lines.length && /^_.*_$/.test(lines[i].trim())) {
        i++
        while (i < lines.length && lines[i].trim() === "") i++
      }
    }
    return lines.slice(i).join("\n")
  }

  readonly property string paneText: {
    if (root.askError !== "") return root.askError
    if (root.asking) return "Thinking…"
    if (root.askAnswer !== "") return root.askAnswer
    return root.noteBody
  }

  // Qt's MarkdownText keeps the hashes and gives every heading the same
  // weight. Turning the note into a small, controlled HTML fragment makes the
  // pane easier to read: quieter headings, real bullets, and no raw markup.
  function escapeHtml(text) {
    return String(text || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  function inlineMarkdown(text) {
    var out = String(text || "")
    out = out.replace(/`([^`]+)`/g, "<code>$1</code>")
    out = out.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
    out = out.replace(/(^|[^\w])_([^_]+)_/g, "$1<i>$2</i>")
    out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
    return out
  }

  function markdownHtml(markdown) {
    var lines = String(markdown || "").split("\n")
    var html = []
    var i = 0
    while (i < lines.length) {
      var raw = lines[i]
      var line = raw.trim()
      if (line === "") { i++; continue }

      // Fenced code: keep it verbatim, monospaced, and dim.
      if (/^```/.test(line)) {
        var code = []
        i++
        while (i < lines.length && !/^```/.test(lines[i].trim())) {
          code.push(root.escapeHtml(lines[i]))
          i++
        }
        html.push('<p><code>' + code.join("<br>") + '</code></p>')
        i++
        continue
      }

      var heading = line.match(/^(#{1,4})\s+(.*)$/)
      if (heading) {
        var size = ["4", "3", "3", "2"][heading[1].length - 1] || "3"
        if (html.length > 0) html.push("<br>")
        html.push('<p><font size="' + size + '"><b>'
          + root.inlineMarkdown(root.escapeHtml(heading[2]))
          + '</b></font></p>')
        i++
        continue
      }

      var bullet = raw.match(/^(\s*)[-*]\s+(.*)$/)
      if (bullet) {
        var depth = Math.min(3, Math.floor(bullet[1].length / 2))
        var pad = ""
        for (var d = 0; d < depth; d++) pad += "&nbsp;&nbsp;&nbsp;&nbsp;"
        var body = bullet[2]
        var task = /^\[([ xX])\]\s+(.*)$/.exec(body)
        if (task) body = (task[1].trim() === "" ? "☐ " : "☑ ") + task[2]
        else body = "• " + body
        html.push('<p>' + pad + root.inlineMarkdown(root.escapeHtml(body)) + '</p>')
        i++
        continue
      }

      if (/^---+$/.test(line)) {
        html.push("<hr>")
        i++
        continue
      }

      if (/^>\s?/.test(line)) {
        html.push('<p><i>' + root.inlineMarkdown(root.escapeHtml(line.replace(/^>\s?/, ""))) + '</i></p>')
        i++
        continue
      }

      html.push("<p>" + root.inlineMarkdown(root.escapeHtml(line)) + "</p>")
      i++
    }
    return '<html><body style="line-height:125%">' + html.join("") + "</body></html>"
  }

  readonly property string noteHtml: root.markdownHtml(root.paneText)

  property string meetingsDir: setting("meetingDir", "~/Documents/Meetings")
  property bool granolaSource: setting("granolaSource", true)
  readonly property string helperPath:
    Qt.resolvedUrl("bin/meeting-notes-index").toString().replace(/^file:\/\//, "")
  readonly property string startHelperPath:
    Qt.resolvedUrl("bin/start-recording").toString().replace(/^file:\/\//, "")
  readonly property string configHome:
    Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string granolaTokenPath:
    root.configHome + "/omarchy-meeting-notes/granola-oauth.json"
  readonly property string granolaAuthHelperPath:
    Qt.resolvedUrl("bin/granola-oauth").toString().replace(/^file:\/\//, "")
  property bool granolaConnected: false

  // Device-code connection: show the code, open the page, wait for approval.
  property bool granolaAuthOpen: false
  property bool granolaConnecting: false
  property string granolaAuthUrl: ""
  property string granolaAuthCode: ""
  property string granolaAuthStatus: ""

  onGranolaConnectedChanged: if (root.granolaConnected) root.refresh()

  readonly property var selectedMeeting:
    meetings.length > 0 && selected >= 0 && selected < meetings.length ? meetings[selected] : null

  // ---- Recorder state ---------------------------------------------------

  property string recorderState: "off"
  property int elapsed: 0
  property real progress: 0
  property string recorderTitle: ""
  property bool recorderAvailable: false

  // Granola as the recording engine: the official app does the capture,
  // transcription and summary, and we show its Nub and read the note via MCP.
  property bool granolaInstalled: false
  readonly property string granolaAppPath:
    Quickshell.env("HOME") + "/.local/share/omarchy-meeting-notes/granola/granola.sh"
  readonly property string granolaEnginePath:
    Qt.resolvedUrl("bin/granola-engine").toString().replace(/^file:\/\//, "")
  readonly property bool useGranola:
    root.granolaInstalled && setting("engine", "granola") === "granola"
  readonly property bool captureReady:
    root.useGranola ? root.granolaInstalled : root.recorderAvailable
  property double granolaStartedAt: 0
  property string granolaDocumentId: ""

  onUseGranolaChanged: MeetingDetect.useGranola = root.useGranola
  Component.onCompleted: MeetingDetect.useGranola = root.useGranola

  readonly property bool capturing:
    recorderState === "recording" || recorderState === "paused" || recorderState === "stopping"
  readonly property bool busy:
    recorderState === "stopping" || recorderState === "transcribing"
  readonly property bool paused: recorderState === "paused"

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  // ---- Panel lifecycle --------------------------------------------------

  property bool opened: false
  readonly property bool popoutSwitchClosing: false

  function refresh() {
    if (indexProc.running) return
    if (root.meetings.length === 0) root.loaded = false
    var args = [
      "/usr/bin/python3", root.helperPath,
      "--query", root.query,
      root.meetingsDir, "40"
    ]
    if (root.granolaSource) args.push("--granola")
    indexProc.command = args
    indexProc.running = true
  }

  function open() {
    root.opened = true
    root.refresh()
  }

  function close() {
    root.opened = false
  }

  function togglePanel() {
    root.opened ? root.close() : root.open()
  }

  function closeForPopoutSwitch() {
    root.close()
  }

  function setQuery(text) {
    root.query = String(text || "")
    searchDebounce.restart()
  }

  function focusSearch() {
    if (!searchField) return
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function focusAsk() {
    if (!root.selectedMeeting || !root.recorderAvailable) return
    root.askOpen = true
    root.askAnswer = ""
    root.askError = ""
    if (askField) askField.forceActiveFocus()
  }

  function closeAsk() {
    root.askOpen = false
    root.askQuestion = ""
    root.askAnswer = ""
    root.askError = ""
    if (askField) askField.focus = false
  }

  function startGranolaAuth() {
    if (root.granolaConnecting) return
    root.granolaAuthOpen = true
    root.granolaConnecting = true
    root.granolaAuthUrl = ""
    root.granolaAuthCode = ""
    root.granolaAuthStatus = "Starting…"
    granolaAuthProc.command = [
      "/usr/bin/python3", root.granolaAuthHelperPath, "--connect"
    ]
    granolaAuthProc.running = true
  }

  function cancelGranolaAuth() {
    root.granolaConnecting = false
    root.granolaAuthOpen = false
    root.granolaAuthStatus = ""
    if (granolaAuthProc.running) granolaAuthProc.signal(15)
  }

  function handleGranolaAuthLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    if (/^https?:\/\//.test(text)) {
      root.granolaAuthUrl = text
      root.granolaAuthStatus = "Approve it in the browser"
    } else if (text.indexOf("Code:") === 0) {
      root.granolaAuthCode = text.slice(5).trim()
    } else if (text.indexOf("Waiting") === 0) {
      root.granolaAuthStatus = "Waiting for approval…"
    } else if (text.indexOf("Connected") === 0) {
      root.granolaConnected = true
      root.granolaConnecting = false
      root.granolaAuthOpen = false
      root.granolaAuthStatus = ""
    }
  }

  function updateGranolaToken(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      root.granolaConnected = !!(data && (data.refresh_token || data.access_token))
    } catch (e) {
      root.granolaConnected = false
    }
  }

  function openGranolaAuthPage() {
    if (root.granolaAuthUrl === "") return
    if (root.bar) root.bar.run("xdg-open " + root.bar.shellQuote(root.granolaAuthUrl))
    else Qt.openUrlExternally(root.granolaAuthUrl)
  }

  function submitAsk() {
    var question = String(root.askQuestion || "").trim()
    if (question === "" || !root.selectedMeeting || root.asking) return
    root.asking = true
    root.askAnswer = ""
    root.askError = ""

    var note = root.selectedMeeting.note_path
      || root.selectedMeeting.transcript_path || ""
    var transcript = root.selectedMeeting.transcript_path || ""
    var prompt = "You are answering a question about a meeting. Use only the note and "
      + "transcript below. If the answer is not in them, say so plainly. Answer "
      + "concisely in Markdown, with no preamble.\n\nQuestion: " + question

    askProc.command = [
      "bash", "-c",
      'if [ -n "$2" ] && [ "$1" != "$2" ]; then cat "$1" "$2"; else cat "$1"; fi'
        + ' | omarchy-meeting-recorder ask "$3"',
      "_", note, transcript, prompt
    ]
    askProc.running = true
  }

  function finishAsk(text) {
    root.asking = false
    var answer = String(text || "").trim()
    if (answer !== "") root.askAnswer = answer
    else if (root.askError === "") root.askError = "The agent returned no answer."
  }

  // ---- Selection --------------------------------------------------------

  function select(index) {
    if (index < 0 || index >= root.meetings.length) return
    root.selected = index
    root.scrollListTo(index)
    noteScroll.contentY = 0
  }

  function scrollListTo(index) {
    var row = Style.space(48) + Style.space(2)
    var top = index * row
    if (top < listScroll.contentY) listScroll.contentY = top
    else if (top + row > listScroll.contentY + listScroll.height)
      listScroll.contentY = top + row - listScroll.height
  }

  function moveSelection(delta) {
    if (root.meetings.length === 0) return
    root.select(Math.max(0, Math.min(root.meetings.length - 1, root.selected + delta)))
  }

  function parseIndex(raw) {
    var next
    try {
      next = JSON.parse(String(raw || "[]"))
    } catch (e) {
      next = []
      root.indexError = "Could not read the meeting list"
    }
    if (!Array.isArray(next)) next = []

    var currentKey = root.selectedMeeting ? root.selectedMeeting.key : ""
    root.meetings = next

    var index = 0
    for (var i = 0; i < next.length; i++) {
      if (next[i] && next[i].key === currentKey) {
        index = i
        break
      }
    }
    root.selected = Math.min(index, Math.max(0, next.length - 1))
    root.loaded = true
  }

  function applyState(line) {
    if (line.length > 4096) return
    var data
    try {
      data = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!data || typeof data.state !== "string") return

    var previous = root.recorderState
    root.recorderState = /^(off|idle|recording|paused|stopping|transcribing|done)$/.test(data.state)
      ? data.state
      : "off"
    MeetingDetect.recorderState = root.recorderState
    root.elapsed = Math.max(0, Math.floor(Number(data.elapsed) || 0))
    root.progress = Math.max(0, Math.min(1, Number(data.progress) || 0))
    root.recorderTitle = typeof data.title === "string" ? data.title.slice(0, 200) : ""

    // A finished transcript changes the note on disk; pick it up without
    // waiting for the next poll.
    if ((previous === "transcribing" || previous === "stopping") &&
        (root.recorderState === "done" || root.recorderState === "off")) {
      root.refresh()
    }
  }

  function applyGranolaState(line) {
    var data
    try {
      data = JSON.parse(String(line || "{}"))
    } catch (e) {
      return
    }
    var recording = !!(data && data.transcribing)
    var previous = root.recorderState
    if (recording) {
      if (root.recorderState !== "recording") {
        root.recorderState = "recording"
        root.granolaStartedAt = Date.now() / 1000
        root.granolaDocumentId = String(data.id || "")
      }
      root.recorderTitle = String(data.title || "Granola note").slice(0, 200)
    } else {
      root.recorderState = "off"
      root.elapsed = 0
      root.granolaStartedAt = 0
      root.granolaDocumentId = ""
      if (previous === "stopping") root.refresh()
    }
    MeetingDetect.recorderState = root.recorderState
  }

  // ---- Recording controls ----------------------------------------------

  function toggleRecord() {
    if (root.busy || !root.captureReady) return
    if (root.useGranola) {
      if (root.capturing) {
        root.recorderState = "stopping"
        granolaStopProc.running = true
      } else {
        granolaStartProc.running = true
      }
      return
    }
    if (root.capturing) {
      stopProc.running = true
    } else {
      // The helper starts the recording and shrinks the window to the strip.
      // It detaches `start`, which stays alive as the app for the session.
      startProc.command = ["/usr/bin/env", "bash", root.startHelperPath]
      startProc.running = true
    }
  }

  function togglePause() {
    if (root.useGranola) return
    if (root.recorderState === "recording" || root.recorderState === "paused")
      pauseProc.running = true
  }

  function openMeeting() {
    var meeting = root.selectedMeeting
    if (!meeting) return
    if (meeting.source === "granola") {
      root.openGranola()
      return
    }
    openProc.command = [
      "bash", "-c",
      'omarchy-meeting-recorder "$1" >/dev/null 2>&1 &',
      "_", meeting.dir
    ]
    openProc.running = true
    root.close()
  }

  function openGranola() {
    var meeting = root.selectedMeeting
    if (!meeting || String(meeting.web_url || "") === "") return
    if (root.bar) root.bar.run("xdg-open " + root.bar.shellQuote(meeting.web_url))
    else Qt.openUrlExternally(meeting.web_url)
    root.close()
  }

  function openFolder() {
    var meeting = root.selectedMeeting
    if (!meeting || meeting.source === "granola" || String(meeting.dir || "") === "") return
    if (root.bar) root.bar.run("xdg-open " + root.bar.shellQuote(meeting.dir))
    else Qt.openUrlExternally("file://" + encodeURI(meeting.dir))
  }

  // ---- Formatting -------------------------------------------------------

  function clock(seconds) {
    var h = Math.floor(seconds / 3600)
    var m = Math.floor(seconds / 60) % 60
    var s = seconds % 60
    var mm = (m < 10 ? "0" : "") + m
    var ss = (s < 10 ? "0" : "") + s
    return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
  }

  readonly property string statusText: {
    if (recorderState === "recording") return clock(elapsed)
    if (recorderState === "paused") return "paused " + clock(elapsed)
    if (recorderState === "stopping") return "saving…"
    if (recorderState === "transcribing") return "transcribing " + Math.round(progress * 100) + "%"
    return ""
  }

  function formatDate(seconds) {
    if (!seconds) return ""
    return Qt.formatDateTime(new Date(seconds * 1000), "ddd d MMM · h:mm AP")
  }

  function formatDuration(seconds) {
    var n = Number(seconds) || 0
    if (n <= 0) return ""
    if (n < 90) return n + "s"
    var minutes = Math.round(n / 60)
    if (minutes < 60) return minutes + " min"
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
  }

  readonly property string noteKindLabel: {
    if (!selectedMeeting) return ""
    if (selectedMeeting.note_kind === "enhanced") return "Enhanced notes"
    if (selectedMeeting.note_kind === "granola") return "Granola note"
    if (selectedMeeting.note_kind === "transcript") return "Transcript"
    return "No text yet"
  }

  // ---- Processes --------------------------------------------------------

  Process {
    id: indexProc
    command: ["/usr/bin/python3", root.helperPath, root.meetingsDir, "40"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseIndex(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "") root.indexError = String(text).trim()
      }
    }
  }

  // The recorder is a separate package, so the widget has to survive it being
  // absent: probe for the binary, and let the probe retry until it appears.
  Process {
    id: whichProc
    running: true
    command: ["which", "omarchy-meeting-recorder"]
    onExited: function (exitCode) {
      root.recorderAvailable = exitCode === 0
    }
  }

  Timer {
    id: availableRetry
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

  // The watches only run while the panel is open: a Node process per bar
  // widget is exactly the idle cost this integration is trying to avoid.
  Process {
    id: recorderWatch
    running: root.recorderAvailable && !root.useGranola && root.opened
    command: ["omarchy-meeting-recorder", "watch"]
    stdout: SplitParser {
      onRead: function (line) { root.applyState(line) }
    }
    onExited: if (root.recorderAvailable && !root.useGranola && root.opened)
      watchRetry.restart()
  }

  Process {
    id: granolaWatch
    running: root.useGranola && root.opened
    command: ["/usr/bin/env", "node", root.granolaEnginePath, "watch"]
    stdout: SplitParser {
      onRead: function (line) { root.applyGranolaState(line) }
    }
    onExited: if (root.useGranola && root.opened) granolaWatchRetry.restart()
  }

  Timer {
    id: granolaWatchRetry
    interval: 10000
    onTriggered: if (root.useGranola && root.opened && !granolaWatch.running)
      granolaWatch.running = true
  }

  Timer {
    interval: 1000
    running: root.useGranola && root.recorderState === "recording"
    repeat: true
    onTriggered: root.elapsed = Math.max(0,
      Math.floor(Date.now() / 1000 - root.granolaStartedAt))
  }

  Process {
    id: granolaWhich
    running: true
    command: ["test", "-x", root.granolaAppPath]
    onExited: function (exitCode) { root.granolaInstalled = exitCode === 0 }
  }

  Timer {
    id: watchRetry
    interval: 10000
    onTriggered: if (root.recorderAvailable && !recorderWatch.running) recorderWatch.running = true
  }

  Timer {
    id: searchDebounce
    interval: 250
    onTriggered: root.refresh()
  }

  Timer {
    interval: 5000
    running: root.granolaSource && !root.granolaConnected
    repeat: true
    onTriggered: granolaTokenFile.reload()
  }

  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process { id: startProc; command: ["true"] }
  Process { id: stopProc; command: ["omarchy-meeting-recorder", "stop"] }
  Process { id: pauseProc; command: ["omarchy-meeting-recorder", "pause"] }
  Process { id: openProc; command: ["true"] }
  Process {
    id: granolaStartProc
    command: ["/usr/bin/env", "node", root.granolaEnginePath, "start"]
  }
  Process {
    id: granolaStopProc
    command: ["/usr/bin/env", "node", root.granolaEnginePath, "stop"]
  }

  Process {
    id: askProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishAsk(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.askError = message
      }
    }
    onExited: function (exitCode) {
      root.asking = false
      if (exitCode !== 0 && root.askError === "") root.askError = "The agent could not answer."
    }
  }

  Process {
    id: granolaAuthProc
    stdout: SplitParser {
      onRead: function (line) { root.handleGranolaAuthLine(line) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "" && root.granolaAuthOpen) root.granolaAuthStatus = message
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.granolaConnected = true
        root.granolaConnecting = false
        root.granolaAuthOpen = false
        root.granolaAuthStatus = ""
        root.refresh()
      } else if (root.granolaAuthOpen && !root.granolaConnected) {
        root.granolaConnecting = false
        if (root.granolaAuthStatus === "" || root.granolaAuthStatus === "Starting…"
            || root.granolaAuthStatus === "Waiting for approval…")
          root.granolaAuthStatus = "Could not connect"
      }
    }
  }

  FileView {
    id: granolaTokenFile
    path: root.granolaTokenPath
    watchChanges: true
    printErrors: false
    onLoaded: root.updateGranolaToken(text())
    onFileChanged: reload()
    onLoadFailed: root.updateGranolaToken("")
  }

  FileView {
    id: noteFile
    path: root.selectedMeeting && root.selectedMeeting.note_path
      ? root.selectedMeeting.note_path
      : "/dev/null"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.noteText = String(text() || "")
      noteScroll.contentY = 0
    }
    onFileChanged: reload()
    onLoadFailed: root.noteText = ""
  }

  // ---- Bar button -------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF0F6"
    tooltipText: root.recorderTitle !== "" ? root.recorderTitle : "Meeting notes"
    onPressed: function (b) {
      if (b === Qt.RightButton) root.openFolder()
      else root.togglePanel()
    }
  }

  Rectangle {
    visible: root.capturing || root.busy
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(5)
    anchors.rightMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: root.paused ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.55) : root.urgent
  }

  // ---- Panel ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(880))
    contentHeight: panel.fittedContentHeight(Style.space(580))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || askField.activeFocus
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onCloseRequested: root.granolaAuthOpen ? root.cancelGranolaAuth() : root.close()
      onActivateRequested: root.openMeeting()
      onTextKey: function (t) {
        if (t === "/") root.focusSearch()
        else if (t === "?") root.focusAsk()
        else if (t === "r" || t === "R") root.toggleRecord()
        else if (t === "p" || t === "P") root.togglePause()
        else if (t === "o" || t === "O") root.openFolder()
        else if (t === "f" || t === "F") root.refresh()
        else if ((t === "c" || t === "C")
          && root.granolaSource && !root.granolaConnected) root.startGranolaAuth()
      }

      Item {
        anchors.fill: parent

        // Header: title, live state, start/stop.
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(Style.space(30), recordButton.implicitHeight)

          PanelSectionHeader {
            id: headerLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "MEETINGS"
            foreground: root.fg
            fontFamily: root.ff
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              id: statusText
              anchors.verticalCenter: parent.verticalCenter
              visible: root.statusText !== ""
              text: root.statusText
              textFormat: Text.PlainText
              color: root.paused ? Qt.darker(root.fg, 1.5) : root.fg
              font.family: root.ff
              font.pixelSize: Style.font.body
              font.features: { "tnum": 1 }
            }

            PanelActionButton {
              id: pauseButton
              visible: root.capturing && !root.useGranola
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.paused ? "\uF04B" : "\uF04C"
              tooltipText: root.paused ? "Resume" : "Pause"
              foreground: root.fg
              hoverColor: root.accent
              fontFamily: root.ff
              onClicked: root.togglePause()
            }

            Button {
              id: recordButton
              anchors.verticalCenter: parent.verticalCenter
              text: root.capturing ? "Stop" : "Record"
              iconText: root.capturing ? "\uF04D" : "\uF04B"
              foreground: root.fg
              accent: root.capturing ? root.urgent : root.accent
              fontFamily: root.ff
              bordered: true
              enabled: root.captureReady && !root.busy
              onClicked: root.toggleRecord()
            }
          }
        }

        // Footer: the file is a folder first, so both ways out are one click.
        Item {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Math.max(openButton.implicitHeight, hint.implicitHeight)

          Row {
            id: footerButtons
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              id: connectButton
              visible: root.granolaSource && !root.granolaConnected && !root.granolaAuthOpen
              text: "Connect Granola"
              iconText: "\uF0C1"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.ff
              bordered: true
              onClicked: root.startGranolaAuth()
            }

            Button {
              id: askButton
              text: "Ask"
              iconText: "\uF128"
              foreground: root.fg
              fontFamily: root.ff
              bordered: true
              enabled: root.selectedMeeting !== null && root.recorderAvailable
                && !root.granolaAuthOpen
              onClicked: root.focusAsk()
            }

            Button {
              id: openButton
              text: root.selectedMeeting && root.selectedMeeting.source === "granola"
                ? "Open in Granola" : "Open in Recorder"
              iconText: "\uF08E"
              foreground: root.fg
              fontFamily: root.ff
              bordered: true
              enabled: root.selectedMeeting !== null && !root.granolaAuthOpen
                && (root.selectedMeeting.source === "granola"
                  ? String(root.selectedMeeting.web_url || "") !== ""
                  : root.recorderAvailable)
              onClicked: root.openMeeting()
            }

            Button {
              visible: root.selectedMeeting === null || root.selectedMeeting.source !== "granola"
              text: "Open folder"
              iconText: "\uF07C"
              foreground: root.fg
              fontFamily: root.ff
              bordered: true
              enabled: root.selectedMeeting !== null && !root.granolaAuthOpen
              onClicked: root.openFolder()
            }
          }

          Text {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, footer.width - footerButtons.width - Style.space(16))
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: root.recorderAvailable
              ? "↑↓ select · enter open · / search · ? ask · r record · esc close"
              : "Install: omarchy pkg add omarchy-meeting-recorder-bin"
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 1.7)
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        // Body: meetings on the left, the note on the right.
        Item {
          id: body
          anchors.top: header.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.space(10)

          // --- List
          Item {
            id: listPane
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(232)

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              placeholderText: "Search"
              foreground: root.fg
              accent: root.accent
              font.family: root.ff
              font.pixelSize: Style.font.body
              text: root.query
              onTextChanged: if (root.query !== text) root.setQuery(text)
              Keys.onEscapePressed: function (event) {
                if (searchField.text !== "") {
                  searchField.text = ""
                  root.setQuery("")
                } else {
                  searchField.focus = false
                }
                event.accepted = true
              }
              Keys.onReturnPressed: function (event) {
                searchField.focus = false
                event.accepted = true
              }
            }

            PanelSectionHeader {
              id: listHeader
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: searchField.bottom
              anchors.topMargin: Style.space(8)
              text: (root.query !== "" ? "RESULTS" : "RECENT")
                + (root.loaded ? " · " + root.meetings.length : "")
              foreground: root.fg
              fontFamily: root.ff
            }

            Flickable {
              id: listScroll
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.top: listHeader.bottom
              anchors.topMargin: Style.space(4)
              anchors.bottom: parent.bottom
              contentHeight: listColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: listColumn
                width: listScroll.width
                spacing: Style.space(2)

                Repeater {
                  model: root.meetings

                  CursorSurface {
                    required property var modelData
                    required property int index

                    width: listColumn.width
                    height: Style.space(48)
                    hasCursor: index === root.selected
                    foreground: root.fg
                    accent: root.accent

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.select(index)
                      onDoubleClicked: root.openMeeting()
                    }

                    Rectangle {
                      visible: modelData.source === "granola"
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(2)
                      color: root.accent
                      opacity: index === root.selected ? 0.95 : 0.55
                    }

                    Column {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      anchors.topMargin: Style.space(5)
                      anchors.bottomMargin: Style.space(5)
                      spacing: Style.space(1)

                      Text {
                        width: parent.width
                        text: modelData.title
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.fg
                        font.family: root.ff
                        font.pixelSize: Style.font.bodySmall
                        font.bold: index === root.selected
                      }

                      Text {
                        width: parent.width
                        text: root.query !== "" && modelData.snippet
                          ? modelData.snippet
                          : root.formatDate(modelData.started_at)
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: Qt.darker(root.fg, 1.55)
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }

            Rectangle {
              visible: listScroll.contentHeight > listScroll.height + 1
              anchors.right: parent.right
              anchors.top: listScroll.top
              anchors.bottom: listScroll.bottom
              width: Style.space(2)
              radius: width / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

              Rectangle {
                width: parent.width
                radius: parent.radius
                height: Math.max(Style.space(16),
                  parent.height * listScroll.visibleArea.heightRatio)
                y: (parent.height - height) * listScroll.visibleArea.yPosition
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.28)
              }
            }

            Column {
              visible: !root.loaded || root.meetings.length === 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: listHeader.bottom
              anchors.topMargin: Style.space(24)
              spacing: Style.space(6)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\uF0F6"
                color: Qt.darker(root.fg, 2.0)
                font.family: root.ff
                font.pixelSize: Style.space(24)
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: !root.loaded
                  ? "Loading meetings…"
                  : (root.indexError !== ""
                    ? root.indexError
                    : (root.query !== "" ? "No matches" : "No meetings yet"))
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.fg, 1.7)
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }

              Button {
                visible: root.granolaSource && !root.granolaConnected && !root.granolaAuthOpen
                width: parent.width
                text: "Connect Granola"
                iconText: "\uF0C1"
                foreground: root.fg
                accent: root.accent
                fontFamily: root.ff
                bordered: true
                onClicked: root.startGranolaAuth()
              }

            }
          }

          // --- Note
          Item {
            id: notePane
            anchors.left: listPane.right
            anchors.leftMargin: Style.space(12)
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            Text {
              id: noteTitle
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              text: root.selectedMeeting
                ? root.selectedMeeting.title
                : (root.loaded ? "No meeting selected" : "Loading…")
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Row {
              id: noteMeta
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: noteTitle.bottom
              anchors.topMargin: Style.space(3)
              spacing: Style.space(8)

              Text {
                text: root.selectedMeeting
                  ? root.formatDate(root.selectedMeeting.started_at)
                    + (root.formatDuration(root.selectedMeeting.duration_secs) !== ""
                      ? " · " + root.formatDuration(root.selectedMeeting.duration_secs)
                      : "")
                  : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                width: Math.max(0, parent.width - kindLabel.implicitWidth - parent.spacing)
                color: Qt.darker(root.fg, 1.5)
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }

              Text {
                id: kindLabel
                text: root.noteKindLabel
                textFormat: Text.PlainText
                color: root.selectedMeeting && root.selectedMeeting.note_kind === "transcript"
                  ? Qt.darker(root.fg, 1.5)
                  : root.accent
                font.family: root.ff
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: noteRule
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: noteMeta.bottom
              anchors.topMargin: Style.space(8)
              height: Math.max(1, Style.space(1))
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            }

            Flickable {
              id: noteScroll
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.top: noteRule.bottom
              anchors.topMargin: Style.space(8)
              anchors.bottom: askBar.top
              contentWidth: width
              contentHeight: noteView.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick

              TextEdit {
                id: noteView
                width: noteScroll.width
                height: Math.max(contentHeight, 1)
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.RichText
                text: root.noteHtml
                color: root.fg
                selectionColor: root.accent
                selectedTextColor: Commons.Color.background
                font.family: root.ff
                font.pixelSize: Style.font.subtitle
                wrapMode: TextEdit.Wrap
                onLinkActivated: function (link) {
                  if (root.bar) root.bar.run("xdg-open " + root.bar.shellQuote(link))
                  else Qt.openUrlExternally(link)
                }
              }
            }

            Rectangle {
              id: noteScrollTrack
              visible: noteScroll.contentHeight > noteScroll.height + 1
              anchors.right: parent.right
              anchors.top: noteScroll.top
              anchors.bottom: noteScroll.bottom
              width: Style.space(3)
              radius: width / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

              Rectangle {
                width: parent.width
                radius: parent.radius
                height: Math.max(Style.space(18),
                  parent.height * noteScroll.visibleArea.heightRatio)
                y: (parent.height - height) * noteScroll.visibleArea.yPosition
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.30)
              }
            }

            Column {
              visible: root.paneText.trim() === ""
              anchors.centerIn: parent
              width: Math.min(parent.width - Style.space(48), Style.space(360))
              spacing: Style.space(8)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\uF0F6"
                color: Qt.darker(root.fg, 2.0)
                font.family: root.ff
                font.pixelSize: Style.space(30)
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.selectedMeeting
                  ? (root.selectedMeeting.note_kind === "none"
                    ? "The recorder is still working, or this meeting has no text yet."
                    : "Loading…")
                  : (!root.loaded ? "Fetching local and Granola notes…"
                    : (root.query !== "" ? "No matches for this search."
                      : "Choose a meeting, or press / to search."))
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.fg, 1.7)
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }
            }

            Item {
              id: askBar
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              visible: root.askOpen
              height: root.askOpen ? Style.space(34) : 0

              TextField {
                id: askField
                anchors.fill: parent
                placeholderText: root.askError !== ""
                  ? root.askError
                  : "Ask about this meeting"
                foreground: root.fg
                accent: root.accent
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
                text: root.askQuestion
                enabled: !root.asking
                onTextChanged: root.askQuestion = text
                Keys.onReturnPressed: function (event) {
                  root.submitAsk()
                  event.accepted = true
                }
                Keys.onEscapePressed: function (event) {
                  root.closeAsk()
                  event.accepted = true
                }
              }
            }

            Rectangle {
              id: granolaAuthPane
              visible: root.granolaAuthOpen
              anchors.fill: parent
              color: Commons.Color.popups.background
              z: 20

              Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - Style.space(48), Style.space(420))
                spacing: Style.space(10)

                PanelSectionHeader {
                  text: "CONNECT GRANOLA"
                  foreground: root.fg
                  fontFamily: root.ff
                }

                Text {
                  width: parent.width
                  text: "Sign in to Granola"
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: root.ff
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: "Approve Meeting Notes for Omarchy in the browser. "
                    + "Your notes are read-only; nothing is written back to Granola."
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: Qt.darker(root.fg, 1.35)
                  font.family: root.ff
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: root.granolaAuthCode !== ""
                  width: parent.width
                  text: root.granolaAuthCode
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  color: root.accent
                  font.family: root.ff
                  font.pixelSize: Style.font.display
                  font.bold: true
                  font.letterSpacing: 2
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Button {
                    text: "Open Granola"
                    iconText: "\uF08E"
                    foreground: root.fg
                    accent: root.accent
                    fontFamily: root.ff
                    bordered: true
                    enabled: root.granolaAuthUrl !== ""
                    onClicked: root.openGranolaAuthPage()
                  }

                  Button {
                    text: "Cancel"
                    foreground: root.fg
                    fontFamily: root.ff
                    bordered: false
                    onClicked: root.cancelGranolaAuth()
                  }
                }

                Text {
                  width: parent.width
                  text: root.granolaAuthStatus
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
