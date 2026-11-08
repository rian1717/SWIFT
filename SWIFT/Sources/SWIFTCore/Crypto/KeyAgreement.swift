import CryptoKit
import Foundation

/// UKEY2 key agreement and the D2D/SecureMessage key schedule.
///
/// Uses CryptoKit's P-256 rather than a third-party big-integer stack. One
/// compatibility detail matters and is easy to get wrong:
///
/// CryptoKit hands back the ECDH shared secret as a fixed 32-byte, zero-padded
/// X coordinate. The reference implementation fed a *magnitude* encoding into
/// the hash — leading zero bytes stripped. Those differ whenever the X
/// coordinate happens to start with a zero byte (~1 handshake in 256), and the
/// result would be two peers deriving different keys and a handshake that fails
/// only occasionally. `magnitudeBytes` reproduces the reference behaviour, and
/// `KeyAgreementVectorTests` pins it against captured vectors.
public enum UKey2 {

    /// The D2D key-schedule salt (SHA-256 of the D2D protocol identifier, fixed
    /// by the protocol).
    static let d2dSalt = Data([
        0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
        0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
        0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10,
    ])

    /// Big-endian magnitude: leading zero bytes removed. See the note above.
    static func magnitudeBytes(_ data: Data) -> Data {
        var bytes = data
        while bytes.first == 0 { bytes = bytes.dropFirst() }
        return Data(bytes)
    }

    /// Two's-complement big-endian, as the reference emitted its own coordinates.
    ///
    /// A leading 0x00 is prepended when the top bit is set, so the value never
    /// reads as negative — which is why a peer may see 33 bytes for a 32-byte
    /// coordinate. We send the same encoding, since that is what has been
    /// verified against real Android devices.
    static func signedBytes(_ data: Data) -> Data {
        let magnitude = magnitudeBytes(data)
        guard let first = magnitude.first else { return Data([0]) }
        return (first & 0x80) != 0 ? Data([0]) + magnitude : magnitude
    }

    /// Normalises an X or Y coordinate to exactly 32 bytes.
    ///
    /// Peers may send a coordinate with a leading zero sign byte (33 bytes) or
    /// with leading zeros stripped (fewer than 32), so trim from the left and
    /// zero-pad on the left as needed.
    static func normalizeCoordinate(_ data: Data) throws -> Data {
        if data.count == 32 { return data }
        if data.count > 32 {
            let trimmed = data.suffix(32)
            // Anything dropped must have been zero padding, not significant bits.
            guard data.prefix(data.count - 32).allSatisfy({ $0 == 0 }) else {
                throw SWIFTError.protocolViolation("EC coordinate out of range")
            }
            return Data(trimmed)
        }
        return Data(repeating: 0, count: 32 - data.count) + data
    }

    // MARK: Key pair

    public struct KeyPair: Sendable {
        public let privateKey: P256.KeyAgreement.PrivateKey
        public var publicKey: P256.KeyAgreement.PublicKey { privateKey.publicKey }

        public init() { privateKey = P256.KeyAgreement.PrivateKey() }
        init(privateKey: P256.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

        /// The public key as the protocol's x/y pair, in the same signed
        /// encoding the reference implementation put on the wire.
        public var ecP256: EcP256PublicKey {
            let raw = publicKey.rawRepresentation      // x‖y, 32 bytes each
            return EcP256PublicKey(x: signedBytes(Data(raw.prefix(32))),
                                   y: signedBytes(Data(raw.suffix(32))))
        }

        public var genericPublicKey: GenericPublicKey { GenericPublicKey(ecP256: ecP256) }
    }

    /// Rebuilds a peer's public key from the wire encoding, rejecting anything
    /// that isn't a point on P-256.
    ///
    /// The validation is not incidental. `P256.KeyAgreement.PublicKey(
    /// rawRepresentation:)` does **not** check the curve equation — it happily
    /// accepts all-zero and arbitrary coordinates — which would leave us open to
    /// an invalid-curve attack, where a peer sends a point on a weaker curve and
    /// learns something about our scalar from the resulting shared secret. The
    /// X9.63 initialiser does validate, so the peer key always goes through it.
    /// (The reference implementation validated too; using the raw initialiser
    /// would have been a silent regression.)
    public static func publicKey(from key: EcP256PublicKey) throws -> P256.KeyAgreement.PublicKey {
        guard let x = key.x, let y = key.y else {
            throw SWIFTError.protocolViolation("EC public key missing a coordinate")
        }
        // 0x04 marks an uncompressed X9.63 point.
        let x963 = Data([0x04]) + (try normalizeCoordinate(x)) + (try normalizeCoordinate(y))
        do {
            return try P256.KeyAgreement.PublicKey(x963Representation: x963)
        } catch {
            throw SWIFTError.protocolViolation("EC public key is not a valid P-256 point")
        }
    }

    // MARK: Derived material

    /// Everything the handshake produces.
    public struct SessionKeys: Sendable {
        public let authString: SymmetricKey
        public let pinCode: String
        public let encryptKey: SymmetricKey
        public let decryptKey: SymmetricKey
        public let sendHmacKey: SymmetricKey
        public let recvHmacKey: SymmetricKey
    }

    /// Runs the UKEY2 derivation.
    ///
    /// - Parameters:
    ///   - clientInitBytes/serverInitBytes: the exact handshake message bytes as
    ///     they went over the wire — they are hashed into the transcript, so a
    ///     re-serialization would break agreement.
    ///   - isServer: which half of the client/server key split we own.
    public static func deriveSessionKeys(
        ourPrivateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey,
        clientInitBytes: Data,
        serverInitBytes: Data,
        isServer: Bool
    ) throws -> SessionKeys {
        let shared = try ourPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        // Magnitude encoding, not the zero-padded fixed-width form.
        let dhs = magnitudeBytes(sharedBytes)
        let derivedSecret = SymmetricKey(data: Data(SHA256.hash(data: dhs)))

        let transcript = clientInitBytes + serverInitBytes

        let authString = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: derivedSecret,
            salt: Data("UKEY2 v1 auth".utf8),
            info: transcript,
            outputByteCount: 32)
        let nextSecret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: derivedSecret,
            salt: Data("UKEY2 v1 next".utf8),
            info: transcript,
            outputByteCount: 32)

        let d2dClientKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: nextSecret, salt: d2dSalt,
            info: Data("client".utf8), outputByteCount: 32)
        let d2dServerKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: nextSecret, salt: d2dSalt,
            info: Data("server".utf8), outputByteCount: 32)

        let smsgSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))
        func subKey(_ key: SymmetricKey, _ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: smsgSalt,
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        let clientEnc = subKey(d2dClientKey, "ENC:2")
        let clientSig = subKey(d2dClientKey, "SIG:1")
        let serverEnc = subKey(d2dServerKey, "ENC:2")
        let serverSig = subKey(d2dServerKey, "SIG:1")

        return SessionKeys(
            authString: authString,
            pinCode: pinCode(from: authString),
            encryptKey: isServer ? serverEnc : clientEnc,
            decryptKey: isServer ? clientEnc : serverEnc,
            sendHmacKey: isServer ? serverSig : clientSig,
            recvHmacKey: isServer ? clientSig : serverSig)
    }

    /// The 4-digit verification code shown on both devices.
    ///
    /// Bytes are interpreted as *signed* and the running value can go negative;
    /// Swift's `%` keeps the sign, matching the reference. This is a display
    /// value for the user to compare out of band — nothing in the protocol
    /// verifies it, so it is never an authorization decision.
    public static func pinCode(from key: SymmetricKey) -> String {
        var hash = 0
        var multiplier = 1
        let bytes = key.withUnsafeBytes { [UInt8]($0) }
        for byte in bytes {
            let signed = Int(Int8(bitPattern: byte))
            hash = (hash + signed * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }
}

// MARK: - UKEY2 frames

// ukey.proto — the UKEY2 authenticated key-exchange handshake messages.

public enum Ukey2HandshakeCipher: Int, Sendable {
    case reserved = 0
    case p256Sha512 = 100
    case curve25519Sha512 = 200
}

public enum Ukey2MessageType: Int, Sendable {
    case unknownDoNotUse = 0
    case alert = 1
    case clientInit = 2
    case serverInit = 3
    case clientFinish = 4
}

public enum Ukey2AlertType: Int, Sendable {
    case badMessage = 1
    case badMessageType = 2
    case incorrectMessage = 3
    case badMessageData = 4
    case badVersion = 100
    case badRandom = 101
    case badHandshakeCipher = 102
    case badNextProtocol = 103
    case badPublicKey = 104
    case internalError = 200
}

/// Envelope for every handshake message.
public struct Ukey2Message: ProtoMessage {
    public var messageType: Ukey2MessageType?
    public var messageData: Data?

    public init() {}
    public init(type: Ukey2MessageType, data: Data) {
        self.messageType = type
        self.messageData = data
    }

    public func encode(to w: inout ProtoWriter) {
        if let v = messageType { w.write(field: 1, enumValue: v.rawValue) }
        if let v = messageData { w.write(field: 2, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint):
            let raw = Int(try reader.readInt32())
            guard let v = Ukey2MessageType(rawValue: raw) else {
                throw ProtoWireError.invalidEnumValue(field: "Ukey2Message.messageType", value: raw)
            }
            messageType = v
        case (2, .lengthDelimited): messageData = try reader.readBytes()
        default: return false
        }
        return true
    }

    public func validate() throws {
        guard messageType != nil else { throw ProtoWireError.missingRequiredField("Ukey2Message.messageType") }
    }
}

public struct Ukey2CipherCommitment: ProtoMessage {
    public var handshakeCipher: Ukey2HandshakeCipher?
    public var commitment: Data?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = handshakeCipher { w.write(field: 1, enumValue: v.rawValue) }
        if let v = commitment { w.write(field: 2, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint):
            // An unrecognised cipher is not fatal: the peer may offer several and
            // we simply won't select it.
            handshakeCipher = Ukey2HandshakeCipher(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): commitment = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct Ukey2ClientInit: ProtoMessage {
    public var version: Int32?
    public var random: Data?
    public var cipherCommitments: [Ukey2CipherCommitment] = []
    public var nextProtocol: String?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = version { w.write(field: 1, int32: v) }
        if let v = random { w.write(field: 2, bytes: v) }
        w.write(field: 3, repeated: cipherCommitments)
        if let v = nextProtocol { w.write(field: 4, string: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): version = try reader.readInt32()
        case (2, .lengthDelimited): random = try reader.readBytes()
        case (3, .lengthDelimited): try decodeNestedAppending(&cipherCommitments, from: &reader)
        case (4, .lengthDelimited): nextProtocol = try reader.readString()
        default: return false
        }
        return true
    }
}

public struct Ukey2ServerInit: ProtoMessage {
    public var version: Int32?
    public var random: Data?
    public var handshakeCipher: Ukey2HandshakeCipher?
    public var publicKey: Data?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = version { w.write(field: 1, int32: v) }
        if let v = random { w.write(field: 2, bytes: v) }
        if let v = handshakeCipher { w.write(field: 3, enumValue: v.rawValue) }
        if let v = publicKey { w.write(field: 4, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): version = try reader.readInt32()
        case (2, .lengthDelimited): random = try reader.readBytes()
        case (3, .varint): handshakeCipher = Ukey2HandshakeCipher(rawValue: Int(try reader.readInt32()))
        case (4, .lengthDelimited): publicKey = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct Ukey2ClientFinished: ProtoMessage {
    public var publicKey: Data?

    public init() {}

    public func encode(to w: inout ProtoWriter) {
        if let v = publicKey { w.write(field: 1, bytes: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .lengthDelimited): publicKey = try reader.readBytes()
        default: return false
        }
        return true
    }
}

public struct Ukey2Alert: ProtoMessage {
    public var type: Ukey2AlertType?
    public var errorMessage: String?

    public init() {}
    public init(type: Ukey2AlertType) { self.type = type }

    public func encode(to w: inout ProtoWriter) {
        if let v = type { w.write(field: 1, enumValue: v.rawValue) }
        if let v = errorMessage { w.write(field: 2, string: v) }
    }

    public mutating func decode(field: UInt32, wireType: ProtoWireType,
                                reader: inout ProtoReader) throws -> Bool {
        switch (field, wireType) {
        case (1, .varint): type = Ukey2AlertType(rawValue: Int(try reader.readInt32()))
        case (2, .lengthDelimited): errorMessage = try reader.readString()
        default: return false
        }
        return true
    }
}
