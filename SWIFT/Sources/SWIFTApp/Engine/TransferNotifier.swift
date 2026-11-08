import AppKit
import Foundation
import UserNotifications

/// The result of a transfer, shown in the window and in Notification Center.
struct TransferNotice: Identifiable, Equatable {
    enum Kind: Equatable { case received, sent, failed }
    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
    /// Files to reveal in Finder. Empty unless this Mac received them.
    var paths: [String]
}

/// Posts a transfer result the person can see even when the window is closed.
enum TransferNotifier {
    static func post(_ notice: TransferNotice) {
        // Unit tests run under xctest, which has no notification bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.message
        content.sound = .default
        switch notice.kind {
        case .received:
            content.categoryIdentifier = "transfer-received"
            content.userInfo = ["paths": notice.paths]
        case .sent:
            content.categoryIdentifier = "transfer-sent"
        case .failed:
            content.categoryIdentifier = "transfer-failed"
        }
        let request = UNNotificationRequest(
            identifier: notice.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
