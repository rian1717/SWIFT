import XCTest
import Network
@testable import SWIFTApp

/// The hand-rolled parser that reads bytes off the control socket. It must
/// return nil (keep reading) for incomplete input and never over-read.
final class HTTPRequestTests: XCTestCase {

    private func req(_ s: String) -> HTTPRequest? { HTTPRequest(Data(s.utf8)) }

    func testParsesASimpleGET() throws {
        let r = try XCTUnwrap(req("GET /devices HTTP/1.1\r\nHost: 127.0.0.1:47821\r\n\r\n"))
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/devices")
        XCTAssertEqual(r.headers["host"], "127.0.0.1:47821")
        XCTAssertTrue(r.body.isEmpty)
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let r = try XCTUnwrap(req("GET /health HTTP/1.1\r\nAUTHORIZATION: Bearer abc\r\n\r\n"))
        XCTAssertEqual(r.headers["authorization"], "Bearer abc")
    }

    func testQueryStringIsStrippedFromPath() throws {
        let r = try XCTUnwrap(req("GET /devices?all=1 HTTP/1.1\r\nHost: x\r\n\r\n"))
        XCTAssertEqual(r.path, "/devices")
    }

    func testIncompleteInputReturnsNil() {
        XCTAssertNil(req(""))
        XCTAssertNil(req("GET /devices HTTP/1.1\r\n"))
        XCTAssertNil(req("GET /devices HTTP/1.1\r\nHost: x\r\n"))   // no blank line yet
    }

    func testPartialBodyReturnsNilUntilComplete() throws {
        let head = "POST /send HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        XCTAssertNil(req(head + "12345"), "accepted a half-delivered body")
        let full = try XCTUnwrap(req(head + "1234567890"))
        XCTAssertEqual(full.body, Data("1234567890".utf8))
    }

    /// A body longer than Content-Length must be truncated, not leak the tail of
    /// a following pipelined request into this one.
    func testBodyIsTruncatedToContentLength() throws {
        let r = try XCTUnwrap(req("POST /send HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcEXTRA"))
        XCTAssertEqual(r.body, Data("abc".utf8))
    }

    func testMalformedRequestLineIsRejected() {
        XCTAssertNil(req("GARBAGE\r\n\r\n"))
        XCTAssertNil(req("\r\n\r\n"))
    }

    func testMissingContentLengthMeansEmptyBody() throws {
        let r = try XCTUnwrap(req("POST /send HTTP/1.1\r\nHost: x\r\n\r\n"))
        XCTAssertTrue(r.body.isEmpty)
    }

    func testNonNumericContentLengthIsTreatedAsZero() throws {
        let r = try XCTUnwrap(req("POST /send HTTP/1.1\r\nContent-Length: abc\r\n\r\nxyz"))
        XCTAssertTrue(r.body.isEmpty)
    }

    func testHeaderLinesWithoutAColonAreSkipped() throws {
        let r = try XCTUnwrap(req("GET /health HTTP/1.1\r\nnonsense\r\nHost: x\r\n\r\n"))
        XCTAssertEqual(r.headers["host"], "x")
    }

    func testRandomBytesNeverCrashTheParser() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let count = Int.random(in: 0...512, using: &rng)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = HTTPRequest(Data(bytes))
        }
    }

    /// Fragments of a valid request must never parse early — this is the
    /// property the read loop depends on for correctness.
    func testEveryPrefixOfAValidRequestIsIncomplete() {
        let full = "POST /send HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello"
        let bytes = Data(full.utf8)
        for cut in 0..<bytes.count {
            XCTAssertNil(HTTPRequest(bytes.prefix(cut)),
                         "prefix of length \(cut) parsed as a complete request")
        }
        XCTAssertNotNil(HTTPRequest(bytes))
    }
}

final class ConstantTimeCompareTests: XCTestCase {
    func testMatchesOnlyForIdenticalStrings() {
        XCTAssertTrue(ControlServer.constantTimeEqual("", ""))
        XCTAssertTrue(ControlServer.constantTimeEqual("abc123", "abc123"))
        XCTAssertFalse(ControlServer.constantTimeEqual("abc123", "abc124"))
        XCTAssertFalse(ControlServer.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(ControlServer.constantTimeEqual("abcd", "abc"))
    }

    func testHandlesMultiByteScalars() {
        XCTAssertTrue(ControlServer.constantTimeEqual("tökén", "tökén"))
        XCTAssertFalse(ControlServer.constantTimeEqual("tökén", "token"))
    }
}

final class FinderReplyTests: XCTestCase {
    func testASuccessfulShareReplyIsRealJSON() throws {
        let object = ControlServer.resultObject(
            AppModel.CliSendResult(ok: true, pin: nil, error: nil))
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
    }

    func testAFailedShareReplyKeepsItsReason() throws {
        let object = ControlServer.resultObject(
            AppModel.CliSendResult(ok: false, pin: nil, error: "no_readable_files"))
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "no_readable_files")
    }

    private struct Reply: Decodable {
        let ok: Bool
        let error: String?
    }
}

final class LoopbackGuardTests: XCTestCase {
    func testAcceptsLoopbackAddresses() {
        XCTAssertTrue(ControlServer.isLoopback(
            .hostPort(host: .ipv4(.loopback), port: 47821)))
        XCTAssertTrue(ControlServer.isLoopback(
            .hostPort(host: .ipv6(.loopback), port: 47821)))
        XCTAssertTrue(ControlServer.isLoopback(
            .hostPort(host: .name("localhost", nil), port: 47821)))
    }

    func testRejectsLANAndServiceEndpoints() {
        XCTAssertFalse(ControlServer.isLoopback(
            .hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 47821)))
        XCTAssertFalse(ControlServer.isLoopback(
            .service(name: "phone", type: "_http._tcp", domain: "local", interface: nil)))
    }
}
