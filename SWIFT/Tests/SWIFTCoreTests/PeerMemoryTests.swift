import XCTest
import Network
@testable import SWIFTCore

final class PeerMemoryTests: XCTestCase {
    let mac = "5e:f9:9a:47:44:aa"

    func testLearnedNameIsFoundByHardwareAddress() {
        var memory = PeerMemory()
        XCTAssertTrue(memory.learn(name: " Rai's A32 ", hardware: mac))
        XCTAssertEqual(memory.name(hardware: mac), "Rai's A32")
        XCTAssertNil(memory.name(hardware: "aa:bb:cc:dd:ee:ff"))
    }

    func testPlaceholdersAndAccessoriesAreNotLearned() {
        var memory = PeerMemory()
        for name in ["", "Unknown device", DeviceName.unnamed, "Xbox Wireless Controller"] {
            XCTAssertFalse(memory.learn(name: name, hardware: mac), name)
        }
        XCTAssertTrue(memory.peers.isEmpty)
    }

    func testModelNameDoesNotReplaceALongerName() {
        var memory = PeerMemory()
        memory.learn(name: "Rai's Pixel 8", hardware: mac)
        XCTAssertFalse(memory.learn(name: "Pixel 8", hardware: mac))
        XCTAssertEqual(memory.name(hardware: mac), "Rai's Pixel 8")
    }

    func testCapacityDropsTheOldest() {
        var memory = PeerMemory()
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0...PeerMemory.capacity {
            memory.learn(name: "Phone \(i)", hardware: "h\(i)", now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(memory.peers.count, PeerMemory.capacity)
        XCTAssertNil(memory.name(hardware: "h0"))
    }

    /// The address is not known yet when a scan arrives, and the phone may be
    /// gone from the list by the time it is.
    @MainActor
    func testScannedNameIsKeptUntilTheAddressAppears() async {
        let browser = ServiceBrowser()
        browser.scanRetryDelay = .milliseconds(5)
        let address = mac
        let attempts = LookupAttempts()
        browser.hardwareLookup = { _ in await attempts.next() >= 3 ? address : nil }
        let saved = expectation(description: "saved")
        browser.onMemoryChanged = { _ in saved.fulfill() }

        browser.learnScanned(deviceID: "gone", name: "Rai's Pixel 8", host: "192.168.1.9")

        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(browser.memory.name(hardware: mac), "Rai's Pixel 8")
    }

    @MainActor
    func testScanWithoutARealNameLooksNothingUp() async throws {
        let browser = ServiceBrowser()
        browser.scanRetryDelay = .milliseconds(1)
        let attempts = LookupAttempts()
        browser.hardwareLookup = { _ in _ = await attempts.next(); return nil }

        browser.learnScanned(deviceID: "x", name: "Scanned device", host: "192.168.1.9")
        try await Task.sleep(for: .milliseconds(30))

        let used = await attempts.count
        XCTAssertEqual(used, 0)
    }

    func testArpParsing() {
        XCTAssertEqual(HardwareAddress.parse(arpOutput: "? (192.168.18.88) at bc:9:b9:b6:eb:4a on en0 ifscope [ethernet]\n"),
                       "bc:09:b9:b6:eb:4a")
        XCTAssertNil(HardwareAddress.parse(arpOutput: "? (192.168.18.117) at (incomplete) on en0 ifscope [ethernet]"))
        XCTAssertNil(HardwareAddress.parse(arpOutput: "? (192.168.18.255) at ff:ff:ff:ff:ff:ff on en0"))
        XCTAssertNil(HardwareAddress.parse(arpOutput: ""))
    }

    func testIPv4IsReadFromAMappedSocketAddress() throws {
        let mapped = try XCTUnwrap(IPv6Address("::ffff:192.168.18.34"))
        XCTAssertEqual(SWIFTEngine.ipv4Host(of: .hostPort(host: .ipv6(mapped), port: 1)), "192.168.18.34")
        XCTAssertEqual(SWIFTEngine.ipv4Host(of: .hostPort(host: .ipv4(.loopback), port: 1)), "127.0.0.1")
        let linkLocal = try XCTUnwrap(IPv6Address("fe80::1"))
        XCTAssertNil(SWIFTEngine.ipv4Host(of: .hostPort(host: .ipv6(linkLocal), port: 1)))
    }
}

private actor LookupAttempts {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
