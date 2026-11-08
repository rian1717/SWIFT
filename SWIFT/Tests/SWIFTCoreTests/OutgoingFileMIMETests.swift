import XCTest
@testable import SWIFTCore

final class OutgoingFileMIMETests: XCTestCase {

    func testAPKIsAdvertisedAsAnInstallablePackage() {
        XCTAssertEqual(
            OutgoingFile.advertisedMIMEType(sniffed: nil, pathExtension: "apk"),
            "application/vnd.android.package-archive")
        XCTAssertEqual(
            OutgoingFile.advertisedMIMEType(sniffed: "application/zip", pathExtension: "APK"),
            "application/vnd.android.package-archive")
    }

    func testKnownTypesKeepTheSniffedMIME() {
        XCTAssertEqual(
            OutgoingFile.advertisedMIMEType(sniffed: "image/jpeg", pathExtension: "jpg"),
            "image/jpeg")
        XCTAssertEqual(
            OutgoingFile.advertisedMIMEType(sniffed: nil, pathExtension: "bin"),
            "application/octet-stream")
    }

    func testReadingAnAPKKeepsTheInstallableType() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-debug-\(UUID().uuidString).apk")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try OutgoingFile.from(url: url)

        XCTAssertTrue(file.name.hasSuffix(".apk"))
        XCTAssertEqual(file.mimeType, "application/vnd.android.package-archive")
    }
}
