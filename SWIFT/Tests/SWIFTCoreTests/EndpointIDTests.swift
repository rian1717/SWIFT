import XCTest
@testable import SWIFTCore

final class EndpointIDTests: XCTestCase {
    func testGeneratedIDIsValid() {
        for _ in 0..<50 {
            XCTAssertTrue(SWIFTEngine.isValidEndpointID(SWIFTEngine.makeEndpointID()))
        }
    }

    func testRejectsWrongLengthAndSymbols() {
        XCTAssertFalse(SWIFTEngine.isValidEndpointID(nil))
        XCTAssertFalse(SWIFTEngine.isValidEndpointID(Array("abc".utf8)))
        XCTAssertFalse(SWIFTEngine.isValidEndpointID(Array("abcde".utf8)))
        XCTAssertFalse(SWIFTEngine.isValidEndpointID(Array("ab-d".utf8)))
    }

    @MainActor
    func testEngineKeepsAValidSuppliedID() {
        let id = Array("Ab12".utf8)
        let engine = SWIFTEngine(deviceName: "Mac", receiveDirectory: FileManager.default.temporaryDirectory, endpointID: id)
        XCTAssertEqual(engine.advertisedEndpointID, id)
        let other = SWIFTEngine(deviceName: "Mac", receiveDirectory: FileManager.default.temporaryDirectory, endpointID: Array("!!".utf8))
        XCTAssertTrue(SWIFTEngine.isValidEndpointID(other.advertisedEndpointID))
    }
}
