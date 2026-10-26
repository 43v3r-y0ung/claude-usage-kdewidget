import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Window
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

PlasmaExtras.Representation {
    id: full

    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 22
    // The popup is as tall as the tab shown, up to most of the screen; past that
    // the content scrolls. Plasma reopens a popup at its last size and only ever
    // grows it, so the minimum and maximum both pin it to the content.
    readonly property real contentNeeds: Math.min(scroll.contentHeight + header.implicitHeight,
                                                  Screen.desktopAvailableHeight * 0.85)
    // Eases between tab heights while open; opens at the right height at once.
    property real shownHeight: contentNeeds
    Behavior on shownHeight {
        enabled: root.expanded
        NumberAnimation {
            id: heightAnimation
            duration: Kirigami.Units.longDuration
            easing.type: Easing.OutCubic
        }
    }
    Layout.preferredHeight: Math.round(shownHeight)
    Layout.minimumHeight: Math.round(shownHeight)
    Layout.maximumHeight: Math.round(shownHeight)
    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            Kirigami.Heading {
                Layout.fillWidth: true
                level: 3
                text: i18n("Claude usage")
            }
            PlasmaComponents.Label {
                visible: !!(root.usage && root.usage.plan)
                text: root.usage && root.usage.plan ? root.usage.plan.charAt(0).toUpperCase() + root.usage.plan.slice(1) : ""
                opacity: 0.7
            }
            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                enabled: !root.loading
                onClicked: root.refresh(true)
                QQC2.ToolTip.text: i18n("Refresh now")
                QQC2.ToolTip.visible: hovered
            }
        }
    }

    PlasmaComponents.ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        contentHeight: content.implicitHeight + Kirigami.Units.largeSpacing * 2
        QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff
        // Content runs ahead of a growing popup; no scrollbar flash meanwhile.
        QQC2.ScrollBar.vertical.policy: heightAnimation.running ? QQC2.ScrollBar.AlwaysOff : QQC2.ScrollBar.AsNeeded

        ColumnLayout {
            id: content
            x: Kirigami.Units.largeSpacing
            y: Kirigami.Units.largeSpacing
            width: scroll.availableWidth - Kirigami.Units.largeSpacing * 2
            spacing: Kirigami.Units.largeSpacing

            SectionLabel { text: i18n("Limits") }

            PlasmaExtras.PlaceholderMessage {
                visible: !root.hasData
                Layout.fillWidth: true
                iconName: root.usage && root.usage.error ? "data-warning" : "office-chart-ring"
                text: root.usage && root.usage.error ? i18n("No usage data") : i18n("Loading…")
                explanation: root.usage && root.usage.error ? root.usage.error : ""
            }

            Repeater {
                model: root.limits

                ColumnLayout {
                    id: limitItem
                    required property var modelData
                    readonly property real percent: root.percentOf(modelData)

                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            text: limitItem.modelData.label
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        PlasmaComponents.Label {
                            text: i18n("%1% used", Math.round(limitItem.percent))
                            font.features: { "tnum": 1 }
                            color: limitItem.percent >= Plasmoid.configuration.warningPercent ? root.colorFor(limitItem.percent) : Kirigami.Theme.textColor
                        }
                    }
                    UsageBar {
                        Layout.fillWidth: true
                        percent: limitItem.percent
                        barColor: root.colorFor(limitItem.percent)
                    }
                    RowLayout {
                        PlasmaComponents.Label {
                            Layout.fillWidth: true
                            text: root.resetText(limitItem.modelData)
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            elide: Text.ElideRight
                        }
                        // What this computer's Claude Code used in the session so far.
                        PlasmaComponents.Label {
                            readonly property var used: root.tokens && root.tokens.current_session
                            visible: limitItem.modelData.kind === "session" && !!used && limitItem.percent > 0
                            text: used ? i18n("%1 tokens · ≈ %2", Format.compact(used.total), Format.money(used.cost)) : ""
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.features: { "tnum": 1 }
                            opacity: 0.7

                            HoverHandler { id: sessionUsedHover }
                            QQC2.ToolTip.visible: sessionUsedHover.hovered
                            QQC2.ToolTip.text: i18n("Used by Claude Code on this computer in this session. The cost is an estimate at Claude API prices.")
                        }
                    }
                }
            }

            RowLayout {
                visible: !!(root.usage && root.usage.extra_usage && typeof root.usage.extra_usage.utilization === "number")
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: i18n("Extra usage")
                }
                PlasmaComponents.Label {
                    text: visible ? i18n("%1% of monthly limit", Math.round(root.usage.extra_usage.utilization)) : ""
                }
            }

            Kirigami.Separator { Layout.fillWidth: true }

            SectionLabel { text: i18n("Tokens · Claude Code on this computer") }

            TokenSection { Layout.fillWidth: true }

            Kirigami.Separator {
                Layout.fillWidth: true
                visible: root.hasData
            }

            PlasmaComponents.Label {
                visible: root.hasData
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                color: root.usage && root.usage.error ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.textColor
                opacity: root.usage && root.usage.error ? 1 : 0.6
                text: {
                    if (!root.usage || !root.usage.fetched_at)
                        return "";
                    const age = (root.now - Date.parse(root.usage.fetched_at)) / 1000;
                    const updated = age < 60 ? i18n("Updated just now") : i18n("Updated %1 ago", Format.duration(age, root.durationUnits));
                    return root.usage.error ? updated + " — " + root.usage.error : updated;
                }
            }
        }
    }
}
