import XCTest
import Network
@testable import SWIFTApp

@MainActor
final class ClipboardTests: XCTestCase {

    func testTextJSONBecomesPasteboardText() throws {
        let body = Data(#"{"kind":"text","text":"hello from the phone","html":"<b>hello</b>","source":"Redmi Note 14"}"#.utf8)
        let payload = try ClipboardDecode.parse(headers: ["content-type": "application/json"], body: body)
        let board = NSPasteboard(name: NSPasteboard.Name("SWIFTClipboardTests.text"))
        let summary = try ClipboardPasteboard.apply(payload, to: board)
        XCTAssertEqual(board.string(forType: .string), "hello from the phone")
        XCTAssertNil(board.string(forType: .html))
        XCTAssertTrue(summary.contains("Redmi Note 14"))
    }

    func testImageFileRoundTripsOntoAPrivatePasteboard() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let encoded = png.base64EncodedString()
        let json = #"{"kind":"image","name":"../shot.png","mime":"image/png","data":"\#(encoded)","source":"Pixel"}"#
        let payload = try ClipboardDecode.parse(headers: ["content-type": "application/json"], body: Data(json.utf8))
        XCTAssertEqual(payload.files.first?.name, "shot.png")
        let board = NSPasteboard(name: NSPasteboard.Name("SWIFTClipboardTests.image"))
        _ = try ClipboardPasteboard.apply(payload, to: board)
        XCTAssertNotNil(NSImage(data: png))
        XCTAssertFalse(board.pasteboardItems?.isEmpty ?? true)
    }

    func testRejectsAPathAsAFileName() {
        XCTAssertEqual(ClipboardDecode.sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(ClipboardDecode.sanitizeFileName(""), "clipboard")
        XCTAssertEqual(ClipboardDecode.sanitizeFileName(".."), "clipboard")
    }

    func testRejectsOversizedBodies() {
        let body = Data(count: ClipboardDecode.maxBytes + 1)
        XCTAssertThrowsError(try ClipboardDecode.parse(headers: [:], body: body)) { error in
            XCTAssertEqual(error as? ClipboardDecodeError, .tooLarge)
        }
    }

    func testPrivateLANCheck() {
        XCTAssertTrue(ClipboardServer.isPrivateIPv4(IPv4Address("10.0.0.8")!))
        XCTAssertTrue(ClipboardServer.isPrivateIPv4(IPv4Address("192.168.1.20")!))
        XCTAssertTrue(ClipboardServer.isPrivateIPv4(IPv4Address("172.16.4.1")!))
        XCTAssertTrue(ClipboardServer.isPrivateIPv4(IPv4Address("127.0.0.1")!))
        XCTAssertFalse(ClipboardServer.isPrivateIPv4(IPv4Address("8.8.8.8")!))
        XCTAssertFalse(ClipboardServer.isPrivateIPv4(IPv4Address("172.32.0.1")!))
        XCTAssertTrue(ClipboardServer.isPrivateLAN(.hostPort(host: .ipv4(.loopback), port: 47822)))
        XCTAssertFalse(ClipboardServer.isPrivateLAN(
            .service(name: "phone", type: "_swift._tcp", domain: "local", interface: nil)))
    }
}
