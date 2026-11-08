import XCTest
@testable import SWIFTCore

final class NearbyPeersTests: XCTestCase {
    func testOnePhoneWithTwoAdvertisementsIsOneRow() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "named", address: "192.168.1.20", advertisedName: "Pixel 8"),
            ShareSighting(id: "extra", address: "192.168.1.20", advertisedName: nil),
        ])
        XCTAssertEqual(rows, [ShareRow(id: "named", name: "Pixel 8")])
    }

    func testSavedControllerNameIsNotASecondDevice() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "phone", address: "192.168.1.20", advertisedName: "Pixel 8"),
            ShareSighting(id: "ghost", address: "192.168.1.20",
                          advertisedName: "Xbox Wireless Controller"),
        ])
        XCTAssertEqual(rows, [ShareRow(id: "phone", name: "Pixel 8")])
    }

    func testControllerAloneIsNotListed() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "ghost", address: "192.168.1.20",
                          advertisedName: "Xbox Wireless Controller"),
        ])
        XCTAssertTrue(rows.isEmpty)
    }

    func testUnnamedAdvertisementStaysHidden() {
        XCTAssertTrue(NearbyPeers.rows([
            ShareSighting(id: "quiet", address: "192.168.1.20"),
        ]).isEmpty)
    }

    func testTwoPhonesStaySeparate() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "a", address: "192.168.1.20", advertisedName: "Pixel 8"),
            ShareSighting(id: "b", address: "192.168.1.30", advertisedName: "Pixel 8 Pro"),
        ])
        XCTAssertEqual(Set(rows.map(\.name)), Set(["Pixel 8", "Pixel 8 Pro"]))
        XCTAssertEqual(rows.count, 2)
    }

    func testSameEndpointIdIsOnePhone() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "service-a", endpointKey: "AB12", advertisedName: "Pixel 8"),
            ShareSighting(id: "service-b", endpointKey: "AB12", address: "192.168.1.20"),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Pixel 8")
        XCTAssertEqual(rows.first?.id, "service-b")
    }

    func testLongerNameWinsInsideOnePhone() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "short", address: "192.168.1.20", advertisedName: "Pixel 8"),
            ShareSighting(id: "long", address: "192.168.1.20", advertisedName: "rai pixel 8"),
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "rai pixel 8")
    }

    func testMatchedBluetoothNameFillsABlankAdvertisement() {
        let rows = NearbyPeers.rows([
            ShareSighting(id: "phone", endpointKey: "ZX81", matchedName: "Pixel 8"),
        ])
        XCTAssertEqual(rows, [ShareRow(id: "phone", name: "Pixel 8")])
    }
}
