import XCTest
import Network
@testable import SWIFTCore

/// End-to-end: our sender and our receiver, over a real TCP socket.
///
/// This is the test that would have caught the send bug. `sendFiles` used to be
/// a write-only loop, so it never answered the peer's keep-alives and never saw
/// a cancel — the phone gave up while we cheerfully reported success. Anything
/// that regresses the concurrent reader shows up here.
final class LoopbackTransferTests: XCTestCase {

    /// Guards a continuation against a second resume.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// A listener that publishes accepted connections as a stream, so the test
    /// can await one without hand-rolling locked state.
    private final class Acceptor: @unchecked Sendable {
        private let listener: NWListener
        private var iterator: AsyncStream<NWConnection>.AsyncIterator
        private let continuation: AsyncStream<NWConnection>.Continuation

        var port: NWEndpoint.Port { listener.port ?? .any }

        init() throws {
            listener = try NWListener(using: .tcp)
            var captured: AsyncStream<NWConnection>.Continuation!
            let stream = AsyncStream<NWConnection> { captured = $0 }
            continuation = captured
            iterator = stream.makeAsyncIterator()
            listener.newConnectionHandler = { [continuation] connection in
                continuation.yield(connection)
            }
        }

        func start() async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let once = OneShot()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { c.resume() }
                    case .failed(let error):
                        if once.claim() { c.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.start(queue: .global())
            }
        }

        func nextConnection() async throws -> NWConnection {
            guard let connection = await iterator.next() else {
                throw SWIFTError.connectionLost
            }
            return connection
        }

        func stop() {
            continuation.finish()
            listener.cancel()
        }
    }

    /// Fails fast instead of hanging the suite if a session deadlocks.
    private func withTimeout<T: Sendable>(_ seconds: Double,
                                          _ operation: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SWIFTError.timedOut
            }
            guard let first = try await group.next() else { throw SWIFTError.timedOut }
            group.cancelAll()
            return first
        }
    }

    private func makeTempFile(bytes: Int, name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        // Compressible-but-varied content, so a truncated transfer is detectable.
        var data = Data(capacity: bytes)
        var seed: UInt8 = 7
        for _ in 0..<bytes {
            seed = seed &* 31 &+ 17
            data.append(seed)
        }
        try data.write(to: url)
        return url
    }

    /// Add phone leaves the scanner a short text, so scanning ends normally.
    func testAddPhoneNoteArrivesAsText() async throws {
        let acceptor = try Acceptor()
        try await acceptor.start()
        defer { acceptor.stop() }
        let receiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: receiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: receiveDir) }

        let outbound = OutboundSession(
            connection: NWConnection(host: .ipv4(.loopback), port: acceptor.port, using: .tcp),
            id: "note", files: [], localName: "Test Mac", localEndpointID: "ab12",
            qrSession: QRCodeSession(), note: "Added to Test Mac")
        let sendTask = Task { () -> Bool in
            var finished = false
            for await event in await outbound.events() {
                if case .finished = event { finished = true }
            }
            return finished
        }
        let inbound = InboundSession(connection: try await acceptor.nextConnection(), id: "r",
                                     receiveDirectory: receiveDir)
        let receiveTask = Task { () -> [URL] in
            var saved: [URL] = []
            for await event in await inbound.events() {
                switch event {
                case .offerReceived(let offer):
                    XCTAssertEqual(offer.textTitle, "SWIFT")
                    await inbound.respond(accept: true)
                case .finished(let urls): saved = urls
                case .failed(let error): XCTFail("receive failed: \(error)")
                case .progress: continue
                }
            }
            return saved
        }
        let sent = try await withTimeout(30) { await sendTask.value }
        let saved = try await withTimeout(30) { await receiveTask.value }
        XCTAssertTrue(sent)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try String(contentsOf: saved[0], encoding: .utf8), "Added to Test Mac")
    }

    func testQRProofUsesTheFieldPhonesRead() throws {
        var frame = PairedKeyEncryptionFrame()
        frame.qrCodeHandshakeData = Data([1, 2, 3])
        XCTAssertEqual(frame.serialized(), Data([0x22, 0x03, 1, 2, 3]))
        XCTAssertEqual(try PairedKeyEncryptionFrame(serialized: frame.serialized()).qrCodeHandshakeData,
                       Data([1, 2, 3]))
    }

    /// A file sent by OutboundSession must arrive intact at InboundSession, and
    /// both sides must report success.
    func testFileRoundTripsBetweenOurOwnSessions() async throws {
        let acceptor = try Acceptor()
        try await acceptor.start()
        defer { acceptor.stop() }

        // A payload big enough to span several 512 KB chunks.
        let sourceURL = try makeTempFile(bytes: 1_400_000, name: "clip.mov")
        let expected = try Data(contentsOf: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let receiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-recv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiveDir) }

        // Sender dials the listener; receiver wraps whatever gets accepted.
        let clientConnection = NWConnection(
            host: .ipv4(.loopback), port: acceptor.port, using: .tcp)
        let outbound = OutboundSession(
            connection: clientConnection, id: "t1",
            files: [try OutgoingFile.from(url: sourceURL)],
            localName: "Test Mac", localEndpointID: "ab12")

        // Start the sender FIRST: events() is what dials the listener, so
        // waiting to accept before calling it would wait forever.
        let sendTask = Task { () -> [String] in
            var events: [String] = []
            for await event in await outbound.events() {
                switch event {
                case .connected(let pin):
                    XCTAssertEqual(pin.count, 4)
                    events.append("connected")
                case .accepted: events.append("accepted")
                case .finished: events.append("finished")
                case .failed(let error): events.append("failed(\(error))")
                case .progress: continue
                }
            }
            return events
        }

        let serverConnection = try await acceptor.nextConnection()
        let inbound = InboundSession(connection: serverConnection, id: "r1",
                                     receiveDirectory: receiveDir)

        // Receiver: accept the offer as soon as it arrives.
        let receiveTask = Task { () -> [URL] in
            var saved: [URL] = []
            for await event in await inbound.events() {
                switch event {
                case .offerReceived:
                    await inbound.respond(accept: true)
                case .finished(let urls):
                    saved = urls
                case .failed(let error):
                    XCTFail("receive failed: \(error)")
                case .progress:
                    continue
                }
            }
            return saved
        }

        let sendEvents = try await withTimeout(60) { await sendTask.value }
        let savedURLs = try await withTimeout(60) { await receiveTask.value }

        XCTAssertTrue(sendEvents.contains("connected"), "events: \(sendEvents)")
        XCTAssertTrue(sendEvents.contains("accepted"), "events: \(sendEvents)")
        XCTAssertTrue(sendEvents.contains("finished"),
                      "sender should report success; got \(sendEvents)")
        XCTAssertFalse(sendEvents.contains { $0.hasPrefix("failed") },
                       "sender reported a failure: \(sendEvents)")

        let saved = try XCTUnwrap(savedURLs.first, "receiver saved nothing")
        XCTAssertEqual(saved.lastPathComponent, "clip.mov")
        XCTAssertEqual(try Data(contentsOf: saved), expected,
                       "received bytes differ from what was sent")
    }

    /// A successful send must not sit waiting out the settle timeout.
    ///
    /// The peer's close wakes us; only a peer that goes quiet without closing
    /// should cost the full window. This pins that the fast path is fast — the
    /// earlier polling version added up to 2s to every transfer.
    func testSuccessfulSendCompletesPromptly() async throws {
        let acceptor = try Acceptor()
        try await acceptor.start()
        defer { acceptor.stop() }

        let sourceURL = try makeTempFile(bytes: 64_000, name: "quick.bin")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }
        let receiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-recv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiveDir) }

        let clientConnection = NWConnection(
            host: .ipv4(.loopback), port: acceptor.port, using: .tcp)
        let outbound = OutboundSession(
            connection: clientConnection, id: "t3",
            files: [try OutgoingFile.from(url: sourceURL)],
            localName: "Test Mac", localEndpointID: "ab12")

        let started = Date()
        let sendTask = Task { () -> [String] in
            var events: [String] = []
            for await event in await outbound.events() {
                switch event {
                case .finished: events.append("finished")
                case .failed(let error): events.append("failed(\(error.userMessage))")
                default: continue
                }
            }
            return events
        }

        let serverConnection = try await acceptor.nextConnection()
        let inbound = InboundSession(connection: serverConnection, id: "r3",
                                     receiveDirectory: receiveDir)
        let receiveTask = Task {
            for await event in await inbound.events() {
                if case .offerReceived = event { await inbound.respond(accept: true) }
            }
        }

        let sendEvents = try await withTimeout(60) { await sendTask.value }
        _ = try await withTimeout(60) { await receiveTask.value }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(sendEvents.contains("finished"), "events: \(sendEvents)")
        XCTAssertLessThan(elapsed, 1.5,
                          "a small transfer took \(elapsed)s — the settle wait isn't being woken")
    }

    /// Declining must surface as a rejection on the sender, not as success.
    func testDeclineIsReportedAsFailureNotSuccess() async throws {
        let acceptor = try Acceptor()
        try await acceptor.start()
        defer { acceptor.stop() }

        let sourceURL = try makeTempFile(bytes: 2_048, name: "small.bin")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let receiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-recv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiveDir) }

        let clientConnection = NWConnection(
            host: .ipv4(.loopback), port: acceptor.port, using: .tcp)
        let outbound = OutboundSession(
            connection: clientConnection, id: "t2",
            files: [try OutgoingFile.from(url: sourceURL)],
            localName: "Test Mac", localEndpointID: "ab12")

        let sendTask = Task { () -> [String] in
            var events: [String] = []
            for await event in await outbound.events() {
                switch event {
                case .finished: events.append("finished")
                case .failed(let error): events.append("failed(\(error.userMessage))")
                default: continue
                }
            }
            return events
        }

        let serverConnection = try await acceptor.nextConnection()
        let inbound = InboundSession(connection: serverConnection, id: "r2",
                                     receiveDirectory: receiveDir)

        let receiveTask = Task {
            for await event in await inbound.events() {
                if case .offerReceived = event { await inbound.respond(accept: false) }
            }
        }

        let sendEvents = try await withTimeout(60) { await sendTask.value }
        _ = try await withTimeout(60) { await receiveTask.value }

        XCTAssertFalse(sendEvents.contains("finished"),
                       "a declined transfer must not be reported as sent: \(sendEvents)")
        XCTAssertTrue(sendEvents.contains { $0.hasPrefix("failed") },
                      "expected a failure; got \(sendEvents)")
    }
}
