import CommonCrypto
import CryptoKit
import Foundation

// securemessage.proto — the signed/encrypted envelope every post-handshake
// frame travels in. Field numbers mirror Google's securemessage.proto.

public enum SigScheme: Int, Sendable {
    case hmacSha256 = 1
    case ecdsaP256Sha256 = 2
    case rsa2048Sha256 = 3
}

public enum EncScheme: Int, Sendable {
    case none = 1
    case aes256Cbc = 2
}

public enum PublicKeyType: Int, Sendable {
    case ecP256 = 1
    case rsa2048 = 2
    case dh2048Modp = 3
}

/// The outermost envelope: an opaque `headerAndBody` plus its signature.
public struct SecureMessage: ProtoMessage {
    public var headerAndBody: Data?
    public var signature: Data?

    public init() {}
    public init(headerAndBody: Data, signature: Data) {
        self.headerAndBody = headerAndBody
        self.signature = signature
    }

    public func encode(to w: inout ProtoWriter) {
        if let v = headerAndBody { w.write(field: 1, bytes: v) }
        if let v = signature { w.write(field: 2, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): headerAndBody = try reader.readBytes()
        case (2, .lengthDelimited): signature = try reader.readBytes()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard headerAndBody != nil else { throw ProtoWireError.missingRequiredField("SecureMessage.headerAndBody") }
        guard signature != nil else { throw ProtoWireError.missingRequiredField("SecureMessage.signature") }
    }
}

public struct SecureMessageHeader: ProtoMessage {
    public var signatureScheme: SigScheme?
    public var encryptionScheme: EncScheme?
    public var verificationKeyID: Data?
    public var decryptionKeyID: Data?
    public var iv: Data?
    public var publicMetadata: Data?
    public var associatedDataLength: UInt32?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = signatureScheme { w.write(field: 1, enumValue: v.rawValue) }
        if let v = encryptionScheme { w.write(field: 2, enumValue: v.rawValue) }
        if let v = verificationKeyID { w.write(field: 3, bytes: v) }
        if let v = decryptionKeyID { w.write(field: 4, bytes: v) }
        if let v = iv { w.write(field: 5, bytes: v) }
        if let v = publicMetadata { w.write(field: 6, bytes: v) }
        if let v = associatedDataLength { w.write(field: 7, uint32: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint):
            let raw = Int(try reader.readInt32())
            guard let v = SigScheme(rawValue: raw) else {
                throw ProtoWireError.invalidEnumValue(field: "Header.signatureScheme", value: raw)
            }
            signatureScheme = v
        case (2, .varint):
            let raw = Int(try reader.readInt32())
            guard let v = EncScheme(rawValue: raw) else {
                throw ProtoWireError.invalidEnumValue(field: "Header.encryptionScheme", value: raw)
            }
            encryptionScheme = v
        case (3, .lengthDelimited): verificationKeyID = try reader.readBytes()
        case (4, .lengthDelimited): decryptionKeyID = try reader.readBytes()
        case (5, .lengthDelimited): iv = try reader.readBytes()
        case (6, .lengthDelimited): publicMetadata = try reader.readBytes()
        case (7, .varint): associatedDataLength = try reader.readUInt32()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard signatureScheme != nil else { throw ProtoWireError.missingRequiredField("Header.signatureScheme") }
        guard encryptionScheme != nil else { throw ProtoWireError.missingRequiredField("Header.encryptionScheme") }
    }
}

public struct HeaderAndBody: ProtoMessage {
    public var header: SecureMessageHeader?
    public var body: Data?

    public init() {}
    public init(header: SecureMessageHeader, body: Data) {
        self.header = header
        self.body = body
    }

    public func encode(to w: inout ProtoWriter) {
        if let v = header { w.write(field: 1, message: v) }
        if let v = body { w.write(field: 2, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): try decodeNested(&header, from: &reader)
        case (2, .lengthDelimited): body = try reader.readBytes()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard header != nil else { throw ProtoWireError.missingRequiredField("HeaderAndBody.header") }
        guard body != nil else { throw ProtoWireError.missingRequiredField("HeaderAndBody.body") }
    }
}

public struct EcP256PublicKey: ProtoMessage {
    public var x: Data?
    public var y: Data?

    public init() {}
    public init(x: Data, y: Data) { self.x = x; self.y = y }

    public func encode(to w: inout ProtoWriter) {
        if let v = x { w.write(field: 1, bytes: v) }
        if let v = y { w.write(field: 2, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): x = try reader.readBytes()
        case (2, .lengthDelimited): y = try reader.readBytes()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard x != nil else { throw ProtoWireError.missingRequiredField("EcP256PublicKey.x") }
        guard y != nil else { throw ProtoWireError.missingRequiredField("EcP256PublicKey.y") }
    }
}

public struct GenericPublicKey: ProtoMessage {
    public var type: PublicKeyType?
    public var ecP256PublicKey: EcP256PublicKey?
    // Fields 3 (rsa2048) and 4 (dh2048) exist in the schema but are unused by
    // Quick Share; they are skipped on decode rather than modelled.

    public init() {}
    public init(ecP256: EcP256PublicKey) {
        self.type = .ecP256
        self.ecP256PublicKey = ecP256
    }

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
        if let v = ecP256PublicKey { w.write(field: 2, message: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint):
            let raw = Int(try reader.readInt32())
            guard let v = PublicKeyType(rawValue: raw) else {
                throw ProtoWireError.invalidEnumValue(field: "GenericPublicKey.type", value: raw)
            }
            type = v
        case (2, .lengthDelimited): try decodeNested(&ecP256PublicKey, from: &reader)
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard type != nil else { throw ProtoWireError.missingRequiredField("GenericPublicKey.type") }
    }
}

// MARK: - GCM metadata

// securegcm.proto — the inner message carried inside a SecureMessage body, plus
// the metadata tag that identifies it.

/// `Securegcm.Type`. Only the one value Quick Share uses is modelled; anything
/// else decodes as `.other` rather than failing, since this field is purely
/// descriptive.
public enum GcmType: Sendable, Equatable {
    case deviceToDeviceMessage
    case other(Int)

    public var rawValue: Int {
        switch self {
        case .deviceToDeviceMessage: return 13
        case .other(let v): return v
        }
    }

    public init(rawValue: Int) {
        self = rawValue == 13 ? .deviceToDeviceMessage : .other(rawValue)
    }
}

public struct GcmMetadata: ProtoMessage {
    public var type: GcmType?
    public var version: Int32?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
        if let v = version { w.write(field: 2, int32: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): type = GcmType(rawValue: Int(try reader.readInt32()))
        case (2, .varint): version = try reader.readInt32()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard type != nil else { throw ProtoWireError.missingRequiredField("GcmMetadata.type") }
    }
}

/// The decrypted payload of every post-handshake frame.
///
/// Note the wire order: `message` is field 1 and `sequenceNumber` is field 2,
/// regardless of the order they're assigned in code.
public struct DeviceToDeviceMessage: ProtoMessage {
    public var message: Data?
    public var sequenceNumber: Int32?

    public init() {}
    public init(message: Data, sequenceNumber: Int32) {
        self.message = message
        self.sequenceNumber = sequenceNumber
    }

    public func encode(to w: inout ProtoWriter) {
        if let v = message { w.write(field: 1, bytes: v) }
        if let v = sequenceNumber { w.write(field: 2, int32: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): message = try reader.readBytes()
        case (2, .varint): sequenceNumber = try reader.readInt32()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard message != nil else { throw ProtoWireError.missingRequiredField("DeviceToDeviceMessage.message") }
        guard sequenceNumber != nil else { throw ProtoWireError.missingRequiredField("DeviceToDeviceMessage.sequenceNumber") }
    }
}

// MARK: - Codec

/// Seals and opens the AES-256-CBC + HMAC-SHA256 envelope every post-handshake
/// frame travels in.
///
/// Encrypt-then-MAC: the HMAC covers the serialized `HeaderAndBody`, and it is
/// verified *before* anything is decrypted. That ordering is what makes the
/// PKCS#7 padding check below safe to perform — an attacker cannot get us to
/// decrypt, or to reveal a padding result, without already holding the MAC key.
public struct SecureMessageCodec: Sendable {

    private let encryptKey: SymmetricKey
    private let decryptKey: SymmetricKey
    private let sendHmacKey: SymmetricKey
    private let recvHmacKey: SymmetricKey

    public init(keys: UKey2.SessionKeys) {
        self.encryptKey = keys.encryptKey
        self.decryptKey = keys.decryptKey
        self.sendHmacKey = keys.sendHmacKey
        self.recvHmacKey = keys.recvHmacKey
    }

    // MARK: Seal

    public func seal(_ plaintext: Data) throws -> SecureMessage {
        let iv = Data.secureRandom(count: kCCBlockSizeAES128)
        let ciphertext = try Self.crypt(operation: CCOperation(kCCEncrypt),
                                        key: encryptKey, iv: iv, input: plaintext)

        var metadata = GcmMetadata()
        metadata.type = .deviceToDeviceMessage
        metadata.version = 1

        var header = SecureMessageHeader()
        header.signatureScheme = .hmacSha256
        header.encryptionScheme = .aes256Cbc
        header.iv = iv
        header.publicMetadata = metadata.serialized()

        let headerAndBody = HeaderAndBody(header: header, body: ciphertext).serialized()
        let signature = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody, using: sendHmacKey))
        return SecureMessage(headerAndBody: headerAndBody, signature: signature)
    }

    // MARK: Open

    public func open(_ message: SecureMessage) throws -> Data {
        guard let headerAndBody = message.headerAndBody, let signature = message.signature else {
            throw SWIFTError.protocolViolation("secure message is missing a field")
        }

        // Verify first, in constant time, and bail before touching the ciphertext.
        let expected = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody, using: recvHmacKey))
        guard constantTimeEquals(expected, signature) else {
            throw SWIFTError.authenticationFailed
        }

        let parsed = try HeaderAndBody(serialized: headerAndBody)
        guard let header = parsed.header, let body = parsed.body else {
            throw SWIFTError.protocolViolation("secure message body is missing a field")
        }
        guard header.encryptionScheme == .aes256Cbc else {
            throw SWIFTError.protocolViolation("unsupported encryption scheme")
        }
        guard header.signatureScheme == .hmacSha256 else {
            throw SWIFTError.protocolViolation("unsupported signature scheme")
        }
        guard let iv = header.iv, iv.count == kCCBlockSizeAES128 else {
            throw SWIFTError.protocolViolation("missing or malformed IV")
        }
        return try Self.crypt(operation: CCOperation(kCCDecrypt),
                              key: decryptKey, iv: iv, input: body)
    }

    /// Constant-time compare so a bad MAC leaks nothing through timing.
    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: AES-CBC

    /// AES-256-CBC with PKCS#7.
    ///
    /// Padding is applied and validated here rather than by `CCCrypt`'s
    /// `kCCOptionPKCS7Padding`: that option accepts inputs which are not a
    /// multiple of the block size and quietly returns garbage instead of an
    /// error, letting malformed ciphertext reach the protobuf parser as noise
    /// instead of failing here. Doing it explicitly rejects it up front.
    private static func crypt(operation: CCOperation, key: SymmetricKey,
                              iv: Data, input: Data) throws -> Data {
        let blockSize = kCCBlockSizeAES128
        let padded: Data
        if operation == CCOperation(kCCEncrypt) {
            let padValue = blockSize - (input.count % blockSize)   // always 1...16
            padded = input + Data(repeating: UInt8(padValue), count: padValue)
        } else {
            guard !input.isEmpty, input.count % blockSize == 0 else {
                throw SWIFTError.protocolViolation("ciphertext is not block-aligned")
            }
            padded = input
        }

        let keyBytes = key.withUnsafeBytes { [UInt8]($0) }
        guard keyBytes.count == kCCKeySizeAES256 else {
            throw SWIFTError.internalFailure("wrong AES key size")
        }

        var output = [UInt8](repeating: 0, count: padded.count + blockSize)
        var moved = 0
        let status = padded.withUnsafeBytes { inPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCrypt(operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),                  // no padding option; handled above
                        keyBytes, keyBytes.count,
                        ivPtr.baseAddress,
                        inPtr.baseAddress, padded.count,
                        &output, output.count,
                        &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw SWIFTError.protocolViolation("AES operation failed (\(status))")
        }
        var result = Data(output.prefix(moved))

        if operation == CCOperation(kCCDecrypt) {
            result = try stripPKCS7(result, blockSize: blockSize)
        }
        return result
    }

    private static func stripPKCS7(_ data: Data, blockSize: Int) throws -> Data {
        guard let pad = data.last.map(Int.init), pad >= 1, pad <= blockSize, data.count >= pad else {
            throw SWIFTError.protocolViolation("invalid PKCS#7 padding")
        }
        // Every padding byte must carry the same value.
        guard data.suffix(pad).allSatisfy({ Int($0) == pad }) else {
            throw SWIFTError.protocolViolation("invalid PKCS#7 padding")
        }
        return Data(data.dropLast(pad))
    }
}

extension Data {
    /// Cryptographically secure random bytes.
    static func secureRandom(count: Int) -> Data {
        guard count > 0 else { return Data() }
        // SystemRandomNumberGenerator is documented as cryptographically secure
        // on Apple platforms and, unlike SecRandomCopyBytes, gives us no status
        // code to mishandle. Drawn 64 bits at a time rather than per byte.
        var rng = SystemRandomNumberGenerator()
        let words = (0..<((count + 7) / 8)).map { _ in rng.next() as UInt64 }
        return words.withUnsafeBytes { Data($0.prefix(count)) }
    }
}
