import Foundation

// offline_wire_formats.proto — Nearby Connections' transport framing: the
// connection handshake, keep-alives, and the payload transfer that carries
// everything else.
//
// Only the fields Quick Share actually exchanges are modelled. Unmodelled
// fields (bandwidth upgrade, auto-reconnect, location hints, …) are skipped on
// decode, which is both smaller and safer than carrying them around.

public enum OfflineFrameVersion: Int, Sendable {
    case unknownVersion = 0
    case v1 = 1
}

public enum V1FrameType: Int, Sendable {
    case unknownFrameType = 0
    case connectionRequest = 1
    case connectionResponse = 2
    case payloadTransfer = 3
    case keepAlive = 5
    case disconnection = 6
}

public enum PacketType: Int, Sendable {
    case unknownPacketType = 0
    case data = 1
    case control = 2
}

public enum PayloadType: Int, Sendable {
    case unknownPayloadType = 0
    case bytes = 1
    case file = 2
    case stream = 3
}

public enum OsType: Int, Sendable {
    case unknownOsType = 0
    case android = 1
    case chromeOs = 2
    case windows = 3
    case apple = 4
    case linux = 100
}

public enum ConnectionResponseStatus: Int, Sendable {
    case unknownResponseStatus = 0
    case accept = 1
    case reject = 2
}

public struct OsInfo: ProtoMessage {
    public var type: OsType?

    public init() {}
    public init(type: OsType) { self.type = type }

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): type = OsType(rawValue: Int(try reader.readInt32()))
        default: return false
        }
        return true
    }
}

/// Transports a peer can be asked to upgrade to. Quick Share over LAN only ever
/// advertises Wi-Fi.
public enum ConnectionMedium: Int, Sendable {
    case unknownMedium = 0
    case mdns = 1
    case bluetooth = 2
    case wifiHotspot = 3
    case bleAdvertisement = 4
    case wifiLan = 5
    case wifiAware = 6
    case nfc = 7
    case wifiDirect = 8
    case ble = 9
    case webRtc = 10
}

public struct ConnectionRequestFrame: ProtoMessage {
    public var endpointID: String?
    public var endpointName: String?
    public var endpointInfo: Data?
    /// Which transports we support. Android expects this to be stated rather
    /// than inferred, so we send `[.wifiLan]` like the reference implementation.
    public var mediums: [ConnectionMedium] = []

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = endpointID { w.write(field: 1, string: v) }
        if let v = endpointName { w.write(field: 2, string: v) }
        // proto2 repeated enums are unpacked by default: one varint field each,
        // not a single length-delimited block.
        for medium in mediums { w.write(field: 5, enumValue: medium.rawValue) }
        if let v = endpointInfo { w.write(field: 6, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): endpointID = try reader.readString()
        case (2, .lengthDelimited): endpointName = try reader.readString()
        case (5, .varint):
            if let m = ConnectionMedium(rawValue: Int(try reader.readInt32())) { mediums.append(m) }
        case (5, .lengthDelimited):
            // A peer is free to send them packed even though we don't.
            var packed = try reader.readNested()
            while !packed.isAtEnd {
                if let m = ConnectionMedium(rawValue: Int(try packed.readInt32())) { mediums.append(m) }
            }
        case (6, .lengthDelimited): endpointInfo = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct ConnectionResponseFrame: ProtoMessage {
    public var status: Int32?
    public var response: ConnectionResponseStatus?
    public var osInfo: OsInfo?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = status { w.write(field: 1, int32: v) }
        if let v = response { w.write(field: 3, enumValue: v.rawValue) }
        if let v = osInfo { w.write(field: 4, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): status = try reader.readInt32()
        case (3, .varint): response = ConnectionResponseStatus(rawValue: Int(try reader.readInt32()))
        case (4, .lengthDelimited): try decodeNested(&osInfo, from: &reader)
        default: return false
        }
        return true
    }
}

public struct DisconnectionFrame: ProtoMessage {
    public var requestSafeToDisconnect: Bool?
    public var ackSafeToDisconnect: Bool?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = requestSafeToDisconnect { w.write(field: 1, bool: v) }
        if let v = ackSafeToDisconnect { w.write(field: 2, bool: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): requestSafeToDisconnect = try reader.readBool()
        case (2, .varint): ackSafeToDisconnect = try reader.readBool()
        default: return false
        }
        return true
    }
}

public struct KeepAliveFrame: ProtoMessage {
    public var ack: Bool?
    public var seqNum: UInt32?

    public init() {}
    public init(ack: Bool) { self.ack = ack }

    public func encode(to w: inout ProtoWriter) {
        if let v = ack { w.write(field: 1, bool: v) }
        if let v = seqNum { w.write(field: 2, uint32: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): ack = try reader.readBool()
        case (2, .varint): seqNum = try reader.readUInt32()
        default: return false
        }
        return true
    }
}

public struct PayloadHeader: ProtoMessage {
    public var id: Int64?
    public var type: PayloadType?
    public var totalSize: Int64?
    public var isSensitive: Bool?
    public var fileName: String?
    public var parentFolder: String?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = id { w.write(field: 1, int64: v) }
        if let v = type { w.write(field: 2, enumValue: v.rawValue) }
        if let v = totalSize { w.write(field: 3, int64: v) }
        if let v = isSensitive { w.write(field: 4, bool: v) }
        if let v = fileName { w.write(field: 5, string: v) }
        if let v = parentFolder { w.write(field: 6, string: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): id = try reader.readInt64()
        case (2, .varint): type = PayloadType(rawValue: Int(try reader.readInt32()))
        case (3, .varint): totalSize = try reader.readInt64()
        case (4, .varint): isSensitive = try reader.readBool()
        case (5, .lengthDelimited): fileName = try reader.readString()
        case (6, .lengthDelimited): parentFolder = try reader.readString()
        default: return false
        }
        return true
    }
}

public struct PayloadChunk: ProtoMessage {
    /// Bit 0 set means "last chunk".
    public static let lastChunkFlag: Int32 = 1

    public var flags: Int32?
    public var offset: Int64?
    public var body: Data?

    public init() {}

    public var isLastChunk: Bool { ((flags ?? 0) & Self.lastChunkFlag) == Self.lastChunkFlag }

    public func encode(to w: inout ProtoWriter) {
        if let v = flags { w.write(field: 1, int32: v) }
        if let v = offset { w.write(field: 2, int64: v) }
        if let v = body { w.write(field: 3, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): flags = try reader.readInt32()
        case (2, .varint): offset = try reader.readInt64()
        case (3, .lengthDelimited): body = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct PayloadTransferFrame: ProtoMessage {
    public var packetType: PacketType?
    public var payloadHeader: PayloadHeader?
    public var payloadChunk: PayloadChunk?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = packetType { w.write(field: 1, enumValue: v.rawValue) }
        if let v = payloadHeader { w.write(field: 2, message: v) }
        if let v = payloadChunk { w.write(field: 3, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): packetType = PacketType(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): try decodeNested(&payloadHeader, from: &reader)
        case (3, .lengthDelimited): try decodeNested(&payloadChunk, from: &reader)
        default: return false
        }
        return true
    }
}

public struct V1Frame: ProtoMessage {
    public var type: V1FrameType?
    public var connectionRequest: ConnectionRequestFrame?
    public var connectionResponse: ConnectionResponseFrame?
    public var payloadTransfer: PayloadTransferFrame?
    public var keepAlive: KeepAliveFrame?
    public var disconnection: DisconnectionFrame?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
        if let v = connectionRequest { w.write(field: 2, message: v) }
        if let v = connectionResponse { w.write(field: 3, message: v) }
        if let v = payloadTransfer { w.write(field: 4, message: v) }
        if let v = keepAlive { w.write(field: 6, message: v) }
        if let v = disconnection { w.write(field: 7, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): type = V1FrameType(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): try decodeNested(&connectionRequest, from: &reader)
        case (3, .lengthDelimited): try decodeNested(&connectionResponse, from: &reader)
        case (4, .lengthDelimited): try decodeNested(&payloadTransfer, from: &reader)
        case (6, .lengthDelimited): try decodeNested(&keepAlive, from: &reader)
        case (7, .lengthDelimited): try decodeNested(&disconnection, from: &reader)
        default: return false
        }
        return true
    }
}

public struct OfflineFrame: ProtoMessage {
    public var version: OfflineFrameVersion?
    public var v1: V1Frame?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = version { w.write(field: 1, enumValue: v.rawValue) }
        if let v = v1 { w.write(field: 2, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): version = OfflineFrameVersion(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): try decodeNested(&v1, from: &reader)
        default: return false
        }
        return true
    }

    // MARK: Convenience constructors

    public static func wrapping(_ body: V1Frame) -> OfflineFrame {
        var f = OfflineFrame()
        f.version = .v1
        f.v1 = body
        return f
    }

    public static func keepAlive(ack: Bool) -> OfflineFrame {
        var v1 = V1Frame()
        v1.type = .keepAlive
        v1.keepAlive = KeepAliveFrame(ack: ack)
        return .wrapping(v1)
    }

    public static func disconnection() -> OfflineFrame {
        var v1 = V1Frame()
        v1.type = .disconnection
        v1.disconnection = DisconnectionFrame()
        return .wrapping(v1)
    }

    public static func payloadTransfer(_ transfer: PayloadTransferFrame) -> OfflineFrame {
        var v1 = V1Frame()
        v1.type = .payloadTransfer
        v1.payloadTransfer = transfer
        return .wrapping(v1)
    }
}

// MARK: - Sharing frames

// wire_format.proto — the Quick Share application layer that rides inside
// Nearby Connections' bytes payloads: what's being offered, and the accept or
// decline that answers it.

public enum SharingFrameVersion: Int, Sendable {
    case unknownVersion = 0
    case v1 = 1
}

public enum SharingFrameType: Int, Sendable {
    case unknownFrameType = 0
    case introduction = 1
    case response = 2
    case pairedKeyEncryption = 3
    case pairedKeyResult = 4
    case certificateInfo = 5
    case cancel = 6
    case progressUpdate = 7
}

public enum SharingFileType: Int, Sendable {
    case unknown = 0
    case image = 1
    case video = 2
    case androidApp = 3
    case audio = 4
    case document = 5
    case contactCard = 6
}

public enum SharingTextType: Int, Sendable {
    case unknown = 0
    case text = 1
    case url = 2
    case address = 3
    case phoneNumber = 4
}

public enum SharingResponseStatus: Int, Sendable {
    case unknown = 0
    case accept = 1
    case reject = 2
    case notEnoughSpace = 3
    case unsupportedAttachmentType = 4
    case timedOut = 5
}

public enum PairedKeyResultStatus: Int, Sendable {
    case unknown = 0
    case success = 1
    case fail = 2
    case unable = 3
}

public struct SharingFileMetadata: ProtoMessage {
    public var name: String?
    public var type: SharingFileType?
    public var payloadID: Int64?
    public var size: Int64?
    public var mimeType: String?
    public var id: Int64?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = name { w.write(field: 1, string: v) }
        if let v = type { w.write(field: 2, enumValue: v.rawValue) }
        if let v = payloadID { w.write(field: 3, int64: v) }
        if let v = size { w.write(field: 4, int64: v) }
        if let v = mimeType { w.write(field: 5, string: v) }
        if let v = id { w.write(field: 6, int64: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): name = try reader.readString()
        case (2, .varint): type = SharingFileType(rawValue: Int(try reader.readInt32()))
        case (3, .varint): payloadID = try reader.readInt64()
        case (4, .varint): size = try reader.readInt64()
        case (5, .lengthDelimited): mimeType = try reader.readString()
        case (6, .varint): id = try reader.readInt64()
        default: return false
        }
        return true
    }
}

public struct SharingTextMetadata: ProtoMessage {
    public var textTitle: String?
    public var type: SharingTextType?
    public var payloadID: Int64?
    public var size: Int64?
    public var id: Int64?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = textTitle { w.write(field: 2, string: v) }
        if let v = type { w.write(field: 3, enumValue: v.rawValue) }
        if let v = payloadID { w.write(field: 4, int64: v) }
        if let v = size { w.write(field: 5, int64: v) }
        if let v = id { w.write(field: 6, int64: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (2, .lengthDelimited): textTitle = try reader.readString()
        case (3, .varint): type = SharingTextType(rawValue: Int(try reader.readInt32()))
        case (4, .varint): payloadID = try reader.readInt64()
        case (5, .varint): size = try reader.readInt64()
        case (6, .varint): id = try reader.readInt64()
        default: return false
        }
        return true
    }
}

public struct IntroductionFrame: ProtoMessage {
    public var fileMetadata: [SharingFileMetadata] = []
    public var textMetadata: [SharingTextMetadata] = []

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        w.write(field: 1, repeated: fileMetadata)
        w.write(field: 2, repeated: textMetadata)
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): try decodeNestedAppending(&fileMetadata, from: &reader)
        case (2, .lengthDelimited): try decodeNestedAppending(&textMetadata, from: &reader)
        default: return false
        }
        return true
    }
}

public struct SharingConnectionResponseFrame: ProtoMessage {
    public var status: SharingResponseStatus?

    public init() {}
    public init(status: SharingResponseStatus) { self.status = status }

    public func encode(to w: inout ProtoWriter) {
        if let v = status { w.write(field: 1, enumValue: v.rawValue) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): status = SharingResponseStatus(rawValue: Int(try reader.readInt32()))
        default: return false
        }
        return true
    }
}

public struct PairedKeyEncryptionFrame: ProtoMessage {
    public var signedData: Data?
    public var secretIDHash: Data?
    /// Proof that this sender showed the QR code the phone scanned.
    public var qrCodeHandshakeData: Data?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = signedData { w.write(field: 1, bytes: v) }
        if let v = secretIDHash { w.write(field: 2, bytes: v) }
        if let v = qrCodeHandshakeData { w.write(field: 4, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): signedData = try reader.readBytes()
        case (2, .lengthDelimited): secretIDHash = try reader.readBytes()
        case (4, .lengthDelimited): qrCodeHandshakeData = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct PairedKeyResultFrame: ProtoMessage {
    public var status: PairedKeyResultStatus?

    public init() {}
    public init(status: PairedKeyResultStatus) { self.status = status }

    public func encode(to w: inout ProtoWriter) {
        if let v = status { w.write(field: 1, enumValue: v.rawValue) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): status = PairedKeyResultStatus(rawValue: Int(try reader.readInt32()))
        default: return false
        }
        return true
    }
}

public struct SharingV1Frame: ProtoMessage {
    public var type: SharingFrameType?
    public var introduction: IntroductionFrame?
    public var connectionResponse: SharingConnectionResponseFrame?
    public var pairedKeyEncryption: PairedKeyEncryptionFrame?
    public var pairedKeyResult: PairedKeyResultFrame?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
        if let v = introduction { w.write(field: 2, message: v) }
        if let v = connectionResponse { w.write(field: 3, message: v) }
        if let v = pairedKeyEncryption { w.write(field: 4, message: v) }
        if let v = pairedKeyResult { w.write(field: 5, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): type = SharingFrameType(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): try decodeNested(&introduction, from: &reader)
        case (3, .lengthDelimited): try decodeNested(&connectionResponse, from: &reader)
        case (4, .lengthDelimited): try decodeNested(&pairedKeyEncryption, from: &reader)
        case (5, .lengthDelimited): try decodeNested(&pairedKeyResult, from: &reader)
        default: return false
        }
        return true
    }
}

public struct SharingFrame: ProtoMessage {
    public var version: SharingFrameVersion?
    public var v1: SharingV1Frame?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = version { w.write(field: 1, enumValue: v.rawValue) }
        if let v = v1 { w.write(field: 2, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): version = SharingFrameVersion(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): try decodeNested(&v1, from: &reader)
        default: return false
        }
        return true
    }

    // MARK: Convenience constructors

    public static func wrapping(_ body: SharingV1Frame) -> SharingFrame {
        var f = SharingFrame()
        f.version = .v1
        f.v1 = body
        return f
    }

    public static func pairedKeyEncryption(secretIDHash: Data, signedData: Data,
                                           qrCodeHandshakeData: Data? = nil) -> SharingFrame {
        var inner = PairedKeyEncryptionFrame()
        inner.signedData = signedData
        inner.secretIDHash = secretIDHash
        inner.qrCodeHandshakeData = qrCodeHandshakeData
        var v1 = SharingV1Frame()
        v1.type = .pairedKeyEncryption
        v1.pairedKeyEncryption = inner
        return .wrapping(v1)
    }

    public static func pairedKeyResult(_ status: PairedKeyResultStatus) -> SharingFrame {
        var v1 = SharingV1Frame()
        v1.type = .pairedKeyResult
        v1.pairedKeyResult = PairedKeyResultFrame(status: status)
        return .wrapping(v1)
    }

    public static func response(_ status: SharingResponseStatus) -> SharingFrame {
        var v1 = SharingV1Frame()
        v1.type = .response
        v1.connectionResponse = SharingConnectionResponseFrame(status: status)
        return .wrapping(v1)
    }

    public static func cancel() -> SharingFrame {
        var v1 = SharingV1Frame()
        v1.type = .cancel
        return .wrapping(v1)
    }

    public static func introduction(_ intro: IntroductionFrame) -> SharingFrame {
        var v1 = SharingV1Frame()
        v1.type = .introduction
        v1.introduction = intro
        return .wrapping(v1)
    }
}
