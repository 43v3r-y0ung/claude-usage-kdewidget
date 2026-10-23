import QtQuick
import org.kde.kirigami as Kirigami

// Horizontal bar, 0..100.
Rectangle {
    property real percent: 0
    property color barColor: Kirigami.Theme.highlightColor

    implicitHeight: Kirigami.Units.smallSpacing * 1.5
    radius: height / 2
    color: Qt.alpha(Kirigami.Theme.textColor, 0.15)

    Rectangle {
        width: parent.width * Math.max(0, Math.min(100, parent.percent)) / 100
        height: parent.height
        radius: parent.radius
        color: parent.barColor
        Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
    }
}
