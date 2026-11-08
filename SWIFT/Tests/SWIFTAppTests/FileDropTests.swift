import XCTest
import UniformTypeIdentifiers
@testable import SWIFTApp

/// A provider that delivers its completion on a concurrent global queue, the way
/// real XPC-backed drag providers do.
///
/// This matters: providers built locally with `NSItemProvider(contentsOf:)`
/// complete serially on the calling thread, so they cannot reproduce the race
/// at all — the old unsynchronized version passes cleanly against them even
/// under TSan. Only a genuinely concurrent provider exercises the fan-out.
private final class ConcurrentFileProvider: NSItemProvider {
    let url: URL
    /// Released together so completions collide instead of trickling in.
    let gate: DispatchSemaphore

    init(url: URL, gate: DispatchSemaphore) {
        self.url = url
        self.gate = gate
        super.init()
    }

    override func loadObject(
        ofClass aClass: NSItemProviderReading.Type,
        completionHandler: @escaping (NSItemProviderReading?, (any Error)?) -> Void
    ) -> Progress {
        let url = self.url, gate = self.gate
        DispatchQueue.global(qos: .userInitiated).async {
            gate.wait()                  // hold every worker at the start line…
            gate.signal()                // …then let them all through at once
            completionHandler(url as NSURL, nil)
        }
        return Progress()
    }
}

/// `loadDroppedFileURLs` fans out across concurrent `NSItemProvider`
/// completions. Run these under the thread sanitizer to cover the race:
/// `swift test --sanitize=thread --filter FileDropTests`
final class FileDropTests: XCTestCase {

    private func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func makeFiles(_ count: Int) throws -> (dir: URL, urls: [URL]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swift-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = try (0..<count).map { i -> URL in
            let u = dir.appendingPathComponent(String(format: "file-%03d.txt", i))
            try Data("x".utf8).write(to: u)
            return u
        }
        return (dir, urls)
    }

    func testResolvesEveryDroppedFile() throws {
        let (dir, urls) = try makeFiles(40)
        defer { try? FileManager.default.removeItem(at: dir) }

        let done = expectation(description: "resolved")
        var resolved: [URL] = []
        loadDroppedFileURLs(urls.map(provider(for:))) { resolved = $0; done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(resolved.count, urls.count, "dropped files were lost")
        XCTAssertEqual(Set(resolved.map(\.lastPathComponent)),
                       Set(urls.map(\.lastPathComponent)))
    }

    /// Slot indexing (rather than racing appends) also fixed ordering, so the
    /// list the user sees matches what they dropped.
    func testPreservesDropOrder() throws {
        let (dir, urls) = try makeFiles(25)
        defer { try? FileManager.default.removeItem(at: dir) }

        let done = expectation(description: "resolved")
        var resolved: [URL] = []
        loadDroppedFileURLs(urls.map(provider(for:))) { resolved = $0; done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(resolved.map(\.lastPathComponent), urls.map(\.lastPathComponent))
    }

    func testEmptyDropCompletesWithNoURLs() {
        let done = expectation(description: "resolved")
        var resolved: [URL] = [URL(fileURLWithPath: "/placeholder")]
        loadDroppedFileURLs([]) { resolved = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testNonFileProvidersAreDroppedNotCounted() {
        let done = expectation(description: "resolved")
        var resolved: [URL] = []
        // Providers that can't produce a file URL must not leave holes or crash.
        loadDroppedFileURLs([NSItemProvider(object: "hello" as NSString)]) {
            resolved = $0; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: The actual race

    /// Providers whose completions land simultaneously on many threads. Against
    /// the old unsynchronized `urls.append(…)` this loses entries (and trips
    /// TSan); it must be exact every round.
    func testTrulyConcurrentCompletionsLoseNothing() throws {
        let (dir, urls) = try makeFiles(64)
        defer { try? FileManager.default.removeItem(at: dir) }

        for round in 0..<25 {
            let gate = DispatchSemaphore(value: 0)
            let providers = urls.map { ConcurrentFileProvider(url: $0, gate: gate) }
            let done = expectation(description: "round \(round)")
            var resolved: [URL] = []
            loadDroppedFileURLs(providers) { resolved = $0; done.fulfill() }
            gate.signal()   // open the gate; all completions fire together
            wait(for: [done], timeout: 15)

            XCTAssertEqual(resolved.count, urls.count,
                           "round \(round): expected \(urls.count), got \(resolved.count)")
            XCTAssertEqual(resolved.map(\.lastPathComponent), urls.map(\.lastPathComponent),
                           "round \(round): order or contents diverged")
        }
    }
}
