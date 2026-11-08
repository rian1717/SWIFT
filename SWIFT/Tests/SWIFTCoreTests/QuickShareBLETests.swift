import XCTest
@testable import SWIFTCore

final class QuickShareBLETests: XCTestCase {

    func testServiceNameCarriesTheFourCharacterId() {
        let raw = Data([0x23, 0x52, 0x59, 0x5A, 0x45, 0xFC, 0x9F, 0x5E, 0x00, 0x00])
        let serviceName = raw.urlSafeBase64EncodedString()
        XCTAssertEqual(QuickShareBLE.endpointID(fromServiceName: serviceName), "RYZE")
        XCTAssertEqual(QuickShareBLE.endpointID(fromServiceName: "bd" + serviceName), "RYZE")
    }

    func testFastAdvertisementCarriesAPlainName() {
        // The protocol's example: endpoint ABCD, name Pixel.
        let bytes: [UInt8] = [
            0x4A, 0x0B,
            0x23, 0x41, 0x42, 0x43, 0x44, 0x05, 0x50, 0x69, 0x78, 0x65, 0x6C,
            0x12, 0x34,
        ]
        let sighting = QuickShareBLE.parse(serviceData: Data(bytes))
        XCTAssertEqual(sighting?.endpointID, "ABCD")
        XCTAssertEqual(sighting?.name, "Pixel")
    }

    func testHiddenWiFiRecordStillYieldsTheBluetoothName() {
        var hidden = Data([0x12])
        hidden.append(Data(repeating: 0, count: 16))
        var record = Data([0x23, 0x41, 0x42, 0x43, 0x44, UInt8(hidden.count)])
        record.append(hidden)
        var packet = Data([0x4A, UInt8(record.count)])
        packet.append(record)
        let name = Array("RYZE S22".utf8)
        packet.append(UInt8(name.count))
        packet.append(contentsOf: name)

        let sighting = QuickShareBLE.parse(serviceData: packet)
        XCTAssertEqual(sighting?.endpointID, "ABCD")
        XCTAssertEqual(sighting?.name, "RYZE S22")
    }

    func testPlaceholderAdvertisementIsIgnored() {
        let placeholder = Data("QCAAABACAAADAAAAAAAAAAA".utf8)
        XCTAssertNil(QuickShareBLE.parse(serviceData: placeholder))
    }

    func testRandomBytesNeverBecomeAName() {
        // A hidden-name record followed by noise that happens to hold the letters "wT".
        var hidden = Data([0x32])
        hidden.append(Data(repeating: 0, count: 16))
        var record = Data([0x23, 0x41, 0x42, 0x43, 0x44, UInt8(hidden.count)])
        record.append(hidden)
        var packet = Data([0x4A, UInt8(record.count)])
        packet.append(record)
        packet.append(contentsOf: [0xF1, 0x02, 0x77, 0x54, 0x9C, 0x00, 0x13])
        let sighting = QuickShareBLE.parse(serviceData: packet)
        XCTAssertEqual(sighting?.endpointID, "ABCD")
        XCTAssertNil(sighting?.name)
    }

    func testNameLaterInThePacketIsRead() {
        var hidden = Data([0x32])
        hidden.append(Data(repeating: 0, count: 16))
        var record = Data([0x23, 0x41, 0x42, 0x43, 0x44, UInt8(hidden.count)])
        record.append(hidden)
        var packet = Data([0x4A, UInt8(record.count)])
        packet.append(record)
        packet.append(contentsOf: [0x12, 0x34])
        let name = Array("Rai's A32".utf8)
        packet.append(UInt8(name.count))
        packet.append(contentsOf: name)
        XCTAssertEqual(QuickShareBLE.parse(serviceData: packet)?.name, "Rai's A32")
    }

    func testLettersInsideTheRecordAreNotAName() {
        var hidden = Data([0x32, 0x05])
        hidden.append(contentsOf: Array("Ghost".utf8))
        hidden.append(Data(repeating: 0, count: 10))
        var record = Data([0x23, 0x41, 0x42, 0x43, 0x44, UInt8(hidden.count)])
        record.append(hidden)
        var packet = Data([0x4A, UInt8(record.count)])
        packet.append(record)
        XCTAssertNil(QuickShareBLE.parse(serviceData: packet)?.name)
    }
}
