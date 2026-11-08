import XCTest
@testable import SWIFTCore

/// Asserts the hand-written codec is byte-identical to the reference encoder.
///
/// `GoldenFixtures` holds wire bytes captured from apple/swift-protobuf before
/// that dependency was removed. Every message must:
///   1. encode to exactly the golden bytes, and
///   2. decode the golden bytes and round-trip back to them.
///
/// Together those pin us to the wire format an Android peer expects.
class GoldenWireTestCase: XCTestCase {

    func golden(_ name: String) throws -> Data {
        let b64 = try XCTUnwrap(GoldenFixtures.all[name], "no fixture named \(name)")
        return try XCTUnwrap(Data(base64Encoded: b64), "fixture \(name) is not valid base64")
    }

    /// Encode must match the reference bytes exactly, and decoding those bytes
    /// must reproduce them.
    func assertMatchesGolden<M: ProtoMessage>(_ message: M, _ name: String,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) throws {
        let expected = try golden(name)
        let actual = message.serialized()
        XCTAssertEqual(actual.hexString, expected.hexString,
                       "\(name): encoded bytes differ from the reference encoder",
                       file: file, line: line)

        let decoded = try M(serialized: expected)
        XCTAssertEqual(decoded.serialized().hexString, expected.hexString,
                       "\(name): decode->encode did not round-trip", file: file, line: line)
        XCTAssertEqual(decoded, message, "\(name): decoded value differs", file: file, line: line)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

final class SecureMessageWireTests: GoldenWireTestCase {

    private var sampleEcKey: EcP256PublicKey {
        EcP256PublicKey(x: Data((1...32).map { UInt8($0) }),
                        y: Data((33...64).map { UInt8($0) }))
    }

    private var sampleGeneric: GenericPublicKey {
        GenericPublicKey(ecP256: sampleEcKey)
    }

    func testEcP256PublicKey() throws {
        try assertMatchesGolden(sampleEcKey, "EcP256PublicKey")
    }

    func testGenericPublicKey() throws {
        try assertMatchesGolden(sampleGeneric, "GenericPublicKey")
    }

    func testHeader() throws {
        var meta = GcmMetadata()
        meta.type = .deviceToDeviceMessage
        meta.version = 1

        var header = SecureMessageHeader()
        header.encryptionScheme = .aes256Cbc
        header.signatureScheme = .hmacSha256
        header.iv = Data((0..<16).map { UInt8($0) })
        header.publicMetadata = meta.serialized()
        try assertMatchesGolden(header, "Header")
    }

    func testHeaderAndBody() throws {
        var meta = GcmMetadata()
        meta.type = .deviceToDeviceMessage
        meta.version = 1

        var header = SecureMessageHeader()
        header.encryptionScheme = .aes256Cbc
        header.signatureScheme = .hmacSha256
        header.iv = Data((0..<16).map { UInt8($0) })
        header.publicMetadata = meta.serialized()

        let hb = HeaderAndBody(header: header, body: Data(repeating: 0xAB, count: 48))
        try assertMatchesGolden(hb, "HeaderAndBody")
    }

    func testSecureMessage() throws {
        var meta = GcmMetadata()
        meta.type = .deviceToDeviceMessage
        meta.version = 1

        var header = SecureMessageHeader()
        header.encryptionScheme = .aes256Cbc
        header.signatureScheme = .hmacSha256
        header.iv = Data((0..<16).map { UInt8($0) })
        header.publicMetadata = meta.serialized()

        let hb = HeaderAndBody(header: header, body: Data(repeating: 0xAB, count: 48))
        let smsg = SecureMessage(headerAndBody: hb.serialized(),
                                 signature: Data(repeating: 0xCD, count: 32))
        try assertMatchesGolden(smsg, "SecureMessage")
    }

    func testGcmMetadata() throws {
        var meta = GcmMetadata()
        meta.type = .deviceToDeviceMessage
        meta.version = 1
        try assertMatchesGolden(meta, "GcmMetadata")
    }

    func testDeviceToDeviceMessage() throws {
        var d2d = DeviceToDeviceMessage()
        d2d.sequenceNumber = 7
        d2d.message = Data(repeating: 0x11, count: 20)
        try assertMatchesGolden(d2d, "DeviceToDeviceMessage")
    }

    // MARK: Required-field enforcement

    func testMissingRequiredFieldsAreRejected() {
        XCTAssertThrowsError(try SecureMessage(serialized: Data()))
        XCTAssertThrowsError(try EcP256PublicKey(serialized: Data()))
    }
}
