import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The device-code overlay: Granola is connecting while the rest of the panel
// waits behind it. Shows the code to approve in the browser and the progress.
Rectangle {
  id: root

  required property string authCode
  required property string authUrl
  required property string authStatus
  signal openPage()
  signal cancel()

  color: Commons.Color.popups.background

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(48), Style.space(420))
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "CONNECT GRANOLA"
      foreground: Commons.Color.popups.text
      fontFamily: Style.font.family
    }

    Text {
      width: parent.width
      text: "Sign in to Granola"
      textFormat: Text.PlainText
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      width: parent.width
      text: "Approve Meeting Notes for Omarchy in the browser. "
        + "Your notes are read-only; nothing is written back to Granola."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Commons.Color.popups.text, 1.35)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      visible: root.authCode !== ""
      width: parent.width
      text: root.authCode
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      color: Commons.Color.accent
      font.family: Style.font.family
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
        foreground: Commons.Color.popups.text
        accent: Commons.Color.accent
        fontFamily: Style.font.family
        bordered: true
        enabled: root.authUrl !== ""
        onClicked: root.openPage()
      }

      Button {
        text: "Cancel"
        foreground: Commons.Color.popups.text
        fontFamily: Style.font.family
        bordered: false
        onClicked: root.cancel()
      }
    }

    Text {
      width: parent.width
      text: root.authStatus
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Commons.Color.popups.text, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
