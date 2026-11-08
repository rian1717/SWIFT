import XCTest
@testable import SWIFTCore

/// `mediums` was missing from our connection request — the reference
/// implementation sent it and the rewrite dropped it. There's no golden fixture
/// for it, so the expected bytes are derived by hand from the wire format.
final class ConnectionMediumTests: XCTestCase {

    /// proto2 repeated enums are *unpacked*: one varint field per element.
    /// Field 5, wire type 0 → tag 0x28; `wifiLan` = 5 → 0x05.
    func testMediumsEncodeUnpacked() {
        var frame = ConnectionRequestFrame()
        frame.mediums = [.wifiLan]
        XCTAssertEqual(frame.serialized().hexString, "2805")
    }

    func testSeveralMediumsEachGetTheirOwnTag() {
        var frame = ConnectionRequestFrame()
        frame.mediums = [.wifiLan, .bluetooth]
        XCTAssertEqual(frame.serialized().hexString, "28052802")
    }

    /// Field order must stay ascending: endpointID(1), endpointName(2),
    /// mediums(5), endpointInfo(6).
    func testFieldOrderIsAscending() throws {
        var frame = ConnectionRequestFrame()
        frame.endpointID = "ABCD"
        frame.endpointName = "Mac"
        frame.endpointInfo = Data([0xAA])
        frame.mediums = [.wifiLan]

        let hex = frame.serialized().hexString
        let idAt = try XCTUnwrap(hex.range(of: "0a04")).lowerBound      // field 1
        let mediumAt = try XCTUnwrap(hex.range(of: "2805")).lowerBound  // field 5
        let infoAt = try XCTUnwrap(hex.range(of: "3201")).lowerBound    // field 6
        XCTAssertTrue(idAt < mediumAt, "field 1 must precede field 5")
        XCTAssertTrue(mediumAt < infoAt, "field 5 must precede field 6")
    }

    func testRoundTrip() throws {
        var frame = ConnectionRequestFrame()
        frame.endpointID = "WXYZ"
        frame.endpointName = "Test Mac"
        frame.endpointInfo = Data(repeating: 0x55, count: 20)
        frame.mediums = [.wifiLan]

        let decoded = try ConnectionRequestFrame(serialized: frame.serialized())
        XCTAssertEqual(decoded.mediums, [.wifiLan])
        XCTAssertEqual(decoded.endpointID, "WXYZ")
        XCTAssertEqual(decoded.endpointInfo, frame.endpointInfo)
    }

    /// We send unpacked, but a peer may send packed; accept both.
    func testPackedMediumsAreAlsoAccepted() throws {
        // Field 5, wire type 2 → 0x2A; length 2; values 5 and 2.
        let packed = Data([0x2A, 0x02, 0x05, 0x02])
        let decoded = try ConnectionRequestFrame(serialized: packed)
        XCTAssertEqual(decoded.mediums, [.wifiLan, .bluetooth])
    }

    /// An unknown medium must be skipped, not crash the handshake.
    func testUnknownMediumIsIgnored() throws {
        let unknown = Data([0x28, 0x7F])   // field 5, value 127
        let decoded = try ConnectionRequestFrame(serialized: unknown)
        XCTAssertTrue(decoded.mediums.isEmpty)
    }
}
