import AppKit
import SwiftUI
import UserNotifications

@main
struct SWIFTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // `Window`, not `WindowGroup`, so "Open" focuses the one window rather
        // than spawning duplicates. macOS autosaves a window's frame per scene
        // id, so changing an id discards a saved frame.
        Window("SWIFT", id: "main-window") {
            RootView()
                .environment(model)
                // A height range is required: with none, `.contentSize`
                // resizability pins height to the content's ideal size and the
                // window reads as not resizable at all.
                //
                // `alignment: .top` must be repeated here — RootView's own
                // frame alignment does not survive being re-wrapped by this
                // outer frame, and without it SwiftUI centres the content
                // whenever the window is taller than its natural size.
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 640,
                       minHeight: 280, maxHeight: 900, alignment: .top)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)   // honour the width bounds above
        .defaultSize(width: 460, height: 700)
        .commands { AppCommands(model: model) }

        // Menu-bar presence: usable without the window in front.
        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        // A `Window`, not the `Settings` scene: a Settings window keeps an
        // opaque native title bar that `.hiddenTitleBar` cannot override, so it
        // could never match the app's glass chrome.
        Window("Settings", id: "settings-panel") {
            SettingsView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 520)
    }
}

/// Ensures the app behaves as a normal foreground app when launched via
/// `swift run` (no bundle). Harmless when run from a proper .app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the model so quitting can withdraw the Quick Share announcement.
    @MainActor static var onTerminate: (@MainActor () -> Void)?

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        Self.onTerminate?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.launchedAtLogin() {
            // Started by macOS at login: stay in the menu bar, no window.
            NSApp.setActivationPolicy(.accessory)
            Self.hideMainWindow()
        } else {
            NSApp.setActivationPolicy(.regular)   // show the window + Dock icon on launch
            NSApp.activate(ignoringOtherApps: true)
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: "show", title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "transfer-received", actions: [show], intentIdentifiers: []),
            UNNotificationCategory(identifier: "transfer-sent", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "transfer-failed", actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Self.enableShareExtension()
    }

    /// True when macOS started the app because it is a login item.
    private static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let openApplication: AEEventID = 0x6F617070   // 'oapp'
        let propData: AEKeyword = 0x70726474          // 'prdt'
        let loggedIn: UInt32 = 0x6C676974             // 'lgit'
        return event.eventID == openApplication
            && event.paramDescriptor(forKeyword: propData)?.enumCodeValue == loggedIn
    }

    /// The window opens a moment after launch, so close it a few times.
    private static func hideMainWindow() {
        for delay in [0.2, 0.7, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for window in NSApp.windows where window.identifier?.rawValue == "main-window" {
                    window.close()
                }
            }
        }
    }

    /// The share sheet lists SWIFT next to AirDrop only after this Mac has
    /// switched the extension on. A fresh install does that the first time
    /// the app opens, for every app that can share.
    private static func enableShareExtension() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", "use", "-i", "app.swift.mac.share"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // The Help menu can't be removed here — AppKit reinstates it after launch.
    // `CommandGroup(replacing: .help) {}` removes its one dead item instead.

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window drops the app to a menu-bar-only agent (no Dock icon).
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        await MainActor.run { TransferNotifier.reveal(paths) }
    }
}

// MARK: - Menu commands

/// Clears out the standard commands this app can't act on.
///
/// Split into its own type because `CommandsBuilder`, like `ViewBuilder`, caps
/// how many children one block may have.
private struct InertDefaultsRemoved: Commands {
    var body: some Commands {
        // The name fields use the standard edit commands. The rest of the
        // document-app menu still has nothing to do here.
        // No `.textFormatting` replacement: an empty group would *create* a
        // Format menu rather than remove one. AppDelegate prunes it instead,
        // since that's the only thing that actually works.
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .help) {}
        // No documents, so New and Open have nothing to act on.
        CommandGroup(replacing: .newItem) {}
    }
}

/// The menu bar.
///
/// SwiftUI's defaults assume a document app with text editing, a toolbar, and
/// a sidebar. This app has none of those, so the Edit and View menus are
/// pared down to only the commands that actually do something here.
struct AppCommands: Commands {
    /// Plain, not `@ObservedObject`: under Observation a view re-evaluates
    /// because it *read* a property, so no wrapper is needed to observe.
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {

        InertDefaultsRemoved()

        // MARK: SWIFT

        CommandGroup(after: .appInfo) {
            Button("Build Info…") { model.showingBuildInfo = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }

        // Settings is a plain Window (see SWIFTApp), not the Settings
        // scene, so we supply its usual ⌘, menu item ourselves.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings-panel") }
                .keyboardShortcut(",", modifiers: .command)
        }

        // MARK: File

        CommandGroup(replacing: .saveItem) {
            Button("Open Downloads Folder") { model.openDownloadsFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            // Recent files, newest first. Entries whose file has since been
            // moved or deleted are shown disabled rather than silently failing.
            if model.recentFiles.isEmpty {
                Text("No Recent Files")
            } else {
                ForEach(model.recentFiles) { file in
                    Button(file.name) { model.openRecentFile(file) }
                        .disabled(!file.stillExists)
                }
                Divider()
                Button("Clear Menu") { model.clearRecentFiles() }
            }
        }

        // MARK: View
        //
        // Replaces the sidebar group, which lives in the View menu and did
        // nothing here.

        CommandGroup(replacing: .sidebar) {
            Button("Send") { model.mode = .send }
                .keyboardShortcut("1", modifiers: .command)
            Button("Receive") { model.mode = .receive }
                .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button(model.wantsVisible ? "Stop Being Visible" : "Be Visible to Nearby Devices") {
                model.toggleVisibility()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button("Clear Completed Transfers") { model.clearFinishedTransfers() }
                .disabled(!model.transfers.contains { $0.phase.isTerminal })
        }

        // MARK: Window
        //
        // Ours rather than macOS's tiling: this window has a hard width cap, so
        // "Left Half" would only ever produce a clamped window in roughly the
        // right place. These keep the app's width and grow it to full height.

        CommandGroup(after: .windowSize) {
            Divider()
            Button("Snap Left") { WindowPlacement.snap(to: .left) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Button("Snap Right") { WindowPlacement.snap(to: .right) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("Center Window") { WindowPlacement.center() }
        }
    }
}

// MARK: - Window snapping

/// Window placement that respects the app's own width.
///
/// macOS's built-in "Left Half" tiling tries to make the window half the screen
/// wide; this window has a hard width cap, so the result is a clamped window in
/// roughly the right place and the tiling looks broken. These commands move and
/// grow the window vertically only, which is what "snap to the side" should mean
/// for a fixed-width utility.
@MainActor
enum WindowPlacement {

    enum Edge {
        case left, right
    }

    static func snap(to edge: Edge) {
        guard let window = targetWindow(), let screen = screen(for: window) else { return }
        let area = screen.visibleFrame          // excludes the menu bar and Dock
        var frame = window.frame

        frame.size.height = area.height
        frame.origin.y = area.minY
        frame.origin.x = edge == .left ? area.minX : area.maxX - frame.width

        window.setFrame(frame, display: true, animate: true)
    }

    static func center() {
        targetWindow()?.center()
    }

    /// Identifier of the `Window(id:)` scene in `SWIFTApp`.
    private static let mainWindowID = "main-window"

    /// The main window, identified explicitly.
    ///
    /// Matching on identifier rather than "first visible non-panel": the app
    /// also owns an `NSStatusBarWindow` for the menu-bar item, which is not an
    /// `NSPanel` and would otherwise be a candidate — snapping the status item
    /// to the side of the screen is not what anyone wants. It also keeps
    /// Settings out of scope, whatever class SwiftUI gives it.
    private static func targetWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == mainWindowID && $0.isVisible }
    }

    private static func screen(for window: NSWindow) -> NSScreen? {
        window.screen ?? NSScreen.main
    }
}
