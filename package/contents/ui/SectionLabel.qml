import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

// Small heading above a group of the popup.
PlasmaComponents.Label {
    Layout.fillWidth: true
    font.pointSize: Kirigami.Theme.smallFont.pointSize
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 0.5
    elide: Text.ElideRight
    opacity: 0.6
}
