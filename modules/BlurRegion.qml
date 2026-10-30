import QtQuick
import Quickshell
import Quickshell.Wayland
import "../services"

// Shared helper component for background blur on Quickshell surfaces.
// Exposes the active Region when blur is globally enabled and active,
// or null when disabled so no stale blur remains on the compositor.
Item {
    id: root

    // Visible panel item whose geometry and position the blur region will follow
    property Item target: null

    // Corner radius matching the panel item's radius
    property real radius: 0

    // Additional condition (e.g. window is shown, panel is not fully transparent, etc.)
    property bool active: true

    // Optional multi-piece custom region (for windows with multiple separate pieces)
    property Region customRegion: null

    readonly property bool debugMode: Quickshell.env("XEON_BLUR_DEBUG") === "1"

    // The resolved Region object when blur is enabled and active, or null when disabled
    readonly property Region region: (Config.blurEnabled && root.active)
        ? (root.customRegion ? root.customRegion : (root.target ? defaultRegion : null))
        : null

    Region {
        id: defaultRegion
        item: root.target
        radius: root.radius
        onChanged: {
            if (root.debugMode) {
                console.log("[BlurRegion DEBUG] Region changed: target=" + root.target
                    + " active=" + root.active
                    + " radius=" + root.radius
                    + " geom=" + (root.target ? ("[" + Math.round(root.target.x) + "," + Math.round(root.target.y) + " " + Math.round(root.target.width) + "x" + Math.round(root.target.height) + "]") : "none"));
            }
        }
    }

    // Debug logging & null-region warning
    onActiveChanged: _checkRegion()
    onRegionChanged: _checkRegion()
    Component.onCompleted: _checkRegion()

    function _checkRegion() {
        if (!debugMode) return;
        if (root.active && !root.region) {
            console.warn("[BlurRegion WARN] Visible surface committed null/empty region! target=" + root.target);
        } else if (root.region) {
            console.log("[BlurRegion DEBUG] Active region on target=" + root.target
                + " active=" + root.active
                + " radius=" + root.radius
                + " geom=" + (root.target ? ("[" + Math.round(root.target.x) + "," + Math.round(root.target.y) + " " + Math.round(root.target.width) + "x" + Math.round(root.target.height) + "]") : "none"));
        }
    }

    // Debug 2px red outline over the exact geometry used by the region
    Rectangle {
        id: debugOutline
        visible: root.debugMode && root.region !== null && root.target !== null
        parent: root.target ? root.target.parent : root
        x: root.target ? root.target.x : 0
        y: root.target ? root.target.y : 0
        width: root.target ? root.target.width : 0
        height: root.target ? root.target.height : 0
        radius: root.radius
        color: "transparent"
        border.color: "red"
        border.width: 2
        z: 999999
    }
}
