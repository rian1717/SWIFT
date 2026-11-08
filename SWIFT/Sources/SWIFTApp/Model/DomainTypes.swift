import Foundation

/// A device we can share with (discovered over the network) or that is sharing
/// with us. Mirrors `SWIFTDevice` in the protocol layer.
struct RemoteDevice: Identifiable, Hashable {
    let id: String
    var name: String
    var type: DeviceType
    /// Set when this row is the SWIFT app on a paired phone, not Quick Share.
    var companionHost: String? = nil
    var companionPort: Int? = nil

    var isCompanion: Bool { companionHost != nil && companionPort != nil }
}

enum DeviceType: String, CaseIterable {
    case phone
    case tablet
    case computer
    case unknown

    /// SF Symbol used to represent the device in lists.
    var symbol: String {
        switch self {
        case .phone:    return "iphone.gen3"
        case .tablet:   return "ipad"
        case .computer: return "laptopcomputer"
        case .unknown:  return "questionmark.circle"
        }
    }
}

// MARK: - Transfers

/// One file queued or in flight.
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var sizeBytes: Int64

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Direction of a transfer relative to *this* Mac.
enum TransferDirection {
    case incoming   // Android -> Mac
    case outgoing   // Mac -> Android
}

/// A request from a remote device to send us files. The user must accept/decline.
struct IncomingRequest: Identifiable {
    let id: String            // transfer id from the protocol layer
    let device: RemoteDevice
    let fileNames: [String]
    let totalBytes: Int64
    let pin: String

    var summary: String {
        if fileNames.count == 1 { return fileNames[0] }
        return "\(fileNames.count) files"
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// Lifecycle of an active transfer.
enum TransferPhase: Equatable {
    case connecting
    case awaitingConsent   // waiting for the remote user to accept
    case transferring
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// One file within a transfer. `url` is set once we know where it lives on disk
/// (source path for outgoing; saved path for incoming, resolved on completion).
struct TransferFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var url: URL? = nil
}

/// A transfer shown in the UI, incoming or outgoing.
struct ActiveTransfer: Identifiable {
    let id: String
    let direction: TransferDirection
    var deviceName: String
    var title: String        // e.g. "photo.jpg" or "3 files"
    var totalBytes: Int64
    var fraction: Double = 0
    var phase: TransferPhase
    var files: [TransferFile] = []

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Files that exist on disk and can be opened/revealed.
    var openableFiles: [TransferFile] { files.filter { $0.url != nil } }

    /// The single item to reveal for the whole transfer (its containing folder).
    var revealURL: URL? { openableFiles.first?.url }
}

// MARK: - Known senders

/// A sender we've accepted from before.
///
/// Identified by advertised name, which is all Quick Share gives us — see the
/// note on `AppModel.knownDevices` for what that does and doesn't guarantee.
struct KnownDevice: Codable, Identifiable, Hashable {
    var name: String
    /// Accept files from this sender without asking.
    var autoAccept: Bool

    var id: String { name }
}

// MARK: - Recent files

/// A file that recently moved through the app, in either direction.
///
/// Persisted so the File menu is still useful after a relaunch — a recents list
/// that empties every launch isn't one.
struct RecentFile: Codable, Identifiable, Hashable {
    let name: String
    /// Stored as a path rather than a URL so the plist stays readable.
    let path: String
    let receivedAt: Date
    let wasIncoming: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    /// The file may have been moved or deleted since; the menu checks this.
    var stillExists: Bool { FileManager.default.fileExists(atPath: path) }
}
