import XCTest
import Network
import CryptoKit
@testable import SWIFTCore

/// Integration coverage for advertising. Deliberately not a unit test: it opens
/// a real `NWListener` and publishes a real Bonjour service, because the bugs
/// worth catching here only exist at that seam.
///
/// It exists because a plausible-looking refactor once broke advertising in a
/// way no unit test could see — `NetService` delivers its delegate callbacks on
/// the run loop it was scheduled on, so publishing from a bare dispatch queue
/// left didPublish/didNotPublish permanently unfired and the UI showed "not
/// visible" forever while the Mac was, in fact, visible.
@MainActor
final class AdvertisingIntegrationTests: XCTestCase {

    private var advertiser: ServiceAdvertiser?

    override func tearDown() async throws {
        advertiser?.stop()
        advertiser = nil
        try await super.tearDown()
    }

    private func makeAdvertiser() -> ServiceAdvertiser {
        let endpointID: [UInt8] = Array("ab12".utf8)
        let a = ServiceAdvertiser(deviceName: "SWIFT Test \(UUID().uuidString.prefix(4))",
                                  endpointID: endpointID)
        advertiser = a
        return a
    }

    /// Visibility must be reported only once we are genuinely published.
    func testStartReportsVisibleOnlyAfterPublishing() async throws {
        let advertiser = makeAdvertiser()
        let published = expectation(description: "published")
        var transitions: [Bool] = []

        advertiser.onVisibilityChange = { visible in
            transitions.append(visible)
            if visible { published.fulfill() }
        }
        advertiser.start()
        await fulfillment(of: [published], timeout: 30)

        XCTAssertEqual(transitions.last, true)
    }

    /// The off→on race: NWListener.cancel() is asynchronous, so going invisible
    /// and immediately visible again must still end up advertising.
    func testRapidStopThenStartReAdvertises() async throws {
        let advertiser = makeAdvertiser()

        let first = expectation(description: "first publish")
        advertiser.onVisibilityChange = { if $0 { first.fulfill() } }
        advertiser.start()
        await fulfillment(of: [first], timeout: 30)

        advertiser.stop()

        let second = expectation(description: "republish")
        advertiser.onVisibilityChange = { if $0 { second.fulfill() } }
        advertiser.start()   // immediately, while cancel() is still in flight
        await fulfillment(of: [second], timeout: 30)
    }

    /// Repeated `start()` must not try to start an already-started listener.
    func testRepeatedStartIsIdempotent() async throws {
        let advertiser = makeAdvertiser()
        let published = expectation(description: "published")
        var visibleReports = 0

        advertiser.onVisibilityChange = { visible in
            if visible {
                visibleReports += 1
                if visibleReports == 1 { published.fulfill() }
            }
        }
        advertiser.start()
        advertiser.start()
        advertiser.start()
        await fulfillment(of: [published], timeout: 30)

        XCTAssertEqual(visibleReports, 1, "visibility should be reported once, not per call")
    }
}

final class QRCodeSessionTests: XCTestCase {

    func testURLIsTheFormAndroidRoutesToSWIFT() {
        let session = QRCodeSession()
        XCTAssertTrue(session.url.hasPrefix("https://quickshare.google/qrcode#key="),
                      "got \(session.url)")
    }

    /// The key blob carries the fixed prefix plus 32 bytes of X coordinate.
    func testKeyBlobShape() {
        let session = QRCodeSession()
        XCTAssertEqual(session.keyData.prefix(3), Data([0, 0, 2]))
        XCTAssertEqual(session.keyData.count, 35)
        XCTAssertEqual(session.advertisingToken.count, 16)
    }

    func testEachSessionIsDistinct() {
        let tokens = (0..<20).map { _ in QRCodeSession().advertisingToken }
        XCTAssertEqual(Set(tokens).count, tokens.count, "advertising tokens repeated")
    }

    func testMatchesOnlyItsOwnToken() {
        let session = QRCodeSession()
        let other = QRCodeSession()
        XCTAssertTrue(session.matches(advertisedQRData: session.advertisingToken))
        XCTAssertFalse(session.matches(advertisedQRData: other.advertisingToken))
        XCTAssertFalse(session.matches(advertisedQRData: Data()))
        XCTAssertFalse(session.matches(advertisedQRData: Data(repeating: 0, count: 16)))
    }

    /// Garbage must decrypt to nil, not crash.
    func testGarbageNameDataIsRejected() {
        let session = QRCodeSession()
        XCTAssertNil(session.decryptDeviceName(from: Data()))
        XCTAssertNil(session.decryptDeviceName(from: Data(repeating: 0xAB, count: 64)))

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let count = Int.random(in: 0...80, using: &rng)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = session.decryptDeviceName(from: data)
        }
    }

    /// Signatures are raw r‖s, which is what the wire expects.
    func testHandshakeSignatureIsRawRS() throws {
        let session = QRCodeSession()
        let authKey = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
        let signature = try XCTUnwrap(session.handshakeSignature(authKey: authKey))
        XCTAssertEqual(signature.count, 64, "expected raw r‖s, not DER")
    }
}
