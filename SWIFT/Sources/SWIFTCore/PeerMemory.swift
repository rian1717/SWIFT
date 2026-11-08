import Foundation

/// A name this Mac has learned for a phone, and the Wi-Fi hardware address it
/// belongs to.
public struct RememberedPeer: Codable, Equatable, Sendable {
    public var hardware: String
    public var name: String
    public var lastSeen: Date
}

/// Phones this Mac has met, so a phone that later hides its name keeps it.
///
/// Quick Share's service name and a phone's IP address both change. The Wi-Fi
/// hardware address normally stays the same for a phone on a given network.
/// A remembered name is only a label: it is self-reported by the phone and never
/// replaces the PIN or the receiver's consent.
public struct PeerMemory: Equatable, Sendable {
    public private(set) var peers: [RememberedPeer]
    static let capacity = 200

    public init(peers: [RememberedPeer] = []) {
        self.peers = peers
    }

    public func name(hardware: String) -> String? {
        peers.first { $0.hardware == hardware }?.name
    }

    /// Stores a name. Returns true when what is displayed would change.
    @discardableResult
    public mutating func learn(name: String, hardware: String, now: Date = Date()) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLearnable(clean) else { return false }
        var changed = true
        if let index = peers.firstIndex(where: { $0.hardware == hardware }) {
            changed = peers[index].name != clean
            // "Pixel 8" after "Rai's Pixel 8" is the model, not a better name.
            if DeviceName.isShorterPiece(clean, of: peers[index].name) { return false }
            peers[index].name = clean
            peers[index].lastSeen = now
        } else {
            peers.append(RememberedPeer(hardware: hardware, name: clean, lastSeen: now))
        }
        if peers.count > Self.capacity {
            peers.sort { $0.lastSeen > $1.lastSeen }
            peers.removeLast(peers.count - Self.capacity)
        }
        return changed
    }

    static func isLearnable(_ name: String) -> Bool {
        !name.isEmpty && name != DeviceName.unnamed && name != "Unknown device" && name != "Scanned device"
            && DeviceName.isPossiblePhoneName(name)
    }
}

/// Reads the Wi-Fi hardware address of a host on this network.
public enum HardwareAddress {
    /// Pulls a normalized address from one line of `arp -n` output.
    static func parse(arpOutput: String) -> String? {
        guard let atRange = arpOutput.range(of: " at ") else { return nil }
        let token = arpOutput[atRange.upperBound...].prefix { !$0.isWhitespace }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [String] = []
        for part in parts {
            guard (1...2).contains(part.count), UInt8(part, radix: 16) != nil else { return nil }
            bytes.append(part.count == 1 ? "0" + part.lowercased() : part.lowercased())
        }
        let joined = bytes.joined(separator: ":")
        guard joined != "ff:ff:ff:ff:ff:ff", joined != "00:00:00:00:00:00" else { return nil }
        return joined
    }

    /// Valid after this Mac has exchanged packets with `host`.
    public static func lookup(host: String) async -> String? {
        guard QuickShareAddress.usable(host) != nil else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
                process.arguments = ["-n", host]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: parse(arpOutput: String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
