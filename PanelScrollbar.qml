import QtQuick
import qs.Commons

// Thin scrollbar for the panel's flickables: a faint track and one thumb.
Rectangle {
  id: root

  required property Flickable flickable
  property color foreground: "#ffffff"
  property real thumbWidth: Style.space(3)
  property int minThumb: Style.space(18)
  property real thumbOpacity: 0.30

  visible: flickable.contentHeight > flickable.height + 1
  anchors.top: flickable.top
  anchors.bottom: flickable.bottom
  width: root.thumbWidth
  radius: width / 2
  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

  Rectangle {
    width: parent.width
    radius: parent.radius
    height: Math.max(root.minThumb,
      parent.height * root.flickable.visibleArea.heightRatio)
    y: (parent.height - height) * root.flickable.visibleArea.yPosition
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
      root.thumbOpacity)
  }
}
