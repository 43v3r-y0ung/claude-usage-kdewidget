import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

// One model of the token list: its share of the period, and on click the
// split into input, output and cache. Doubles as the chart's legend.
Item {
    id: row

    property var entry                // a model, as in token_stats.py
    property real periodTotal: 1
    // Kept by the list, so a row stays open when new numbers rebuild it.
    property bool expanded: false
    signal toggled()
    readonly property bool hovered: hover.containsMouse
    readonly property real share: periodTotal > 0 ? entry.total / periodTotal * 100 : 0

    implicitHeight: column.implicitHeight + Kirigami.Units.smallSpacing * 2

    Rectangle {
        anchors.fill: parent
        radius: Kirigami.Units.cornerRadius
        color: Kirigami.Theme.highlightColor
        opacity: row.hovered ? 0.12 : 0
        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggled()
    }

    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Kirigami.Units.smallSpacing
        anchors.rightMargin: Kirigami.Units.smallSpacing
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                implicitWidth: 10
                implicitHeight: 10
                radius: 5
                color: root.modelColor(row.entry.slot)
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: row.entry.name
                elide: Text.ElideRight
            }
            PlasmaComponents.Label {
                visible: row.entry.cost != null
                text: row.entry.cost != null ? Format.money(row.entry.cost) : ""
                font.features: { "tnum": 1 }
                opacity: 0.6
            }
            PlasmaComponents.Label {
                text: Format.compact(row.entry.total)
                font.features: { "tnum": 1 }
                font.weight: Font.DemiBold
            }
            PlasmaComponents.Label {
                Layout.preferredWidth: shareMetrics.width
                horizontalAlignment: Text.AlignRight
                text: row.share < 1 && row.share > 0 ? "<1%" : Math.round(row.share) + "%"
                font.features: { "tnum": 1 }
                opacity: 0.6
                PlasmaComponents.Label { id: shareMetrics; visible: false; text: "100%" }
            }
            Kirigami.Icon {
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: Kirigami.Units.iconSizes.small
                source: row.expanded ? "arrow-up" : "arrow-down"
                opacity: row.hovered || row.expanded ? 0.7 : 0.3
            }
        }

        UsageBar {
            Layout.fillWidth: true
            Layout.leftMargin: 10 + Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.iconSizes.small + Kirigami.Units.smallSpacing
            implicitHeight: 3
            percent: row.share
            barColor: root.modelColor(row.entry.slot)
        }

        GridLayout {
            visible: row.expanded
            Layout.fillWidth: true
            Layout.leftMargin: 10 + Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            columns: 2
            columnSpacing: Kirigami.Units.largeSpacing
            rowSpacing: 0

            Repeater {
                model: [
                    [i18n("Input"), Format.compact(row.entry.input)],
                    [i18n("Output"), Format.compact(row.entry.output)],
                    [i18n("Cache write"), Format.compact(row.entry.cache_write)],
                    [i18n("Cache read"), Format.compact(row.entry.cache_read)],
                    [i18n("Requests"), Format.compact(row.entry.requests)],
                    [i18n("Cost"), row.entry.cost != null ? "≈ " + Format.money(row.entry.cost) : i18n("unknown price")],
                ]

                PlasmaComponents.Label {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData[0] + "  <b>" + modelData[1] + "</b>"
                    textFormat: Text.StyledText
                    font: Kirigami.Theme.smallFont
                }
            }
        }
    }
}
