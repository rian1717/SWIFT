import Foundation

/// A device on the local network.
public struct SWIFTDevice: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let type: DeviceType

    public init(id: String, name: String, type: DeviceType) {
        self.id = id
        self.name = name
        self.type = type
    }

    public enum DeviceType: Int32, Sendable {
        case unknown = 0
        case phone = 1
        case tablet = 2
        case computer = 3

        public init(rawDeviceType: Int) {
            self = DeviceType(rawValue: Int32(rawDeviceType)) ?? .unknown
        }
    }
}

/// One file inside an incoming offer.
public struct IncomingFile: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let mimeType: String
    public let payloadID: Int64

    public init(name: String, size: Int64, mimeType: String, payloadID: Int64) {
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.payloadID = payloadID
    }
}

/// What a peer is offering us, presented for the user to accept or decline.
public struct IncomingOffer: Sendable, Equatable {
    public let id: String
    public let device: SWIFTDevice
    public let files: [IncomingFile]
    /// Present instead of files when the peer is sharing a link.
    public let textTitle: String?
    /// The verification code, for the user to compare against the other screen.
    public let pinCode: String

    /// Saturating, not trapping. Sizes here are declared by a remote peer and
    /// this is read while presenting the offer — i.e. before anyone has
    /// consented to anything. A plain `+` traps on overflow, so two files each
    /// declaring `Int64.max` were enough to kill the process from the network.
    /// `InboundSession` bounds the values long before they reach this, but a
    /// public property on a public type shouldn't be one caller away from a
    /// crash either way.
    public var totalBytes: Int64 {
        files.reduce(Int64(0)) { sum, file in
            let (total, overflowed) = sum.addingReportingOverflow(file.size)
            return overflowed ? Int64.max : total
        }
    }

    public init(id: String, device: SWIFTDevice, files: [IncomingFile],
                textTitle: String?, pinCode: String) {
        self.id = id
        self.device = device
        self.files = files
        self.textTitle = textTitle
        self.pinCode = pinCode
    }
}

/// Events a receiving session reports.
public enum InboundEvent: Sendable {
    /// The peer has offered files; answer with `respond(accept:)`.
    case offerReceived(IncomingOffer)
    case progress(Double)
    /// Finished successfully, with where the files landed.
    case finished(savedFiles: [URL])
    case failed(SWIFTError)
}

/// Events a sending session reports.
public enum OutboundEvent: Sendable {
    /// Handshake done; `pinCode` should be shown so the user can compare it.
    case connected(pinCode: String)
    /// The remote user accepted; bytes are flowing.
    case accepted
    case progress(Double)
    case finished
    case failed(SWIFTError)
}

/// A file queued to send.
public struct OutgoingFile: Sendable {
    public let url: URL
    public let name: String
    public let size: Int64
    public let mimeType: String

    public init(url: URL, name: String, size: Int64, mimeType: String) {
        self.url = url
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }

    /// The MIME type to advertise. macOS has no type for `.apk`, so a sniffed
    /// lookup comes back empty and the file goes out as
    /// `application/octet-stream`. Quick Share then stores a blob the phone
    /// will not open. An APK has to be named as an installable package.
    public static func advertisedMIMEType(sniffed: String?, pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "apk":
            return "application/vnd.android.package-archive"
        default:
            return sniffed ?? "application/octet-stream"
        }
    }
}

// MARK: - Errors

/// Everything the protocol layer can fail with.
///
/// Deliberately coarse: the UI only needs to know what to tell the user, and a
/// remote peer should learn as little as possible about why we hung up.
public enum SWIFTError: Error, Equatable, Sendable {
    /// The peer sent something the protocol doesn't allow.
    case protocolViolation(String)
    /// A required field was absent.
    case missingField(String)
    /// HMAC verification failed — the frame was forged or corrupted.
    case authenticationFailed
    /// The UKEY2 handshake could not be completed.
    case handshakeFailed(String)
    /// The connection dropped or timed out.
    case connectionLost
    case timedOut
    /// The peer declined, or we did.
    case rejected(Reason)
    /// A local failure — disk, or a bug on our side.
    case localFailure(String)
    case internalFailure(String)

    public enum Reason: String, Sendable {
        case userRejected
        case userCanceled
        case notEnoughSpace
        case unsupportedType
        case timedOut
    }

    /// Short, user-facing text. Deliberately non-technical.
    public var userMessage: String {
        switch self {
        case .rejected(let reason):
            switch reason {
            case .userRejected:    return "Declined"
            case .userCanceled:    return "Cancelled"
            case .notEnoughSpace:  return "Not enough space"
            case .unsupportedType: return "Unsupported file type"
            case .timedOut:        return "Timed out"
            }
        case .authenticationFailed: return "Couldn't verify the other device"
        case .handshakeFailed:      return "Handshake failed"
        case .connectionLost:       return "Connection lost"
        case .timedOut:             return "Timed out"
        case .protocolViolation, .missingField: return "Protocol error"
        case .localFailure(let m):  return m
        case .internalFailure:      return "Something went wrong"
        }
    }
}

// MARK: - Received file names

/// Turns a remote-supplied file name into a safe destination inside the receive
/// directory.
///
/// The name arrives from an unauthenticated peer, so it is treated as hostile:
/// reduced to a single path component, stripped of anything that could redirect
/// a write, and the resulting path is re-checked against the receive directory
/// before it is used.
public enum ReceivedFileName {

    public static let fallbackName = "received_file"
    /// Long names are truncated well below the 255-byte filesystem limit,
    /// leaving room for a " (2)" disambiguator.
    static let maxNameLength = 200

    /// Reduces an arbitrary string to one safe path component.
    public static func sanitize(_ raw: String) -> String {
        // lastPathComponent removes any directory part, including "../".
        var name = (raw as NSString).lastPathComponent

        // A bare root comes back as "/" rather than "", and would otherwise
        // survive separator substitution as a file literally named "_".
        if name == "/" { name = "" }

        // NUL can truncate a path inside C-level APIs; separators would
        // reintroduce structure.
        name = name.replacingOccurrences(of: "\0", with: "")
        name = name.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: "\\", with: "_")

        // A leading dot would hide the file; a trailing dot or space is
        // significant on other platforms and confusing here.
        while name.hasSuffix(".") || name.hasSuffix(" ") { name = String(name.dropLast()) }

        if name.utf8.count > maxNameLength {
            let ext = (name as NSString).pathExtension
            var base = (name as NSString).deletingPathExtension
            base = String(base.prefix(maxNameLength - ext.count - 1))
            name = ext.isEmpty ? base : "\(base).\(ext)"
        }

        if name.isEmpty || name == "." || name == ".." { name = fallbackName }
        return name
    }

    /// Resolves a non-colliding destination, and refuses anything that would
    /// land outside `directory`.
    public static func uniqueDestination(for sanitizedName: String,
                                         in directory: URL) throws -> URL {
        let base = directory.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var candidate = base.appendingPathComponent(sanitizedName)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = base.appendingPathComponent(name)
            counter += 1
            guard counter < 10_000 else {
                throw SWIFTError.localFailure("couldn't find a free file name")
            }
        }

        // Belt and braces: confirm the final path really is inside the directory.
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent.path == base.path else {
            throw SWIFTError.protocolViolation("rejected a file name that escaped the receive folder")
        }
        return candidate
    }
}
