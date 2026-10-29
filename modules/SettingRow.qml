import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../services"

RowLayout {
    id: rootRow
    property string title
    property string subtitle
    property alias controlComponent: controlLoader.sourceComponent

    Layout.fillWidth: true

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4

        Text {
            text: rootRow.title
            color: Theme.onPrimaryContainerColor
            font.pixelSize: 15
            font.weight: Font.Medium
        }

        Text {
            text: rootRow.subtitle
            color: Qt.rgba(Theme.onPrimaryContainerColor.r, Theme.onPrimaryContainerColor.g, Theme.onPrimaryContainerColor.b, 0.6)
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
    }

    Loader {
        id: controlLoader
        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
    }
}
