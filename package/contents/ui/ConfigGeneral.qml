import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

import "../code/format.js" as Format

KCM.SimpleKCM {
    property alias cfg_panelLimit: panelLimit.currentIndex
    property alias cfg_showChart: showChart.checked
    property alias cfg_showPercent: showPercent.checked
    property alias cfg_showResetTime: showResetTime.checked
    property alias cfg_resetTimeStyle: resetTimeStyle.currentIndex

    // At least one element stays on, or the widget would vanish from the panel.
    readonly property int shownCount: showChart.checked + showPercent.checked + showResetTime.checked
    property alias cfg_refreshMinutes: refreshMinutes.value
    property alias cfg_warningPercent: warningPercent.value
    property alias cfg_criticalPercent: criticalPercent.value
    property alias cfg_configDir: configDir.text
    property alias cfg_allowTokenRefresh: allowTokenRefresh.checked

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: panelLimit
            Kirigami.FormData.label: i18n("Limit shown in panel:")
            model: [i18n("Session (5 hours)"), i18n("Weekly (all models)"), i18n("Whichever is most used")]
        }

        QQC2.CheckBox {
            id: showChart
            Kirigami.FormData.label: i18n("Panel shows:")
            text: i18n("Chart")
            enabled: !checked || shownCount > 1
        }
        QQC2.CheckBox {
            id: showPercent
            text: i18n("Percentage used")
            enabled: !checked || shownCount > 1
        }
        RowLayout {
            QQC2.CheckBox {
                id: showResetTime
                text: i18n("Reset time as")
                enabled: !checked || shownCount > 1
            }
            QQC2.ComboBox {
                id: resetTimeStyle
                enabled: showResetTime.checked
                model: [i18n("Time left (1h 2m)"), i18n("Clock time (11:50)"), i18n("Both")]
            }
        }

        // What the panel will look like, with sample numbers.
        QQC2.Frame {
            Kirigami.FormData.label: i18n("Preview:")
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                readonly property real samplePercent: 37
                // Resets in 1h 2m from now.
                readonly property string sampleReset: new Date(Date.now() + 62 * 60000 + 30000).toISOString()

                UsageRing {
                    visible: showChart.checked || shownCount === 0
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                    percent: parent.samplePercent
                }
                QQC2.Label {
                    readonly property string sample: Format.panelText(parent.samplePercent, parent.sampleReset, Date.now(),
                        showPercent.checked, showResetTime.checked, resetTimeStyle.currentIndex)
                    visible: sample.length > 0
                    text: sample
                    font.features: { "tnum": 1 }
                }
            }
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: refreshMinutes
            Kirigami.FormData.label: i18n("Refresh every:")
            from: 1
            to: 60
            textFromValue: (value) => i18np("%1 minute", "%1 minutes", value)
            valueFromText: (text) => parseInt(text)
        }
        QQC2.SpinBox {
            id: warningPercent
            Kirigami.FormData.label: i18n("Warning at:")
            from: 0
            to: 100
            textFromValue: (value) => value + "%"
            valueFromText: (text) => parseInt(text)
        }
        QQC2.SpinBox {
            id: criticalPercent
            Kirigami.FormData.label: i18n("Critical at:")
            from: 0
            to: 100
            textFromValue: (value) => value + "%"
            valueFromText: (text) => parseInt(text)
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.TextField {
            id: configDir
            Kirigami.FormData.label: i18n("Claude config directory:")
            placeholderText: "~/.claude"
        }
        QQC2.CheckBox {
            id: allowTokenRefresh
            text: i18n("Renew an expired login token")
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.Wrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("Off: when Claude Code has not been used for a while and its token expires, the widget keeps showing the last data until Claude Code renews it. On: the widget renews the token itself and writes the new one back to Claude Code's credentials file.")
        }
    }
}
