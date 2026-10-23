import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property var limit: root.panelLimit
    readonly property real percent: root.percentOf(limit)
    readonly property var cfg: Plasmoid.configuration
    // With everything switched off the widget would vanish from the panel; the chart stays then.
    readonly property bool showChart: cfg.showChart || (!cfg.showPercent && !cfg.showResetTime)
    readonly property string text: {
        if (!limit)
            return root.usage && root.usage.error ? "!" : showChart ? "" : "…";
        return Format.panelText(percent, limit.resets_at, root.now, cfg.showPercent, cfg.showResetTime, cfg.resetTimeStyle);
    }

    Layout.minimumWidth: vertical ? -1 : row.implicitWidth
    Layout.minimumHeight: vertical ? row.implicitHeight : -1
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton)
            root.refresh(true);
        else
            root.expanded = !root.expanded;
    }

    GridLayout {
        id: row
        anchors.centerIn: parent
        flow: compact.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
        columnSpacing: Kirigami.Units.smallSpacing
        rowSpacing: 0

        UsageRing {
            visible: compact.showChart
            readonly property int size: Math.round((compact.vertical ? compact.width : compact.height) * 0.6)
            Layout.preferredWidth: size
            Layout.preferredHeight: size
            Layout.alignment: Qt.AlignCenter
            percent: compact.percent
            color: root.colorFor(compact.percent)
            opacity: root.usage && root.usage.stale ? 0.5 : 1
        }
        PlasmaComponents.Label {
            visible: compact.text.length > 0
            text: compact.text
            Layout.alignment: Qt.AlignCenter
            font.pointSize: compact.vertical ? Kirigami.Theme.smallFont.pointSize : Kirigami.Theme.defaultFont.pointSize
            font.features: { "tnum": 1 }
            color: root.usage && root.usage.stale ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.textColor
        }
    }
}
