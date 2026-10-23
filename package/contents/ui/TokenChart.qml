import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

// Stacked bars of tokens per bucket, one segment per model. Hovering a bar shows
// its totals; `highlight` (a model id) dims every other model.
Item {
    id: chart

    property var buckets: []
    property var models: []        // as in token_stats.py, for names and slots
    property string period: "day"
    property string highlight: ""
    property int hovered: -1
    // When a limit was hit (epoch seconds); the rest of the chart is shaded as blocked.
    property var limitHitAt: null

    readonly property real maxTotal: buckets.reduce((m, b) => Math.max(m, b.total), 0)
    // Bottom to top in slot order, so a model sits at the same height in every bar.
    readonly property var stackOrder: models.slice().sort((a, b) => a.slot - b.slot)
    readonly property int gap: buckets.length > 24 ? 2 : 4
    readonly property real barWidth: buckets.length ? Math.min(Kirigami.Units.gridUnit * 1.5,
        (plot.width - gap * (buckets.length - 1)) / buckets.length) : 0
    readonly property real barsLeft: (plot.width - (barWidth + gap) * buckets.length + gap) / 2

    implicitHeight: Kirigami.Units.gridUnit * 7

    function bucketTitle(i) {
        const start = new Date(buckets[i].start * 1000);
        const end = new Date((i + 1 < buckets.length ? buckets[i + 1].start : buckets[i].start + 900) * 1000);
        const loc = Qt.locale();
        switch (period) {
        case "session":
        case "day":
            return loc.toString(start, "HH:mm") + "–" + loc.toString(end, "HH:mm");
        case "week":
        case "month":
            return loc.toString(start, "dddd, d MMM");
        default:
            return loc.toString(start, "MMMM yyyy");
        }
    }
    function tickLabel(i) {
        const start = new Date(buckets[i].start * 1000);
        const loc = Qt.locale();
        switch (period) {
        case "session": return loc.toString(start, "HH:mm");
        case "day": return loc.toString(start, "HH");
        case "week": return loc.toString(start, "ddd");
        case "month": return loc.toString(start, "d");
        default: return loc.toString(start, "MMM");
        }
    }
    // Segments of one bucket, bottom up, with a 2px gap between them.
    function segments(bucket, height) {
        if (!maxTotal)
            return [];
        let y = 0, out = [];
        for (const m of stackOrder) {
            const value = bucket.models[m.id] || 0;
            const h = value / maxTotal * height;
            if (h < 0.5)
                continue;
            if (out.length)
                y += 2;
            out.push({ id: m.id, slot: m.slot, y: y, h: Math.max(1, h - (out.length ? 2 : 0)) });
            y += out[out.length - 1].h;
        }
        return out;
    }

    // Peak value, top left; the only gridline is the baseline.
    PlasmaComponents.Label {
        id: peak
        anchors.top: parent.top
        anchors.left: parent.left
        text: chart.maxTotal ? i18n("Peak %1", Format.compact(chart.maxTotal)) : ""
        font: Kirigami.Theme.smallFont
        opacity: 0.6
    }

    Item {
        id: plot
        anchors.top: peak.bottom
        anchors.topMargin: Kirigami.Units.smallSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: axis.top
        anchors.bottomMargin: Kirigami.Units.smallSpacing
        z: 1  // the tooltip goes over the axis labels

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Kirigami.Theme.textColor
            opacity: 0.15
        }

        Item {
            id: blocked
            visible: chart.limitHitAt !== null && chart.buckets.length > 1
            readonly property real bucketSeconds: visible ? chart.buckets[1].start - chart.buckets[0].start : 1
            x: visible ? chart.barsLeft + (chart.limitHitAt - chart.buckets[0].start) / bucketSeconds * (chart.barWidth + chart.gap) : 0
            width: Math.max(0, plot.width - x)
            height: plot.height

            Rectangle {
                anchors.fill: parent
                color: Qt.alpha(Kirigami.Theme.negativeTextColor, 0.1)
            }
            Rectangle {
                width: 1
                height: parent.height
                color: Kirigami.Theme.negativeTextColor
            }
            // Above the plot, so a narrow band does not cut it off.
            PlasmaComponents.Label {
                x: parent.width >= implicitWidth ? 0 : parent.width - implicitWidth
                y: -implicitHeight - Kirigami.Units.smallSpacing
                text: chart.limitHitAt ? i18n("Limit hit %1", Qt.locale().toString(new Date(chart.limitHitAt * 1000), "HH:mm")) : ""
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.negativeTextColor
            }
        }

        Repeater {
            model: chart.buckets

            Item {
                id: bar
                required property var modelData
                required property int index
                readonly property bool dimmed: chart.hovered >= 0 && chart.hovered !== index
                readonly property var segments: chart.segments(modelData, plot.height - 1)

                x: chart.barsLeft + index * (chart.barWidth + chart.gap)
                width: chart.barWidth
                height: plot.height

                // Empty buckets keep a stub on the baseline so the timeline reads.
                Rectangle {
                    visible: bar.modelData.total === 0
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 2
                    radius: 1
                    color: Kirigami.Theme.textColor
                    opacity: 0.12
                }

                Repeater {
                    model: bar.segments

                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool isTop: index === bar.segments.length - 1

                        y: plot.height - 1 - modelData.y - modelData.h
                        width: bar.width
                        height: modelData.h
                        color: root.modelColor(modelData.slot)
                        topLeftRadius: isTop ? Math.min(4, height / 2, width / 2) : 0
                        topRightRadius: topLeftRadius
                        opacity: chart.highlight && chart.highlight !== modelData.id ? 0.25 : bar.dimmed ? 0.5 : 1
                        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }
                    }
                }

                // The hit target spans the full height and the gap, not just the bar.
                MouseArea {
                    x: -chart.gap / 2
                    width: parent.width + chart.gap
                    height: parent.height
                    hoverEnabled: true
                    onContainsMouseChanged: {
                        if (containsMouse)
                            chart.hovered = bar.index;
                        else if (chart.hovered === bar.index)
                            chart.hovered = -1;
                    }
                }
            }
        }

        // Tooltip beside the hovered bar, bottom-aligned with the plot; a tall
        // one grows upwards over the headline rather than over the model list.
        Rectangle {
            id: tip
            visible: chart.hovered >= 0 && chart.hovered < chart.buckets.length
            readonly property var bucket: visible ? chart.buckets[chart.hovered] : null
            // Largest first, at most five lines.
            readonly property var lines: bucket ? chart.models.filter(m => bucket.models[m.id])
                .sort((a, b) => bucket.models[b.id] - bucket.models[a.id]) : []
            readonly property real barX: chart.barsLeft + Math.max(0, chart.hovered) * (chart.barWidth + chart.gap)
            x: barX + chart.barWidth / 2 < plot.width / 2
               ? Math.min(barX + chart.barWidth + Kirigami.Units.smallSpacing, plot.width - width)
               : Math.max(0, barX - width - Kirigami.Units.smallSpacing)
            y: Math.min(0, plot.height - height)
            width: tipColumn.implicitWidth + Kirigami.Units.largeSpacing
            height: tipColumn.implicitHeight + Kirigami.Units.smallSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: Kirigami.Theme.backgroundColor
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.2)

            ColumnLayout {
                id: tipColumn
                anchors.centerIn: parent
                spacing: 0

                PlasmaComponents.Label {
                    text: tip.bucket ? chart.bucketTitle(chart.hovered) : ""
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
                PlasmaComponents.Label {
                    text: tip.bucket ? i18n("%1 tokens", Format.compact(tip.bucket.total)) : ""
                    font.weight: Font.DemiBold
                }
                Repeater {
                    model: tip.lines.slice(0, 5)

                    RowLayout {
                        required property var modelData
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            implicitWidth: 8
                            implicitHeight: 8
                            radius: 4
                            color: root.modelColor(modelData.slot)
                        }
                        PlasmaComponents.Label {
                            text: modelData.name + "  " + Format.compact(tip.bucket.models[modelData.id])
                            font: Kirigami.Theme.smallFont
                        }
                    }
                }
                PlasmaComponents.Label {
                    visible: tip.lines.length > 5
                    text: i18n("+%1 more", tip.lines.length - 5)
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
            }
        }
    }

    Item {
        id: axis
        anchors.bottom: parent.bottom
        width: parent.width
        height: tickMetrics.height

        PlasmaComponents.Label { id: tickMetrics; visible: false; text: "0"; font: Kirigami.Theme.smallFont }

        Repeater {
            model: chart.buckets

            PlasmaComponents.Label {
                required property int index
                visible: Format.isTick(chart.period, index)
                x: Math.max(0, Math.min(axis.width - width,
                   chart.barsLeft + index * (chart.barWidth + chart.gap) + (chart.barWidth - width) / 2))
                text: chart.tickLabel(index)
                font: Kirigami.Theme.smallFont
                opacity: chart.hovered === index ? 1 : 0.6
            }
        }
    }
}
