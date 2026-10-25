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

    visible: !root.hidden
    Layout.minimumWidth: root.hidden ? 0 : vertical ? -1 : row.implicitWidth
    Layout.minimumHeight: root.hidden ? 0 : vertical ? row.implicitHeight : -1
    Layout.preferredWidth: root.hidden ? 0 : -1
    Layout.preferredHeight: root.hidden ? 0 : -1
    Layout.maximumWidth: root.hidden ? 0 : Infinity
    Layout.maximumHeight: root.hidden ? 0 : Infinity
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
            // Two rings need more room to stay readable.
            readonly property int size: Math.round((compact.vertical ? compact.width : compact.height) * (nested ? 0.8 : 0.6))
            Layout.preferredWidth: size
            Layout.preferredHeight: size
            Layout.alignment: Qt.AlignCenter
            nested: root.nestedRings
            readonly property real weeklyPercent: root.percentOf(root.weeklyLimit)
            percent: nested && !root.sessionOutside ? weeklyPercent : compact.percent
            color: root.colorFor(percent)
            innerPercent: root.sessionOutside ? weeklyPercent : compact.percent
            innerColor: root.colorFor(innerPercent)
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
