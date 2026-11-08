import XCTest
import Network
@testable import SWIFTCore

/// `events()` starts the session. Calling it twice used to replace the event
/// continuation and kick off a second handshake on a socket already in use.
final class SessionLifecycleTests: XCTestCase {

    private func deadConnection() -> NWConnection {
        // Discard port; nothing is listening, which is fine — these tests are
        // about the stream contract, not the wire.
        NWConnection(host: .ipv4(.loopback), port: 9, using: .tcp)
    }

    private func receiveDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-life-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The second call must hand back an already-finished stream rather than
    /// starting the session again.
    func testInboundEventsIsSingleShot() async throws {
        let dir = try receiveDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = InboundSession(connection: deadConnection(), id: "a", receiveDirectory: dir)

        _ = await session.events()
        let second = await session.events()

        var delivered = 0
        for await _ in second { delivered += 1 }
        XCTAssertEqual(delivered, 0, "a second events() must not run the session again")
    }

    func testOutboundEventsIsSingleShot() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-life-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let session = OutboundSession(
            connection: deadConnection(), id: "b",
            files: [try OutgoingFile.from(url: file)],
            localName: "Test", localEndpointID: "ab12")

        _ = await session.events()
        let second = await session.events()

        var delivered = 0
        for await _ in second { delivered += 1 }
        XCTAssertEqual(delivered, 0, "a second events() must not run the session again")
    }
}

/// Randomness is drawn in 64-bit words now rather than byte by byte; the
/// properties that matter shouldn't have changed.
final class SecureRandomTests: XCTestCase {

    func testProducesTheRequestedLength() {
        // Deliberately spans word boundaries: 15, 16, 17 around 8-byte chunks.
        for count in [0, 1, 7, 8, 9, 15, 16, 17, 32, 64, 1000] {
            XCTAssertEqual(Data.secureRandom(count: count).count, count, "count \(count)")
        }
    }

    func testDoesNotRepeat() {
        let samples = (0..<200).map { _ in Data.secureRandom(count: 16) }
        XCTAssertEqual(Set(samples).count, samples.count, "repeated output from a CSPRNG")
    }

    /// A bug in the chunked fill would most likely show as a stuck byte
    /// position — every draw sharing a value at some offset.
    func testEveryBytePositionVaries() {
        let width = 32
        let samples = (0..<128).map { _ in [UInt8](Data.secureRandom(count: width)) }
        for offset in 0..<width {
            let distinct = Set(samples.map { $0[offset] })
            XCTAssertGreaterThan(distinct.count, 1, "byte \(offset) never changed")
        }
    }
}
