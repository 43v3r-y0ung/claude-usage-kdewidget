import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

// Session tab extras: a strip of nearby sessions to jump between, and whether
// the shown session ran into its limit.
ColumnLayout {
    id: history

    property var t   // a session answer of token_stats.py
    readonly property var info: t ? t.session : null
    readonly property real stripMax: t ? t.strip.reduce((m, s) => Math.max(m, s.total), 0) : 0
    property int hovered: -1

    spacing: Kirigami.Units.smallSpacing

    function hm(ts) {
        return Qt.locale().toString(new Date(ts * 1000), "HH:mm");
    }

    // One bar per session, oldest left; red ones hit the limit.
    Item {
        Layout.fillWidth: true
        implicitHeight: Kirigami.Units.gridUnit * 1.6

        Row {
            id: strip
            anchors.fill: parent
            spacing: 3
            readonly property real barWidth: history.t ? (width - spacing * (history.t.strip.length - 1)) / history.t.strip.length : 0

            Repeater {
                model: history.t ? history.t.strip : []

                Item {
                    id: cell
                    required property var modelData
                    required property int index
                    readonly property bool selected: modelData.offset === history.t.offset

                    width: strip.barWidth
                    height: strip.height

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(3, history.stripMax ? cell.modelData.total / history.stripMax * (parent.height - 4) : 3)
                        topLeftRadius: Math.min(3, width / 2)
                        topRightRadius: topLeftRadius
                        color: cell.modelData.hit ? Kirigami.Theme.negativeTextColor
                             : cell.selected ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
                        opacity: cell.selected || cell.modelData.hit ? 1 : history.hovered === cell.index ? 0.55 : 0.3
                    }
                    // Selection marker under the bar
                    Rectangle {
                        visible: cell.selected
                        anchors.top: parent.bottom
                        anchors.topMargin: 2
                        width: parent.width
                        height: 2
                        radius: 1
                        color: Kirigami.Theme.highlightColor
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: history.hovered = containsMouse ? cell.index : (history.hovered === cell.index ? -1 : history.hovered)
                        onClicked: root.setTokenOffset(cell.modelData.offset)
                    }
                }
            }
        }
    }

    // What the strip shows, or the hovered session
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 2
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents.Label {
            Layout.fillWidth: true
            font: Kirigami.Theme.smallFont
            opacity: 0.6
            elide: Text.ElideRight
            text: {
                if (!history.t)
                    return "";
                if (history.hovered >= 0 && history.hovered < history.t.strip.length) {
                    const s = history.t.strip[history.hovered];
                    return Qt.locale().toString(new Date(s.start * 1000), "ddd d MMM") + ", " + history.hm(s.start)
                        + "–" + history.hm(s.end) + " · " + i18n("%1 tokens", Format.compact(s.total))
                        + (s.cost ? " · ≈ " + Format.money(s.cost) : "")
                        + (s.hit ? " · " + i18n("limit reached") : "");
                }
                const hits = history.t.strip.filter(s => s.hit).length;
                return i18np("%2 of the last %1 session hit the limit", "%2 of the last %1 sessions hit the limit",
                             history.t.strip.length, hits);
            }
        }
        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            radius: 2
            color: Kirigami.Theme.negativeTextColor
        }
        PlasmaComponents.Label {
            text: i18n("Limit reached")
            font: Kirigami.Theme.smallFont
            opacity: 0.6
        }
    }

    // Did this session run into the limit?
    Rectangle {
        id: banner
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        implicitHeight: status.implicitHeight + Kirigami.Units.smallSpacing * 3
        radius: Kirigami.Units.cornerRadius
        readonly property color tone: !history.info ? Kirigami.Theme.textColor
            : history.info.hit_at ? Kirigami.Theme.negativeTextColor
            : history.info.active ? Kirigami.Theme.highlightColor : Kirigami.Theme.positiveTextColor
        color: Qt.alpha(tone, 0.12)
        border.color: Qt.alpha(tone, 0.35)

        RowLayout {
            id: status
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing * 1.5
            spacing: Kirigami.Units.smallSpacing * 2

            Kirigami.Icon {
                Layout.alignment: Qt.AlignTop
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                source: !history.info ? "" : history.info.hit_at ? "dialog-error"
                      : history.info.active ? "chronometer" : "checkmark"
                color: banner.tone
                isMask: true
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                    text: {
                        const i = history.info;
                        if (!i)
                            return "";
                        if (i.hit_at)
                            return i18n("Limit reached at %1", history.hm(i.hit_at));
                        if (i.active)
                            return i18n("In progress");
                        return i18n("Limit not reached");
                    }
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    wrapMode: Text.Wrap
                    opacity: 0.8
                    text: {
                        const i = history.info, t = history.t;
                        if (!i)
                            return "";
                        let parts = [];
                        if (i.hit_at) {
                            parts.push(i18n("after %1 of the session", Format.duration(i.hit_at - t.start, root.durationUnits)));
                            parts.push(i.active ? i18n("resets in %1", Format.duration(t.end - root.now / 1000, root.durationUnits))
                                                : i18n("blocked for %1", Format.duration(t.end - i.hit_at, root.durationUnits)));
                        } else if (i.active) {
                            const live = root.limits.find(l => l.kind === "session");
                            if (live)
                                parts.push(i18n("%1% used", Math.round(root.percentOf(live))));
                            parts.push(i18n("resets in %1", Format.duration(t.end - root.now / 1000, root.durationUnits)));
                        } else if (i.peak_percent !== null && i.peak_percent !== undefined) {
                            parts.push(i18n("peaked at %1% of the limit", Math.round(i.peak_percent)));
                        } else {
                            parts.push(i18n("no limit errors were logged"));
                        }
                        if (!t.session.confirmed)
                            parts.push(i18n("times estimated from this computer's activity"));
                        return parts.join(" · ");
                    }
                }
            }
        }
    }
}
