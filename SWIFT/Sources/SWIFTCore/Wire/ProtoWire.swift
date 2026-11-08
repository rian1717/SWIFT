import Foundation

// Minimal protocol-buffers (proto2) wire format, hand-written for SWIFT.
//
// This covers only what the Quick Share protocol actually uses: varints,
// length-delimited fields, and nested messages. There is no reflection, no
// descriptor parsing, no JSON, no `Any`. That is deliberate — the decoder reads
// bytes straight off an unauthenticated network socket, so its whole job is to
// be small enough to audit in one sitting.
//
// Safety properties the decoder guarantees:
//   * every read is bounds-checked and throws rather than trapping;
//   * varints are capped at 10 bytes (no infinite scan on 0x80 padding);
//   * a length prefix is validated against the bytes actually remaining before
//     anything is allocated, so a claimed length can never reserve memory;
//   * nested messages are depth-limited, so recursive nesting can't blow the
//     stack;
//   * unknown fields are skipped, not stored — nothing an attacker sends is
//     retained.

public enum ProtoWireError: Error, Equatable, Sendable {
    case truncated                       // ran off the end of the buffer
    case malformedVarint                 // >10 bytes, or overflows 64 bits
    case invalidWireType(UInt8)
    case invalidFieldNumber(UInt32)
    case lengthTooLarge(Int)             // declared length exceeds what remains
    case depthLimitExceeded
    case invalidUTF8
    case missingRequiredField(String)
    case invalidEnumValue(field: String, value: Int)
}

/// Protobuf wire types. Groups (3/4) are deprecated and intentionally rejected.
public enum ProtoWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5

    init(rawTag: UInt8) throws {
        guard let t = ProtoWireType(rawValue: rawTag) else {
            throw ProtoWireError.invalidWireType(rawTag)
        }
        self = t
    }
}

// MARK: - Reader

/// A cursor over a byte buffer. Every method either advances the cursor by a
/// validated amount or throws; it never traps and never reads out of bounds.
public struct ProtoReader: Sendable {
    /// Deepest nesting the decoder will follow before giving up.
    public static let maxDepth = 16

    private let bytes: [UInt8]
    private var index: Int
    private let end: Int
    private let depth: Int

    public init(_ data: Data, depth: Int = 0) {
        self.bytes = [UInt8](data)
        self.index = 0
        self.end = self.bytes.count
        self.depth = depth
    }

    private init(bytes: [UInt8], from: Int, to: Int, depth: Int) {
        self.bytes = bytes
        self.index = from
        self.end = to
        self.depth = depth
    }

    public var isAtEnd: Bool { index >= end }
    public var bytesRemaining: Int { max(0, end - index) }

    // MARK: Primitives

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var consumed = 0
        while true {
            guard index < end else { throw ProtoWireError.truncated }
            // A 64-bit varint is at most 10 groups of 7 bits.
            guard consumed < 10 else { throw ProtoWireError.malformedVarint }
            let byte = bytes[index]
            index += 1
            consumed += 1
            result |= UInt64(byte & 0x7F) &<< shift
            if byte & 0x80 == 0 { return result }
            shift &+= 7
        }
    }

    public mutating func readFixed32() throws -> UInt32 {
        guard end - index >= 4 else { throw ProtoWireError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[index + i]) &<< UInt32(8 * i) }
        index += 4
        return v
    }

    public mutating func readFixed64() throws -> UInt64 {
        guard end - index >= 8 else { throw ProtoWireError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[index + i]) &<< UInt64(8 * i) }
        index += 8
        return v
    }

    /// Reads a length prefix and validates it against the remaining bytes
    /// *before* any allocation happens.
    private mutating func readLengthPrefix() throws -> Int {
        let raw = try readVarint()
        guard raw <= UInt64(Int.max) else { throw ProtoWireError.lengthTooLarge(Int.max) }
        let length = Int(raw)
        guard length <= end - index else { throw ProtoWireError.lengthTooLarge(length) }
        return length
    }

    public mutating func readBytes() throws -> Data {
        let length = try readLengthPrefix()
        let slice = Data(bytes[index..<(index + length)])
        index += length
        return slice
    }

    public mutating func readString() throws -> String {
        let data = try readBytes()
        guard let s = String(data: data, encoding: .utf8) else {
            throw ProtoWireError.invalidUTF8
        }
        return s
    }

    /// Reads a nested length-delimited message, handing back a reader scoped to
    /// exactly its bytes so it cannot over-read into its parent.
    public mutating func readNested() throws -> ProtoReader {
        guard depth < Self.maxDepth else { throw ProtoWireError.depthLimitExceeded }
        let length = try readLengthPrefix()
        let sub = ProtoReader(bytes: bytes, from: index, to: index + length, depth: depth + 1)
        index += length
        return sub
    }

    public mutating func readBool() throws -> Bool { try readVarint() != 0 }
    public mutating func readInt32() throws -> Int32 { Int32(truncatingIfNeeded: try readVarint()) }
    public mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readVarint()) }
    public mutating func readUInt32() throws -> UInt32 { UInt32(truncatingIfNeeded: try readVarint()) }
    public mutating func readUInt64() throws -> UInt64 { try readVarint() }

    // MARK: Field iteration

    public struct Tag: Sendable {
        public let fieldNumber: UInt32
        public let wireType: ProtoWireType
    }

    /// Next field tag, or nil at end of message.
    public mutating func nextTag() throws -> Tag? {
        if isAtEnd { return nil }
        let key = try readVarint()
        let fieldNumber = UInt32(truncatingIfNeeded: key >> 3)
        guard fieldNumber != 0 else { throw ProtoWireError.invalidFieldNumber(fieldNumber) }
        let wireType = try ProtoWireType(rawTag: UInt8(truncatingIfNeeded: key & 0x07))
        return Tag(fieldNumber: fieldNumber, wireType: wireType)
    }

    /// Skips a field we don't model. Unknown data is discarded, never retained.
    public mutating func skip(_ wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed32:
            _ = try readFixed32()
        case .fixed64:
            _ = try readFixed64()
        case .lengthDelimited:
            let length = try readLengthPrefix()
            index += length
        }
    }
}

// MARK: - Writer

/// Accumulates wire bytes. Fields must be written in ascending field-number
/// order to match the reference encoder byte-for-byte.
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}
    public var data: Data { Data(bytes) }

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    private mutating func writeTag(_ field: UInt32, _ type: ProtoWireType) {
        writeVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    // Scalars. Negative int32/int64 sign-extend to a full 10-byte varint, which
    // is what the reference encoder emits.
    public mutating func write(field: UInt32, int32 value: Int32) {
        writeTag(field, .varint); writeVarint(UInt64(bitPattern: Int64(value)))
    }
    public mutating func write(field: UInt32, int64 value: Int64) {
        writeTag(field, .varint); writeVarint(UInt64(bitPattern: value))
    }
    public mutating func write(field: UInt32, uint32 value: UInt32) {
        writeTag(field, .varint); writeVarint(UInt64(value))
    }
    public mutating func write(field: UInt32, uint64 value: UInt64) {
        writeTag(field, .varint); writeVarint(value)
    }
    public mutating func write(field: UInt32, bool value: Bool) {
        writeTag(field, .varint); writeVarint(value ? 1 : 0)
    }
    public mutating func write(field: UInt32, enumValue value: Int) {
        writeTag(field, .varint); writeVarint(UInt64(bitPattern: Int64(value)))
    }

    public mutating func write(field: UInt32, bytes value: Data) {
        writeTag(field, .lengthDelimited)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func write(field: UInt32, string value: String) {
        write(field: field, bytes: Data(value.utf8))
    }

    /// Nested message: serialize, then length-prefix.
    public mutating func write<M: ProtoMessage>(field: UInt32, message value: M) {
        write(field: field, bytes: value.serialized())
    }

    public mutating func write<M: ProtoMessage>(field: UInt32, repeated values: [M]) {
        for v in values { write(field: field, message: v) }
    }
}

// MARK: - Message

/// A hand-written proto2 message.
///
/// `encode(to:)` must write fields in ascending field-number order, and must
/// write a field only when it was explicitly set — that is what keeps output
/// byte-identical to the reference encoder under proto2 semantics.
public protocol ProtoMessage: Sendable, Equatable {
    init()
    func encode(to writer: inout ProtoWriter)
    mutating func decode(field: UInt32, wireType: ProtoWireType, reader: inout ProtoReader) throws -> Bool
    /// Throws if a field the protocol requires is absent after decoding.
    func validate() throws
}

public extension ProtoMessage {
    func validate() throws {}

    func serialized() -> Data {
        var w = ProtoWriter()
        encode(to: &w)
        return w.data
    }

    /// Parse from a complete buffer.
    init(serialized data: Data) throws {
        var reader = ProtoReader(data)
        self = try Self(reading: &reader)
    }

    /// Parse from a reader already scoped to this message's bytes.
    init(reading reader: inout ProtoReader) throws {
        self.init()
        while let tag = try reader.nextTag() {
            let handled = try decode(field: tag.fieldNumber, wireType: tag.wireType, reader: &reader)
            if !handled { try reader.skip(tag.wireType) }
        }
        try validate()
    }
}

/// Decodes a nested message field in place.
@inlinable
public func decodeNested<M: ProtoMessage>(_ target: inout M?, from reader: inout ProtoReader) throws {
    var sub = try reader.readNested()
    target = try M(reading: &sub)
}

@inlinable
public func decodeNestedAppending<M: ProtoMessage>(_ target: inout [M], from reader: inout ProtoReader) throws {
    var sub = try reader.readNested()
    target.append(try M(reading: &sub))
}
