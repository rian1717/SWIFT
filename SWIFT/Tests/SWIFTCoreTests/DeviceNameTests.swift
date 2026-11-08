import XCTest
@testable import SWIFTCore

final class DeviceNameTests: XCTestCase {
    func testCustomNameBeatsBluetoothSystemAndModel() {
        XCTAssertEqual(
            DeviceName.choose(custom: "rai pixel 8", bluetooth: "Pixel 8", system: "Pixel", model: "Pixel 8"),
            "rai pixel 8")
    }

    func testBluetoothNameBeatsSystemAndModel() {
        XCTAssertEqual(
            DeviceName.choose(custom: "  ", bluetooth: "rai pixel 8", system: "Pixel 8", model: "Pixel 8"),
            "rai pixel 8")
    }

    func testSystemNameBeatsModel() {
        XCTAssertEqual(
            DeviceName.choose(custom: nil, bluetooth: nil, system: "Rai's phone", model: "Pixel 8"),
            "Rai's phone")
    }

    func testModelIsTheLastResort() {
        XCTAssertEqual(DeviceName.choose(custom: nil, bluetooth: nil, system: nil, model: "Pixel 8"), "Pixel 8")
    }

    func testShorterModelDoesNotReplaceALongerName() {
        XCTAssertEqual(
            DeviceName.display(existing: "rai pixel 8", advertised: "Pixel 8", bluetooth: nil, alias: nil),
            "rai pixel 8")
        XCTAssertEqual(
            DeviceName.display(existing: nil, advertised: "Pixel 8", bluetooth: "rai pixel 8", alias: nil),
            "rai pixel 8")
    }

    func testSavedAliasWinsOverALaterAnnouncement() {
        XCTAssertEqual(
            DeviceName.display(existing: "Pixel 8", advertised: "Pixel 8", bluetooth: nil, alias: "rai pixel 8"),
            "rai pixel 8")
    }

    func testDifferentPhonesStayDistinct() {
        XCTAssertFalse(DeviceName.isShorterPiece("Pixel 8", of: "Pixel 8 Pro"))
        XCTAssertEqual(
            DeviceName.display(existing: "Pixel 8 Pro", advertised: "Pixel 8", bluetooth: nil, alias: nil),
            "Pixel 8")
    }

    func testSavedAccessoryIsNotAPhoneName() {
        XCTAssertFalse(DeviceName.isPossiblePhoneName("Xbox Wireless Controller"))
        XCTAssertFalse(DeviceName.isPossiblePhoneName("Rian’s Buds"))
        XCTAssertTrue(DeviceName.isPossiblePhoneName("Pixel 8"))
        XCTAssertTrue(DeviceName.isPossiblePhoneName("rai pixel 8"))
    }

    func testMissingNameStaysGeneric() {
        XCTAssertEqual(DeviceName.display(existing: nil, advertised: nil, bluetooth: " ", alias: nil), DeviceName.unnamed)
    }
}
