import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

Item {
    Component.onCompleted: {
        for (let i = 0; i < SystemTray.items.length; i++) {
            let item = SystemTray.items[i];
            if (item.hasMenu && item.menu) {
                console.log("Found menu for:", item.id);
                console.log("Menu has items:", item.menu.items.length);
                if (item.menu.items.length > 0) {
                    let mi = item.menu.items[0];
                    console.log("Item 0 keys:", Object.keys(mi));
                }
                break;
            }
        }
    }
}
