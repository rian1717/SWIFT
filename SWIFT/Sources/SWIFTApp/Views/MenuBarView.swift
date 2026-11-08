import SwiftUI
import AppKit

/// Contents of the menu-bar item. Lets you toggle receiving, open the main
/// window, and quit — so the app is useful without its window in front.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.availableDevices.isEmpty {
            Text("Looking for devices…")
        } else {
            if !model.myDevices.isEmpty {
                Text("My devices")
                ForEach(model.myDevices) { device in
                    Button {
                        sendTo(device)
                    } label: {
                        Label(device.name, systemImage: device.type.symbol)
                    }
                }
            }
            if !model.nearbyDevices.isEmpty {
                Text("Nearby")
                ForEach(model.nearbyDevices) { device in
                    Button {
                        sendTo(device)
                    } label: {
                        Label(device.name, systemImage: device.type.symbol)
                    }
                }
            }
        }
        Divider()

        // Follows intent so it responds immediately; the icon reflects whether
        // advertising actually came up.
        Toggle("Receive files (visible)", isOn: Binding(
            get: { model.wantsVisible },
            set: { model.setVisible($0) }
        ))

        if model.clipboardEnabled {
            Text(model.clipboardStatus)
        }

        let active = model.transfers.filter { $0.phase == .transferring }.count
        if active > 0 {
            Divider()
            Text(active == 1 ? "1 transfer in progress" : "\(active) transfers in progress")
        }

        Divider()
        Button("Open SWIFT") { openMainWindow() }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit SWIFT") { NSApp.terminate(nil) }
            .keyboardShortcut("q")

        // Not a menu item — just where the model (which
        // can't call the View-only `openWindow` action itself) reaches a
        // View that can, so an incoming request reopens a closed window
        // instead of only reordering an already-open one.
        EmptyView().onChange(of: model.incomingActivityToken) { _, _ in openMainWindow() }
    }

    /// Open the window straight into the drop-zone targeting `device`.
    private func sendTo(_ device: RemoteDevice) {
        model.prepareSend(to: device)
        openMainWindow()
    }

    private func openMainWindow() {
        NSApp.setActivationPolicy(.regular)   // restore Dock icon while the window is up
        openWindow(id: "main-window")
        NSApp.activate(ignoringOtherApps: true)
    }
}
