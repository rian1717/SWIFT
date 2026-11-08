import XCTest
@testable import SWIFTCore

/// The only thing standing between a remote-supplied name and the filesystem.
final class ReceivedFileNameTests: XCTestCase {

    private func sanitize(_ s: String) -> String { ReceivedFileName.sanitize(s) }

    func testOrdinaryNamesSurvive() {
        XCTAssertEqual(sanitize("photo.jpg"), "photo.jpg")
        XCTAssertEqual(sanitize("Report 2026 (final).pdf"), "Report 2026 (final).pdf")
        XCTAssertEqual(sanitize("naïve-café-🎉.png"), "naïve-café-🎉.png")
    }

    func testTraversalIsStripped() {
        XCTAssertEqual(sanitize("../evil.sh"), "evil.sh")
        XCTAssertEqual(sanitize("../../../../etc/passwd"), "passwd")
        XCTAssertEqual(sanitize("/etc/passwd"), "passwd")
        XCTAssertEqual(sanitize("a/b/c/d.txt"), "d.txt")
    }

    func testBareTraversalTokensBecomeTheFallback() {
        for input in ["..", ".", "", "/", "../..", "foo/..", "\u{0}"] {
            XCTAssertEqual(sanitize(input), ReceivedFileName.fallbackName, "input \(input.debugDescription)")
        }
    }

    func testSeparatorsAndNulAreNeutralised() {
        XCTAssertFalse(sanitize("evil\u{0}.jpg").contains("\u{0}"))
        XCTAssertFalse(sanitize("a\\b.txt").contains("\\"))
        XCTAssertFalse(sanitize("a/b.txt").contains("/"))
    }

    func testTrailingDotsAndSpacesAreTrimmed() {
        XCTAssertEqual(sanitize("file.txt."), "file.txt")
        XCTAssertEqual(sanitize("file.txt   "), "file.txt")
    }

    func testOverlongNamesAreTruncatedButKeepTheirExtension() {
        let long = String(repeating: "a", count: 500) + ".jpg"
        let out = sanitize(long)
        XCTAssertLessThanOrEqual(out.utf8.count, ReceivedFileName.maxNameLength)
        XCTAssertTrue(out.hasSuffix(".jpg"), "extension lost: \(out)")
    }

    func testResultIsAlwaysASingleComponent() {
        for name in ["a/b", "/a/b/c", "../x", "x/", "//a//b//", "..\\..\\win"] {
            let out = sanitize(name)
            XCTAssertFalse(out.contains("/"), "\(name) -> \(out)")
            XCTAssertFalse(out.contains("\\"), "\(name) -> \(out)")
            XCTAssertFalse(out.isEmpty)
        }
    }

    // MARK: Destination confinement

    func testDestinationsNeverEscapeTheReceiveDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swift-confine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.resolvingSymlinksInPath()

        let hostile = [
            "../escape", "../../escape", "/etc/passwd", "..", ".", "", "/",
            "....//....//escape", "a/../../b", "~/.ssh/authorized_keys",
            "..;/etc", "%2e%2e%2fescape", "\u{0}../x", "con", "..\\..\\windows",
            String(repeating: "../", count: 64) + "deep",
            String(repeating: "A", count: 4096),
        ]

        for name in hostile {
            let dest = try ReceivedFileName.uniqueDestination(for: sanitize(name), in: base)
            XCTAssertEqual(dest.deletingLastPathComponent().resolvingSymlinksInPath().path,
                           base.path, "\(name.debugDescription) escaped to \(dest.path)")
        }
    }

    func testCollisionsGetDisambiguated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("swift-collide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try ReceivedFileName.uniqueDestination(for: "photo.jpg", in: root)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = try ReceivedFileName.uniqueDestination(for: "photo.jpg", in: root)

        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertEqual(second.lastPathComponent, "photo (1).jpg")
        XCTAssertNotEqual(first, second)
    }
}

final class EndpointInfoTests: XCTestCase {

    func testRoundTrip() throws {
        let original = EndpointInfo(name: "Test Mac", deviceType: .computer)
        let parsed = try EndpointInfo(serialized: original.serialized())
        XCTAssertEqual(parsed.name, "Test Mac")
        XCTAssertEqual(parsed.deviceType, .computer)
    }

    func testRoundTripAcrossDeviceTypes() throws {
        for type in [SWIFTDevice.DeviceType.unknown, .phone, .tablet, .computer] {
            let parsed = try EndpointInfo(serialized: EndpointInfo(name: "X", deviceType: type).serialized())
            XCTAssertEqual(parsed.deviceType, type)
        }
    }

    func testTruncatedRecordsAreRejected() {
        for length in 0..<18 {
            XCTAssertThrowsError(try EndpointInfo(serialized: Data(repeating: 0, count: length)),
                                 "accepted a \(length)-byte record")
        }
    }

    func testNameLengthOverrunIsRejected() {
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[17] = 200                      // claims 200 bytes...
        bytes.append(contentsOf: [1, 2, 3])  // ...but 3 follow
        XCTAssertThrowsError(try EndpointInfo(serialized: Data(bytes)))
    }

    func testInvalidUTF8NameIsRejected() {
        var bytes: [UInt8] = [0x06]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        bytes.append(2)
        bytes.append(contentsOf: [0xFF, 0xFE])
        XCTAssertThrowsError(try EndpointInfo(serialized: Data(bytes)))
    }

    /// The "no name" flag must yield a nil name, not a crash.
    func testNamelessRecordParses() throws {
        var bytes: [UInt8] = [0x10]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 17))
        let info = try EndpointInfo(serialized: Data(bytes))
        XCTAssertNil(info.name)
    }

    /// Samsung Quick Share, with the receive screen open, advertises exactly
    /// this: flag byte 0x32 (phone, name hidden) and 16 id bytes.
    func testAdvertisedAddressWinsOverAChangingHostname() {
        let chosen = QuickShareAddress.choose(
            advertisedIPv4: "192.168.18.127", resolvedIPv4: "10.0.0.4", port: 53601)
        XCTAssertEqual(chosen, QuickShareAddress(host: "192.168.18.127", port: 53601))
    }

    func testResolvedAddressIsUsedWhenTheAdvertisementHasNone() {
        let chosen = QuickShareAddress.choose(
            advertisedIPv4: nil, resolvedIPv4: "10.1.2.3", port: 47823)
        XCTAssertEqual(chosen?.host, "10.1.2.3")
        XCTAssertEqual(chosen?.port, 47823)
    }

    func testVpnAddressIsNotTheSameNetwork() {
        let locals = ["192.168.18.20"]
        XCTAssertTrue(QuickShareAddress.sharesSubnet("192.168.18.127", locals: locals))
        XCTAssertFalse(QuickShareAddress.sharesSubnet("10.8.0.4", locals: locals))
        XCTAssertFalse(QuickShareAddress.sharesSubnet("8.8.8.8", locals: locals))
    }

    func testPublicAddressIsNotDialed() {
        XCTAssertNil(QuickShareAddress.choose(
            advertisedIPv4: "8.8.8.8", resolvedIPv4: "1.1.1.1", port: 53601))
        XCTAssertNil(QuickShareAddress.choose(
            advertisedIPv4: "192.168.18.127", resolvedIPv4: nil, port: 0))
    }

    func testSamsungReceiveRecordIsAPhone() throws {
        let bytes: [UInt8] = [
            0x32, 0xdd, 0xbd, 0x5e, 0x81, 0xd1, 0x61, 0x94,
            0x45, 0xbe, 0x70, 0x37, 0x9f, 0xb9, 0x01, 0x6a, 0x9b,
        ]
        let info = try EndpointInfo(serialized: Data(bytes))
        XCTAssertNil(info.name)
        XCTAssertEqual(info.deviceType, .phone)
        XCTAssertNil(info.qrCodeData)
    }

    /// A malformed TLV tail must terminate rather than spin.
    func testMalformedTLVTailTerminates() throws {
        var bytes = [UInt8](EndpointInfo(name: "x", deviceType: .phone).serialized())
        for _ in 0..<64 { bytes.append(contentsOf: [1, 0xFF]) }   // always overruns
        let done = expectation(description: "returned")
        DispatchQueue.global().async {
            _ = try? EndpointInfo(serialized: Data(bytes))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testOverlongNameIsTruncatedToAValidRecord() throws {
        let long = String(repeating: "é", count: 400)   // 800 UTF-8 bytes
        let parsed = try EndpointInfo(serialized: EndpointInfo(name: long, deviceType: .phone).serialized())
        let name = try XCTUnwrap(parsed.name)
        XCTAssertLessThanOrEqual(name.utf8.count, EndpointInfo.maxNameBytes)
        XCTAssertTrue(long.hasPrefix(name), "truncation broke the string")
    }

    func testRandomInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let count = Int.random(in: 0...300, using: &rng)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = try? EndpointInfo(serialized: Data(bytes))
        }
    }
}
