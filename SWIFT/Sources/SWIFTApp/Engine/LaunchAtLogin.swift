import Foundation
import ServiceManagement

/// Starting SWIFT when the person logs in, quietly in the menu bar.
enum LaunchAtLogin {
    /// Only a copy kept in an Applications folder. A build running from a
    /// project folder must never register itself.
    static func isInstalledCopy(path: String = Bundle.main.bundlePath,
                                home: String = NSHomeDirectory()) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app" else { return false }
        let folder = url.deletingLastPathComponent().path
        return folder == "/Applications" || folder == home + "/Applications"
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS asked the person to allow it in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
