import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

// Tokens per model over a session, day, week, month or year, with paging back
// through the history.
ColumnLayout {
    id: section

    readonly property var periods: ["session", "day", "week", "month", "year"]
    readonly property var t: root.tokens && root.tokens.ok ? root.tokens : null
    // While another period loads, the last one stays up, dimmed, so the popup does not jump.
    readonly property bool loading: !!t && (t.period !== root.tokenPeriod || t.offset !== root.tokenOffset)
    readonly property bool empty: !t || t.total === 0
    property string highlight: ""

    spacing: Kirigami.Units.largeSpacing

    function rangeTitle() {
        if (!t)
            return "";
        const o = t.offset;
        switch (t.period) {
        case "session": return o === 0 && t.session.active ? i18n("Current session")
            : Qt.locale().toString(new Date(t.start * 1000), "dddd, d MMM");
        case "day": return o === 0 ? i18n("Today") : o === 1 ? i18n("Yesterday") : Qt.locale().toString(new Date(t.start * 1000), "dddd");
        case "week": return o === 0 ? i18n("This week") : o === 1 ? i18n("Last week") : i18np("%1 week ago", "%1 weeks ago", o);
        case "month": return o === 0 ? i18n("This month") : o === 1 ? i18n("Last month") : Qt.locale().toString(new Date(t.start * 1000), "MMMM");
        default: return o === 0 ? i18n("This year") : o === 1 ? i18n("Last year") : Qt.locale().toString(new Date(t.start * 1000), "yyyy");
        }
    }
    function rangeSubtitle() {
        if (!t)
            return "";
        const loc = Qt.locale();
        const start = new Date(t.start * 1000), last = new Date(t.end * 1000 - 1);
        switch (t.period) {
        case "session": return loc.toString(start, "HH:mm") + " – " + loc.toString(new Date(t.end * 1000), "HH:mm")
            + (t.session.confirmed ? "" : " " + i18n("(estimated)"));
        case "day": return loc.toString(start, "d MMMM yyyy");
        case "week": return loc.toString(start, "d MMM") + " – " + loc.toString(last, "d MMM yyyy");
        case "month": return loc.toString(start, "MMMM yyyy");
        default: return loc.toString(start, "yyyy");
        }
    }
    function changeText() {
        const pct = Format.change(t.total, t.prev_total);
        if (isNaN(pct))
            return "";
        const arrow = pct >= 0 ? "▲ " : "▼ ";
        const value = Math.abs(pct) < 1 ? "<1%" : Math.round(Math.abs(pct)) + "%";
        const against = t.partial ? {
            session: i18n("vs this point last session"), day: i18n("vs this time yesterday"),
            week: i18n("vs this point last week"), month: i18n("vs this point last month"),
            year: i18n("vs this point last year")
        } : {
            session: i18n("vs the session before"), day: i18n("vs the day before"),
            week: i18n("vs the week before"), month: i18n("vs the month before"),
            year: i18n("vs the year before")
        };
        return arrow + value + " " + against[t.period];
    }

    // Period switcher
    PlasmaComponents.TabBar {
        Layout.fillWidth: true
        currentIndex: section.periods.indexOf(root.tokenPeriod)

        Repeater {
            model: [i18n("Session"), i18n("Day"), i18n("Week"), i18n("Month"), i18n("Year")]
            PlasmaComponents.TabButton {
                required property string modelData
                required property int index
                text: modelData
                onClicked: root.setTokenPeriod(section.periods[index])
            }
        }
    }

    // Which stretch of time, with paging through the history
    RowLayout {
        Layout.fillWidth: true

        PlasmaComponents.ToolButton {
            icon.name: "go-previous"
            enabled: !!section.t && section.t.has_older
            onClicked: root.moveTokenOffset(1)
            QQC2.ToolTip.text: i18n("Earlier")
            QQC2.ToolTip.visible: hovered
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            // Labels fill the width, or the column cannot grow past them.
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: section.rangeTitle()
                font.weight: Font.DemiBold
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: section.rangeSubtitle()
                font: Kirigami.Theme.smallFont
                opacity: 0.6
            }
        }
        PlasmaComponents.ToolButton {
            icon.name: "go-next"
            enabled: root.tokenOffset > 0
            onClicked: root.moveTokenOffset(-1)
            QQC2.ToolTip.text: root.tokenOffset > 1 ? i18n("Later") : i18n("Back to now")
            QQC2.ToolTip.visible: hovered
        }
    }

    SessionHistory {
        visible: !!section.t && section.t.period === "session" && !!section.t.session
        Layout.fillWidth: true
        t: visible ? section.t : null
        opacity: section.loading ? 0.5 : 1
    }

    PlasmaComponents.Label {
        visible: !!root.tokens && !root.tokens.ok
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Kirigami.Theme.negativeTextColor
        text: root.tokens && root.tokens.error ? root.tokens.error : ""
    }

    // Headline total and how it compares
    RowLayout {
        visible: !section.empty
        opacity: section.loading ? 0.5 : 1
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            level: 1
            text: section.t ? Format.compact(section.t.total) : ""
            font.features: { "tnum": 1 }
        }
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignBaseline
            Layout.fillWidth: true
            text: i18n("tokens")
            opacity: 0.7
        }
        PlasmaComponents.Label {
            Layout.alignment: Qt.AlignBaseline
            text: section.t ? section.changeText() : ""
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }
    }

    // Where the tokens went
    GridLayout {
        visible: !section.empty
        opacity: section.loading ? 0.5 : 1
        Layout.fillWidth: true
        columns: 4
        uniformCellWidths: true
        columnSpacing: Kirigami.Units.largeSpacing
        rowSpacing: 0

        Repeater {
            model: section.t ? [
                [i18n("Input"), section.t.input],
                [i18n("Output"), section.t.output],
                [i18n("Cache write"), section.t.cache_write],
                [i18n("Cache read"), section.t.cache_read],
            ] : []

            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: modelData[0]
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                    opacity: 0.6
                }
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: Format.compact(modelData[1])
                    font.features: { "tnum": 1 }
                }
            }
        }
    }

    TokenChart {
        visible: !section.empty
        opacity: section.loading ? 0.5 : 1
        Layout.fillWidth: true
        buckets: section.t ? section.t.buckets : []
        models: section.t ? section.t.models : []
        period: section.t ? section.t.period : "day"
        highlight: section.highlight
        limitHitAt: section.t && section.t.session && section.t.session.hit_at ? section.t.session.hit_at : null
    }

    ColumnLayout {
        visible: !section.empty
        opacity: section.loading ? 0.5 : 1
        Layout.fillWidth: true
        spacing: 0

        Repeater {
            model: section.t ? section.t.models : []

            ModelRow {
                required property var modelData
                Layout.fillWidth: true
                entry: modelData
                periodTotal: section.t.total
                onHoveredChanged: {
                    if (hovered)
                        section.highlight = modelData.id;
                    else if (section.highlight === modelData.id)
                        section.highlight = "";
                }
            }
        }
    }

    PlasmaExtras.PlaceholderMessage {
        visible: !!section.t && section.empty
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.gridUnit
        Layout.bottomMargin: Kirigami.Units.gridUnit
        iconName: "office-chart-bar"
        text: i18n("No Claude Code activity")
        explanation: section.t && !section.t.has_older && section.t.offset > 0
            ? i18n("History starts on %1", Qt.locale().toString(new Date(section.t.oldest * 1000), "d MMMM yyyy"))
            : ""
    }
}
