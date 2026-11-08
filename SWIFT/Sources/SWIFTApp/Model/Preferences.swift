import CryptoKit
import Foundation
import Security
import SWIFTCore

/// Everything SWIFT persists, and the migrations between older shapes of it.
///
/// Split out of `AppModel` so the view model states *what* it wants remembered
/// and this states *how*. Keys live here and nowhere else.
struct Preferences {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let downloadDirectory = "downloadDirectoryPath"
        static let startVisible = "startVisible"
        static let appearance = "appearance"
        static let controlAPIEnabled = "controlAPIEnabled"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardToken = "clipboardToken"
        static let clipboardIdentity = "clipboardIdentity"
        static let clipboardPhones = "clipboardPhones"
        static let clipboardPairCode = "clipboardPairCode"
        static let knownDevices = "knownDevices"
        static let pairedPhones = "pairedPhones"
        static let removedPhones = "removedPhones"
        static let recentFiles = "recentFiles"
        static let deviceName = "deviceName"
        static let endpointID = "quickShareEndpointID"
        static let peerMemory = "peerMemory"
        static let deviceNicknames = "deviceNicknames"
        // Earlier shapes of the known-devices list, migrated on load.
        static let legacyKnownNames = "knownDeviceNames"
        static let legacyTrustedNames = "trustedDeviceNames"
    }

    // MARK: Settings

    var downloadDirectory: URL? {
        get { defaults.string(forKey: Key.downloadDirectory).map { URL(fileURLWithPath: $0) } }
        nonmutating set { defaults.set(newValue?.path, forKey: Key.downloadDirectory) }
    }

    /// Absent means on. A paired Mac should already be ready to receive; the
    /// user should not have to open SWIFT and switch to Receive first.
    var startVisible: Bool {
        get {
            if defaults.object(forKey: Key.startVisible) == nil { return true }
            return defaults.bool(forKey: Key.startVisible)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.startVisible) }
    }

    /// The 4-character Quick Share id this Mac advertises. Created once and kept,
    /// so a relaunch replaces the phone's entry instead of adding a second Mac.
    var endpointID: [UInt8] {
        if let saved = defaults.string(forKey: Key.endpointID), SWIFTEngine.isValidEndpointID(Array(saved.utf8)) {
            return Array(saved.utf8)
        }
        let fresh = SWIFTEngine.makeEndpointID()
        defaults.set(String(decoding: fresh, as: UTF8.self), forKey: Key.endpointID)
        return fresh
    }

    /// Names learned for nearby phones.
    var peerMemory: PeerMemory {
        get {
            guard let data = defaults.data(forKey: Key.peerMemory),
                  let peers = try? JSONDecoder().decode([RememberedPeer].self, from: data) else {
                return PeerMemory()
            }
            return PeerMemory(peers: peers)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.peers) else { return }
            defaults.set(data, forKey: Key.peerMemory)
        }
    }

    var controlAPIEnabled: Bool {
        get { defaults.bool(forKey: Key.controlAPIEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.controlAPIEnabled) }
    }

    var clipboardEnabled: Bool {
        get { defaults.bool(forKey: Key.clipboardEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.clipboardEnabled) }
    }

    /// Created the first time clipboard sync is turned on. The phone stores it
    /// after pairing; it is the only credential that can write the pasteboard.
    func clipboardToken() -> String {
        if let existing = defaults.string(forKey: Key.clipboardToken), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let token: String
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            token = bytes.map { String(format: "%02x", $0) }.joined()
        } else {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        defaults.set(token, forKey: Key.clipboardToken)
        return token
    }

    /// This Mac's clipboard key pair, made once. Only the public half leaves the Mac.
    func clipboardIdentity() -> P256.KeyAgreement.PrivateKey {
        if let raw = defaults.data(forKey: Key.clipboardIdentity),
           let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = P256.KeyAgreement.PrivateKey()
        defaults.set(key.rawRepresentation, forKey: Key.clipboardIdentity)
        return key
    }

    var clipboardPhones: [ClipboardPhone] {
        get {
            guard let data = defaults.data(forKey: Key.clipboardPhones),
                  let phones = try? JSONDecoder().decode([ClipboardPhone].self, from: data) else { return [] }
            return phones
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.clipboardPhones)
            }
        }
    }

    /// Eight digits the phone can type when it finds this Mac over Bonjour.
    func clipboardPairCode() -> String {
        if let existing = defaults.string(forKey: Key.clipboardPairCode),
           existing.count == 8, existing.allSatisfy(\.isNumber) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let code = String(format: "%08d", Int(value % 100_000_000))
        defaults.set(code, forKey: Key.clipboardPairCode)
        return code
    }

    var appearance: AppAppearance {
        get {
            defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    // MARK: Known devices

    /// Loads the list, migrating the two earlier storage shapes.
    ///
    /// Those were plain arrays of names with no per-device choice, so everything
    /// migrated arrives with auto-accept **off**. An upgrade must never switch
    /// it on for someone.
    func loadKnownDevices() -> [KnownDevice] {
        if let data = defaults.data(forKey: Key.knownDevices),
           let decoded = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            return decoded
        }
        var migrated: [String] = defaults.stringArray(forKey: Key.legacyKnownNames) ?? []
        migrated += defaults.stringArray(forKey: Key.legacyTrustedNames) ?? []
        defaults.removeObject(forKey: Key.legacyKnownNames)
        defaults.removeObject(forKey: Key.legacyTrustedNames)
        return Array(Set(migrated)).sorted().map { KnownDevice(name: $0, autoAccept: false) }
    }

    func loadPairedPhones() -> [String] {
        defaults.stringArray(forKey: Key.pairedPhones) ?? []
    }

    func save(pairedPhones: [String]) {
        defaults.set(pairedPhones, forKey: Key.pairedPhones)
    }

    func loadRemovedPhones() -> [String] {
        defaults.stringArray(forKey: Key.removedPhones) ?? []
    }

    func save(removedPhones: [String]) {
        defaults.set(removedPhones, forKey: Key.removedPhones)
    }

    func save(knownDevices: [KnownDevice]) {
        guard let data = try? JSONEncoder().encode(knownDevices) else { return }
        defaults.set(data, forKey: Key.knownDevices)
    }

    // MARK: Recent files

    func loadRecentFiles() -> [RecentFile] {
        guard let data = defaults.data(forKey: Key.recentFiles),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) else {
            return []
        }
        return decoded
    }

    func save(recentFiles: [RecentFile]) {
        guard let data = try? JSONEncoder().encode(recentFiles) else { return }
        defaults.set(data, forKey: Key.recentFiles)
    }

    // MARK: Names

    /// The name this Mac advertises. Empty means "use the system name".
    var deviceName: String? {
        get { defaults.string(forKey: Key.deviceName) }
        nonmutating set { defaults.set(newValue, forKey: Key.deviceName) }
    }

    func loadNicknames() -> [String: String] {
        guard let data = defaults.data(forKey: Key.deviceNicknames),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func save(nicknames: [String: String]) {
        guard let data = try? JSONEncoder().encode(nicknames) else { return }
        defaults.set(data, forKey: Key.deviceNicknames)
    }

    /// A name the person typed for a device, matched against what it advertises now.
    func nickname(matching raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let map = loadNicknames()
        if let exact = map.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value {
            return exact
        }
        for (seen, alias) in map {
            if DeviceName.isShorterPiece(name, of: alias) || DeviceName.isShorterPiece(name, of: seen) {
                return alias
            }
        }
        return nil
    }

    func rememberNickname(_ alias: String, seenAs name: String) {
        var map = loadNicknames()
        let keys = map.keys.filter {
            $0.caseInsensitiveCompare(name) != .orderedSame
                && map[$0]?.caseInsensitiveCompare(name) == .orderedSame
        }
        map[name] = alias
        for key in keys { map[key] = alias }
        save(nicknames: map)
    }
}

// MARK: - Build identity

/// Identifies exactly which build is running.
///
/// The values are stamped into the bundle's Info.plist by `build-app.sh`. A
/// binary run outside a bundle (`swift run`) has none of them, and says so
/// rather than inventing a number.
enum BuildInfo {

    /// Marketing version, e.g. "0.1 alpha".
    static let version: String = {
        let short = string(for: "CFBundleShortVersionString") ?? "0.1"
        let stage = string(for: "SWIFTReleaseStage") ?? "alpha"
        return "\(short) \(stage)"
    }()

    /// Monotonic build counter, incremented by every packaging run.
    static let build: String = string(for: "CFBundleVersion") ?? "—"

    /// Short git SHA the build came from; the unambiguous identifier.
    static let commit: String = string(for: "SWIFTGitCommit") ?? "—"

    /// When the bundle was assembled.
    static let builtAt: String = string(for: "SWIFTBuildDate") ?? "—"

    /// True when running from a proper .app rather than `swift run`.
    static var isPackaged: Bool { string(for: "CFBundleVersion") != nil }

    /// One-line summary, matching what the debug panel shows.
    static var summary: String { "\(version) · build \(build) · \(commit)" }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String,
              !value.isEmpty,
              // Unsubstituted placeholders are not information.
              !value.hasPrefix("__") else { return nil }
        return value
    }
}
