// ─────────────────────────────────────────────────────────────────────────
// KeybindViewer.qml — read-only overlay that displays niri keybinds
//
// Runs scripts/parse-niri-binds.py, which reads the `binds { … }` block of
// ~/.config/niri/config.kdl (following `include`s) and prints JSON. Each
// bind becomes a  Key → Action  row, grouped into sections (Shell,
// Applications, Windows, Columns, Workspaces, …) chosen from the action.
// ─────────────────────────────────────────────────────────────────────────
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../services"

OverlayWindow {
    id: keybindViewer
    WlrLayershell.namespace: "keybinds"

    panelWidth:  width > 0 ? Math.min(width * 0.82, 1400) : 1200
    panelHeight: height > 0 ? height * 0.78 : 700

    // ── File reader ──────────────────────────────────────────────────────
    property string rawContent: ""

    Process {
        id: reader
        command: ["python3", Quickshell.shellDir + "/scripts/parse-niri-binds.py"]
        property string buf: ""
        onRunningChanged: {
            if (running) buf = ""
            else {
                keybindViewer.rawContent = buf
                keybindViewer._parse()
            }
        }
        stdout: SplitParser { onRead: data => reader.buf += data + "\n" }
    }

    onShownChanged: {
        if (shown) {
            reader.running = true
            keyHandler.forceActiveFocus()
        }
    }

    // ── Parsed model ─────────────────────────────────────────────────────
    // Each element: { section: "...", key: "...", action: "..." }
    // Section headers become dividers in the grid.
    property var binds: []
    property var leftBinds: []
    property var rightBinds: []

    function _parse() {
        // The helper prints a JSON array of { section, key, action }.
        let result = []
        try {
            let parsed = JSON.parse(rawContent.trim() || "[]")
            if (Array.isArray(parsed)) result = parsed
        } catch (e) {
            console.warn("KeybindViewer: could not parse niri keybinds -", e)
        }
        binds = result
        _splitColumns()
    }

    function _splitColumns() {
        // Split binds into two columns, trying to break at a section boundary
        // near the midpoint so sections don't get split across columns.
        let mid = Math.ceil(binds.length / 2)

        // Search for a section boundary near mid (prefer keeping sections intact)
        let bestSplit = mid
        for (let offset = 0; offset < Math.min(8, mid); offset++) {
            let idx = mid + offset
            if (idx < binds.length && idx > 0 && binds[idx].section !== binds[idx - 1].section) {
                bestSplit = idx
                break
            }
            idx = mid - offset
            if (idx > 0 && idx < binds.length && binds[idx].section !== binds[idx - 1].section) {
                bestSplit = idx
                break
            }
        }

        leftBinds  = binds.slice(0, bestSplit)
        rightBinds = binds.slice(bestSplit)
    }

    // ── Visual ───────────────────────────────────────────────────────────
    Item {
        id: keyHandler
        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                keybindViewer.hide()
                event.accepted = true
            }
        }

        // Header
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 0

            // ── Title row ────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 16

                Text {
                    text: "⌨  Keybindings"
                    color: Theme.onPrimaryContainerColor
                    font.pixelSize: 22
                    font.weight: Font.Bold
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: "ESC to close"
                    color: Qt.rgba(Theme.onPrimaryContainerColor.r,
                                   Theme.onPrimaryContainerColor.g,
                                   Theme.onPrimaryContainerColor.b, 0.45)
                    font.pixelSize: 13
                }
            }

            // Thin separator
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(Theme.outlineVariant.r, Theme.outlineVariant.g, Theme.outlineVariant.b, 0.5)
                Layout.bottomMargin: 12
            }

            // ── Scrollable two-column grid ─────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Subtle background behind the list area
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.radiusSmall
                    color: Qt.rgba(Theme.surfaceVariant.r,
                                   Theme.surfaceVariant.g,
                                   Theme.surfaceVariant.b, 0.15)
                }

                Flickable {
                    id: flick
                    anchors.fill: parent
                    anchors.rightMargin: 10   // leave room for scrollbar
                    contentHeight: twoColRow.implicitHeight + 24
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.VerticalFlick

                    // ── Two columns side by side ─────────────────────
                    Row {
                        id: twoColRow
                        width: flick.width
                        spacing: 0
                        y: 12  // top padding

                        // ── Left column ──────────────────────────────
                        ColumnLayout {
                            width: (twoColRow.width - divider.width - 24) / 2
                            spacing: 4

                            Repeater {
                                model: keybindViewer.leftBinds.length

                                delegate: ColumnLayout {
                                    required property int index
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        visible: index === 0 || keybindViewer.leftBinds[index].section !== keybindViewer.leftBinds[index - 1].section
                                        Layout.fillWidth: true
                                        Layout.topMargin: index > 0 ? 16 : 4
                                        Layout.bottomMargin: 6
                                        Layout.leftMargin: 8
                                        text: keybindViewer.leftBinds[index] ? keybindViewer.leftBinds[index].section : ""
                                        color: Theme.primary
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        font.letterSpacing: 0.8
                                    }

                                    KeybindRow {
                                        bindSource: keybindViewer.leftBinds
                                        bindIndex: index
                                        Layout.fillWidth: true
                                    }
                                }
                            }
                        }

                        // ── Vertical divider ─────────────────────────
                        Rectangle {
                            id: divider
                            width: 1
                            height: Math.max(
                                twoColRow.children[0].implicitHeight,
                                twoColRow.children[2] ? twoColRow.children[2].implicitHeight : 0
                            )
                            anchors.margins: 12
                            color: Qt.rgba(Theme.outlineVariant.r,
                                           Theme.outlineVariant.g,
                                           Theme.outlineVariant.b, 0.35)
                        }

                        // Spacer for divider margins
                        Item { width: 24; height: 1 }

                        // ── Right column ─────────────────────────────
                        ColumnLayout {
                            width: (twoColRow.width - divider.width - 24) / 2
                            spacing: 4

                            Repeater {
                                model: keybindViewer.rightBinds.length

                                delegate: ColumnLayout {
                                    required property int index
                                    Layout.fillWidth: true
                                    spacing: 4

                                    Text {
                                        visible: index === 0 || keybindViewer.rightBinds[index].section !== keybindViewer.rightBinds[index - 1].section
                                        Layout.fillWidth: true
                                        Layout.topMargin: index > 0 ? 16 : 4
                                        Layout.bottomMargin: 6
                                        Layout.leftMargin: 8
                                        text: keybindViewer.rightBinds[index] ? keybindViewer.rightBinds[index].section : ""
                                        color: Theme.primary
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        font.letterSpacing: 0.8
                                    }

                                    KeybindRow {
                                        bindSource: keybindViewer.rightBinds
                                        bindIndex: index
                                        Layout.fillWidth: true
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Scrollbar ────────────────────────────────────────
                Rectangle {
                    id: scrollTrack
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: 4
                    width: 4
                    radius: 2
                    color: Qt.rgba(Theme.outlineVariant.r,
                                   Theme.outlineVariant.g,
                                   Theme.outlineVariant.b, 0.15)
                    visible: flick.contentHeight > flick.height

                    Rectangle {
                        id: scrollThumb
                        width: parent.width
                        radius: 2
                        color: Qt.rgba(Theme.primary.r,
                                       Theme.primary.g,
                                       Theme.primary.b,
                                       thumbMouse.containsMouse || thumbMouse.pressed ? 0.7 : 0.35)
                        Behavior on color { ColorAnimation { duration: 150 } }

                        // Thumb size proportional to visible fraction
                        property real ratio: flick.height / flick.contentHeight
                        height: Math.max(30, scrollTrack.height * ratio)

                        // Thumb position tracks flick position
                        y: flick.contentHeight > flick.height
                           ? (flick.contentY / (flick.contentHeight - flick.height))
                             * (scrollTrack.height - height)
                           : 0

                        MouseArea {
                            id: thumbMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            drag.target: parent
                            drag.axis: Drag.YAxis
                            drag.minimumY: 0
                            drag.maximumY: scrollTrack.height - scrollThumb.height

                            onPositionChanged: {
                                if (pressed) {
                                    let fraction = scrollThumb.y / (scrollTrack.height - scrollThumb.height)
                                    flick.contentY = fraction * (flick.contentHeight - flick.height)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Keybind row component ────────────────────────────────────────────
    component KeybindRow: Rectangle {
        property var bindSource: []
        property int bindIndex: 0

        implicitHeight: 38
        radius: Theme.radiusSmall
        color: rowMouse.containsMouse
               ? Qt.rgba(Theme.onPrimaryContainerColor.r,
                         Theme.onPrimaryContainerColor.g,
                         Theme.onPrimaryContainerColor.b, 0.08)
               : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }

        MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 16

            // Key badges
            Row {
                spacing: 6
                Layout.preferredWidth: parent.width * 0.42
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter

                Repeater {
                    model: bindSource[bindIndex]
                           ? bindSource[bindIndex].key.split(/\s*\+\s*/)
                           : []

                    delegate: Rectangle {
                        required property string modelData

                        width: keyLabel.implicitWidth + 18
                        height: 26
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 6
                        color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)
                        border.width: 1
                        border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35)

                        Text {
                            id: keyLabel
                            anchors.centerIn: parent
                            text: _prettyKey(modelData)
                            color: Theme.onPrimaryContainerColor
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            font.family: "monospace"
                        }

                        function _prettyKey(k) {
                            k = k.trim()
                            if (k === "return") return "↵"
                            if (k === "RETURN") return "↵"
                            if (k === "PRINT")  return "PrtSc"
                            if (k === "Next")   return "PgDn"
                            if (k === "Prior")  return "PgUp"
                            if (k === "left")   return "←"
                            if (k === "right")  return "→"
                            if (k === "up")     return "↑"
                            if (k === "down")   return "↓"
                            if (k === "mouse:272") return "LMB"
                            if (k === "mouse:273") return "RMB"
                            if (k === "mouse_down") return "Scroll ↓"
                            if (k === "mouse_up")   return "Scroll ↑"
                            if (k === "bracketright") return "]"
                            if (k === "bracketleft")  return "["
                            if (k.startsWith("XF86Audio"))  return k.replace("XF86Audio", "🔊 ")
                            if (k.startsWith("XF86MonBrightness")) return k.replace("XF86MonBrightness", "🔆 ")
                            if (k === "SPACE" || k === "Space") return "␣"
                            if (k === "ESCAPE" || k === "escape") return "Esc"
                            return k
                        }
                    }
                }
            }

            // Action description
            Text {
                Layout.fillWidth: true
                Layout.fillHeight: true
                verticalAlignment: Text.AlignVCenter
                text: bindSource[bindIndex]
                      ? bindSource[bindIndex].action
                      : ""
                color: Qt.rgba(Theme.onPrimaryContainerColor.r,
                               Theme.onPrimaryContainerColor.g,
                               Theme.onPrimaryContainerColor.b, 0.85)
                font.pixelSize: 14
                elide: Text.ElideRight
            }
        }
    }
}
