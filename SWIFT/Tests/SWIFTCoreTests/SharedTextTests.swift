import XCTest
@testable import SWIFTCore

/// Receiving a shared link or snippet of text.
///
/// This used to accept the offer and then discard the payload — the sender was
/// told it worked, the transfer was reported as finished, and nothing appeared
/// on disk. Silent success is the worst possible failure, so these pin the
/// behaviour end to end at the layer where it broke.
final class SharedTextTests: XCTestCase {

    private var receiveDir: URL!

    override func setUpWithError() throws {
        receiveDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: receiveDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: receiveDir)
    }

    /// Introduction frames for text carry the payload id we must later match.
    func testTextIntroductionRoundTripsItsPayloadID() throws {
        var meta = SharingTextMetadata()
        meta.textTitle = "example.com"
        meta.type = .url
        meta.payloadID = 987654321
        meta.size = 19

        var introduction = IntroductionFrame()
        introduction.textMetadata = [meta]

        let decoded = try SharingFrame(serialized: SharingFrame.introduction(introduction).serialized())
        let text = try XCTUnwrap(decoded.v1?.introduction?.textMetadata.first)
        XCTAssertEqual(text.payloadID, 987654321)
        XCTAssertEqual(text.type, .url)
        XCTAssertEqual(text.textTitle, "example.com")
    }

    // MARK: Writing

    /// `saveSharedText` is exercised through a session so the real path runs.
    private func save(_ contents: String, title: String, isLink: Bool) throws -> URL {
        let session = InboundSession(
            connection: .init(host: .ipv4(.loopback), port: 9, using: .tcp),
            id: "t", receiveDirectory: receiveDir)
        return try session.saveSharedTextForTesting(
            Data(contents.utf8), title: title, isLink: isLink)
    }

    func testLinkIsSavedAsAClickableBookmark() throws {
        let url = try save("https://example.com/page", title: "example.com", isLink: true)

        XCTAssertEqual(url.pathExtension, "webloc")
        let plist = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), format: nil) as? [String: String]
        XCTAssertEqual(plist?["URL"], "https://example.com/page")
    }

    func testPlainTextIsSavedAsTxt() throws {
        let url = try save("just some words", title: "note", isLink: false)
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "just some words")
    }

    /// A "link" that isn't one must not produce a broken bookmark.
    func testMalformedLinkFallsBackToText() throws {
        let url = try save("not a url at all", title: "hmm", isLink: true)
        XCTAssertEqual(url.pathExtension, "txt")
    }

    /// The title is remote-supplied, so it goes through the same sanitiser as a
    /// file name and must never escape the receive folder.
    func testHostileTitleIsConfined() throws {
        let base = receiveDir.resolvingSymlinksInPath()
        for title in ["../../escape", "/etc/passwd", "..", "", "a/b"] {
            let url = try save("x", title: title, isLink: false)
            XCTAssertEqual(url.deletingLastPathComponent().resolvingSymlinksInPath().path,
                           base.path, "title \(title.debugDescription) escaped to \(url.path)")
        }
    }

    func testInvalidUTF8IsRejected() {
        let session = InboundSession(
            connection: .init(host: .ipv4(.loopback), port: 9, using: .tcp),
            id: "t", receiveDirectory: receiveDir)
        XCTAssertThrowsError(try session.saveSharedTextForTesting(
            Data([0xFF, 0xFE]), title: "bad", isLink: false))
    }

    func testCollidingTitlesDoNotOverwrite() throws {
        let first = try save("one", title: "note", isLink: false)
        let second = try save("two", title: "note", isLink: false)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
    }
}
