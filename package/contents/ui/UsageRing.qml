import QtQuick
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

// Circular gauge, 0..100. With nested set, a second gauge (innerPercent) sits inside it.
Item {
    id: ring

    property real percent: 0
    property color color: Kirigami.Theme.highlightColor
    property bool nested: false
    property real innerPercent: 0
    property color innerColor: Kirigami.Theme.highlightColor
    property real thickness: nested ? Math.max(2, width / 9) : Math.max(2, width / 7)
    readonly property real gap: nested ? Math.max(1, thickness / 2) : 0
    readonly property real outerRadius: (Math.min(width, height) - thickness) / 2
    readonly property real innerRadius: outerRadius - thickness - gap

    component Arc: ShapePath {
        property real radius
        property real percent
        property bool track: false
        fillColor: "transparent"
        strokeColor: track ? Qt.alpha(Kirigami.Theme.textColor, 0.2) : ring.color
        strokeWidth: ring.thickness
        capStyle: track ? ShapePath.FlatCap : ShapePath.RoundCap
        PathAngleArc {
            centerX: ring.width / 2
            centerY: ring.height / 2
            radiusX: radius
            radiusY: radius
            startAngle: -90
            sweepAngle: 3.6 * Math.max(0, Math.min(100, percent))
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        Arc { track: true; radius: ring.outerRadius; percent: 100 }
        Arc { radius: ring.outerRadius; percent: ring.percent }
    }
    Shape {
        anchors.fill: parent
        visible: ring.nested && ring.innerRadius > 0
        preferredRendererType: Shape.CurveRenderer

        Arc { track: true; radius: ring.innerRadius; percent: 100 }
        Arc { radius: ring.innerRadius; percent: ring.innerPercent; strokeColor: ring.innerColor }
    }
}
