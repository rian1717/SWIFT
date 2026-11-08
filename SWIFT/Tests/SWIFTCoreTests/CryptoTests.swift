import XCTest
import CryptoKit
@testable import SWIFTCore

/// Pins the key agreement to vectors cross-checked against the reference
/// implementation (SwiftECC) before that dependency was removed.
final class KeyAgreementVectorTests: XCTestCase {

    func testAgreementMatchesCapturedVectors() throws {
        XCTAssertFalse(CryptoVectors.all.isEmpty, "vector set is empty")
        var shortSecrets = 0

        for (i, v) in CryptoVectors.all.enumerated() {
            let priv = try P256.KeyAgreement.PrivateKey(
                rawRepresentation: try XCTUnwrap(Data(hex: v.privateKey)))
            var wire = EcP256PublicKey()
            wire.x = try XCTUnwrap(Data(hex: v.peerX))
            wire.y = try XCTUnwrap(Data(hex: v.peerY))

            let peer = try UKey2.publicKey(from: wire)
            let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
            let magnitude = UKey2.magnitudeBytes(shared.withUnsafeBytes { Data($0) })

            XCTAssertEqual(magnitude.hexString, v.expectedSharedMagnitude,
                           "vector \(i) diverged from the reference")
            if magnitude.count < 32 { shortSecrets += 1 }
        }

        // The whole reason these vectors exist: without magnitude encoding these
        // cases would derive different keys from the peer.
        XCTAssertGreaterThan(shortSecrets, 0,
                             "vector set no longer covers leading-zero shared secrets")
    }

    /// Leading zeros must be stripped, matching the reference's magnitude form.
    func testMagnitudeBytesStripsLeadingZeros() {
        XCTAssertEqual(UKey2.magnitudeBytes(Data([0x00, 0x00, 0xAB, 0xCD])), Data([0xAB, 0xCD]))
        XCTAssertEqual(UKey2.magnitudeBytes(Data([0xAB, 0x00])), Data([0xAB, 0x00]))
        XCTAssertEqual(UKey2.magnitudeBytes(Data([0x00, 0x00])), Data())
        XCTAssertEqual(UKey2.magnitudeBytes(Data()), Data())
    }

    // MARK: Coordinate normalisation

    func testCoordinateNormalisation() throws {
        let exact = Data(repeating: 0x11, count: 32)
        XCTAssertEqual(try UKey2.normalizeCoordinate(exact), exact)

        // 33 bytes with a leading zero sign byte → trimmed.
        XCTAssertEqual(try UKey2.normalizeCoordinate(Data([0x00]) + exact), exact)

        // Short → left-padded.
        let short = Data(repeating: 0x22, count: 30)
        let padded = try UKey2.normalizeCoordinate(short)
        XCTAssertEqual(padded.count, 32)
        XCTAssertEqual(padded.prefix(2), Data([0x00, 0x00]))
        XCTAssertEqual(padded.suffix(30), short)
    }

    /// Dropping significant bytes would silently accept a wrong key.
    func testOversizedCoordinateWithSignificantBytesIsRejected() {
        let bad = Data([0x01]) + Data(repeating: 0x11, count: 32)
        XCTAssertThrowsError(try UKey2.normalizeCoordinate(bad))
    }

    /// A point that isn't on the curve must be refused, not used.
    ///
    /// This guards a real trap: CryptoKit's `rawRepresentation` initialiser does
    /// not check the curve equation, so a naive port would silently accept
    /// attacker-chosen points and enable an invalid-curve attack.
    func testInvalidCurvePointIsRejected() {
        for (x, y) in [(Data(repeating: 0x01, count: 32), Data(repeating: 0x02, count: 32)),
                       (Data(repeating: 0x00, count: 32), Data(repeating: 0x00, count: 32)),
                       (Data(repeating: 0xFF, count: 32), Data(repeating: 0xFF, count: 32))] {
            var wire = EcP256PublicKey()
            wire.x = x
            wire.y = y
            XCTAssertThrowsError(try UKey2.publicKey(from: wire),
                                 "accepted an off-curve point")
        }
    }

    /// A single flipped bit takes a valid key off the curve; it must be refused.
    func testBitFlippedPublicKeyIsRejected() throws {
        let valid = P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        var flipped = valid
        flipped[63] ^= 0x01
        var wire = EcP256PublicKey()
        wire.x = Data(flipped.prefix(32))
        wire.y = Data(flipped.suffix(32))
        XCTAssertThrowsError(try UKey2.publicKey(from: wire))

        // Sanity: the unmodified key is still accepted.
        var ok = EcP256PublicKey()
        ok.x = Data(valid.prefix(32))
        ok.y = Data(valid.suffix(32))
        XCTAssertNoThrow(try UKey2.publicKey(from: ok))
    }

    func testMissingCoordinateIsRejected() {
        var wire = EcP256PublicKey()
        wire.x = Data(repeating: 0x01, count: 32)
        XCTAssertThrowsError(try UKey2.publicKey(from: wire))
    }
}

final class PinCodeTests: XCTestCase {

    /// The PIN algorithm treats bytes as signed and keeps a signed running sum.
    /// These are pinned so a refactor can't quietly change what the user sees.
    func testKnownPins() {
        func pin(_ bytes: [UInt8]) -> String {
            UKey2.pinCode(from: SymmetricKey(data: Data(bytes)))
        }
        XCTAssertEqual(pin([UInt8](repeating: 0x00, count: 32)), "0000")
        XCTAssertEqual(pin([0x01] + [UInt8](repeating: 0x00, count: 31)), "0001")
        // 0xFF is -1 signed: the running hash goes negative and is abs()'d.
        XCTAssertEqual(pin([0xFF] + [UInt8](repeating: 0x00, count: 31)), "0001")
    }

    func testPinIsAlwaysFourDigits() {
        for _ in 0..<500 {
            let key = SymmetricKey(data: Data.secureRandom(count: 32))
            let pin = UKey2.pinCode(from: key)
            XCTAssertEqual(pin.count, 4, "got \(pin)")
            XCTAssertTrue(pin.allSatisfy(\.isNumber), "got \(pin)")
        }
    }

    func testPinIsDeterministic() {
        let key = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(UKey2.pinCode(from: key), UKey2.pinCode(from: key))
    }
}

final class SecureMessageCodecTests: XCTestCase {

    /// Two peers that ran the same handshake, from both sides.
    private func peerCodecs() throws -> (server: SecureMessageCodec, client: SecureMessageCodec) {
        let serverKey = P256.KeyAgreement.PrivateKey()
        let clientKey = P256.KeyAgreement.PrivateKey()
        let clientInit = Data("client-init-transcript".utf8)
        let serverInit = Data("server-init-transcript".utf8)

        let serverKeys = try UKey2.deriveSessionKeys(
            ourPrivateKey: serverKey, peerPublicKey: clientKey.publicKey,
            clientInitBytes: clientInit, serverInitBytes: serverInit, isServer: true)
        let clientKeys = try UKey2.deriveSessionKeys(
            ourPrivateKey: clientKey, peerPublicKey: serverKey.publicKey,
            clientInitBytes: clientInit, serverInitBytes: serverInit, isServer: false)

        // Both sides must land on the same verification code.
        XCTAssertEqual(serverKeys.pinCode, clientKeys.pinCode)
        return (SecureMessageCodec(keys: serverKeys), SecureMessageCodec(keys: clientKeys))
    }

    func testRoundTripBetweenPeers() throws {
        let (server, client) = try peerCodecs()
        for size in [0, 1, 15, 16, 17, 1024, 65_536] {
            let plaintext = Data.secureRandom(count: size)
            XCTAssertEqual(try client.open(server.seal(plaintext)), plaintext, "size \(size)")
            XCTAssertEqual(try server.open(client.seal(plaintext)), plaintext, "size \(size)")
        }
    }

    func testEachSealUsesAFreshIV() throws {
        let (server, _) = try peerCodecs()
        let plaintext = Data("same every time".utf8)
        var seen = Set<Data>()
        for _ in 0..<50 {
            let msg = try server.seal(plaintext)
            let hb = try HeaderAndBody(serialized: XCTUnwrap(msg.headerAndBody))
            let iv = try XCTUnwrap(hb.header?.iv)
            XCTAssertEqual(iv.count, 16)
            XCTAssertTrue(seen.insert(iv).inserted, "IV reused")
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let (server, client) = try peerCodecs()
        var msg = try server.seal(Data("secret".utf8))
        var hb = try HeaderAndBody(serialized: try XCTUnwrap(msg.headerAndBody))
        var body = try XCTUnwrap(hb.body)
        body[0] ^= 0x01
        hb.body = body
        msg.headerAndBody = hb.serialized()   // signature no longer matches

        XCTAssertThrowsError(try client.open(msg)) { error in
            XCTAssertEqual(error as? SWIFTError, .authenticationFailed)
        }
    }

    func testForgedSignatureIsRejected() throws {
        let (server, client) = try peerCodecs()
        var msg = try server.seal(Data("secret".utf8))
        msg.signature = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(try client.open(msg)) { error in
            XCTAssertEqual(error as? SWIFTError, .authenticationFailed)
        }
    }

    /// A different session must not be able to open our frames.
    func testKeysFromADifferentHandshakeCannotOpen() throws {
        let (server, _) = try peerCodecs()
        let (_, otherClient) = try peerCodecs()
        let msg = try server.seal(Data("secret".utf8))
        XCTAssertThrowsError(try otherClient.open(msg))
    }

    /// Misaligned ciphertext must be refused up front rather than decrypted into
    /// garbage — the behaviour CCCrypt's padding option quietly allowed.
    func testMisalignedCiphertextIsRejected() throws {
        let (server, client) = try peerCodecs()
        var msg = try server.seal(Data("secret".utf8))
        var hb = try HeaderAndBody(serialized: try XCTUnwrap(msg.headerAndBody))
        hb.body = Data(repeating: 0xAB, count: 17)   // not a multiple of 16
        msg.headerAndBody = hb.serialized()
        // Re-sign so we get past the MAC and actually reach the alignment check.
        msg.signature = Data(HMAC<SHA256>.authenticationCode(
            for: msg.headerAndBody!, using: serverSendKey(server)))

        XCTAssertThrowsError(try client.open(msg))
    }

    /// Reaches into the codec for the send key so the test above can re-sign.
    private func serverSendKey(_ codec: SecureMessageCodec) -> SymmetricKey {
        Mirror(reflecting: codec).children
            .first { $0.label == "sendHmacKey" }?.value as! SymmetricKey
    }

    func testMalformedIVIsRejected() throws {
        let (server, client) = try peerCodecs()
        var msg = try server.seal(Data("secret".utf8))
        var hb = try HeaderAndBody(serialized: try XCTUnwrap(msg.headerAndBody))
        hb.header?.iv = Data(repeating: 0x00, count: 8)   // wrong length
        msg.headerAndBody = hb.serialized()
        msg.signature = Data(HMAC<SHA256>.authenticationCode(
            for: msg.headerAndBody!, using: serverSendKey(server)))
        XCTAssertThrowsError(try client.open(msg))
    }
}

// MARK: - Helpers

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let b = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        self = Data(bytes)
    }
}
