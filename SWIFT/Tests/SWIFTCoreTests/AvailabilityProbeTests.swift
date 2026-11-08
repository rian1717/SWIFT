import Darwin
import Network
import XCTest
@testable import SWIFTCore

final class AvailabilityProbeTests: XCTestCase {
    func testAnOpenPortCountsAsAvailable() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let ok = await ServiceBrowser.canConnect(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertTrue(ok)
        listener.cancel()
    }

    func testAClosedPortIsNotAvailable() async throws {
        // Reserve a free port with a plain socket, then close it so nothing listens.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        close(fd)
        let ok = await ServiceBrowser.canConnect(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertFalse(ok)
    }

    func testABadAddressIsNotAvailable() async {
        let ok = await ServiceBrowser.canConnect(host: "not-an-ip", port: 1, timeout: 1)
        XCTAssertFalse(ok)
    }
}
