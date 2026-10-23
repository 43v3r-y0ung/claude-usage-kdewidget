import QtQuick
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

// Circular gauge, 0..100.
Item {
    id: ring

    property real percent: 0
    property color color: Kirigami.Theme.highlightColor
    property real thickness: Math.max(2, width / 7)

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.alpha(Kirigami.Theme.textColor, 0.2)
            strokeWidth: ring.thickness
            PathAngleArc {
                centerX: ring.width / 2
                centerY: ring.height / 2
                radiusX: (Math.min(ring.width, ring.height) - ring.thickness) / 2
                radiusY: radiusX
                startAngle: 0
                sweepAngle: 360
            }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: ring.color
            strokeWidth: ring.thickness
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: ring.width / 2
                centerY: ring.height / 2
                radiusX: (Math.min(ring.width, ring.height) - ring.thickness) / 2
                radiusY: radiusX
                startAngle: -90
                sweepAngle: 3.6 * Math.max(0, Math.min(100, ring.percent))
            }
        }
    }
}
