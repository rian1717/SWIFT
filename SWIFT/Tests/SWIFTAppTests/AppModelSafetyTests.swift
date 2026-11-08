import XCTest
@testable import SWIFTApp

/// A service double that records what the model asked the engine to do.
@MainActor
final class SpyService: SWIFTService {
    weak var delegate: SWIFTServiceDelegate?

    private(set) var consentResponses: [(id: String, accept: Bool)] = []
    private(set) var sentFiles: [(files: [FileItem], device: RemoteDevice)] = []
    private(set) var advertising = false

    func startAdvertising(deviceName: String) { advertising = true }
    func stopAdvertising() { advertising = false }
    func respondToIncoming(id: String, accept: Bool) { consentResponses.append((id, accept)) }
    func setReceiveDirectory(_ url: URL) {}
    func startDiscovery() {}
    func stopDiscovery() {}
    func sendFiles(_ files: [FileItem], to device: RemoteDevice) { sentFiles.append((files, device)) }
    func cancelTransfer(id: String) {}
    func prepareQRCode() -> String? { "qr" }
    func cancelQRCode() {}
    func finishAddPhone(_ device: RemoteDevice) {}
}

@MainActor
final class AppModelSafetyTests: XCTestCase {

    private var spy: SpyService!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        // AppModel persists to UserDefaults.standard; start from a clean slate so
        // tests don't inherit each other's (or the real app's) state.
        for key in ["knownDevices", "knownDeviceNames", "trustedDeviceNames", "controlAPIEnabled",
                    "startVisible", "downloadDirectoryPath", "appearance", "pairedPhones",
                    "removedPhones", "deviceNicknames"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Production defaults to visible. These tests start from an explicit off.
        UserDefaults.standard.set(false, forKey: "startVisible")
        spy = SpyService()
        model = AppModel(service: spy)
    }

    override func tearDown() async throws {
        for key in ["knownDevices", "knownDeviceNames", "trustedDeviceNames", "controlAPIEnabled"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try await super.tearDown()
    }

    private func request(from name: String, id: String = "t1") -> IncomingRequest {
        IncomingRequest(id: id,
                        device: RemoteDevice(id: "d-\(name)", name: name, type: .phone),
                        fileNames: ["photo.jpg"], totalBytes: 1234, pin: "1234")
    }

    // MARK: Every transfer requires explicit consent

    /// Being known is not consent. A sender accepted before must still prompt.
    func testAPhoneIsNotListedTwiceAfterItsNameGrows() {
        XCTAssertEqual(AppModel.withoutDuplicates(["Rai's Pixel 8", "rai's pixel 8", "A32"]), ["Rai's Pixel 8", "A32"])
    }

    func testKnownButNotAutoAcceptedStillPrompts() {
        model.remember("Pixel 8 Pro")
        XCTAssertTrue(model.isKnown("Pixel 8 Pro"))
        XCTAssertFalse(model.autoAccepts("Pixel 8 Pro"))

        model.serviceDidReceiveIncomingRequest(request(from: "Pixel 8 Pro"))

        XCTAssertEqual(model.incomingRequest?.device.name, "Pixel 8 Pro")
        XCTAssertTrue(spy.consentResponses.isEmpty,
                      "nothing may be accepted before the user answers")
        XCTAssertTrue(model.transfers.isEmpty)
    }

    /// Legacy callers cannot turn a self-reported name into an identity.
    func testLegacyAutoAcceptRequestStillPrompts() {
        model.remember("Pixel 8 Pro", autoAccept: true)

        model.serviceDidReceiveIncomingRequest(request(from: "Pixel 8 Pro"))

        XCTAssertNotNil(model.incomingRequest)
        XCTAssertFalse(model.autoAccepts("Pixel 8 Pro"))
        XCTAssertTrue(spy.consentResponses.isEmpty)
        XCTAssertTrue(model.transfers.isEmpty)
    }

    func testLegacyAutoAcceptDoesNotAffectOtherSenders() {
        model.remember("Pixel 8 Pro", autoAccept: true)

        model.serviceDidReceiveIncomingRequest(request(from: "Someone Else"))

        XCTAssertNotNil(model.incomingRequest)
        XCTAssertTrue(spy.consentResponses.isEmpty)
    }

    func testUnknownDevicePrompts() {
        model.serviceDidReceiveIncomingRequest(request(from: "Stranger"))
        XCTAssertNotNil(model.incomingRequest)
        XCTAssertTrue(spy.consentResponses.isEmpty)
    }

    func testTogglingAutoAcceptOffRestoresThePrompt() {
        model.remember("Tablet", autoAccept: true)
        model.setAutoAccept(false, for: "Tablet")

        model.serviceDidReceiveIncomingRequest(request(from: "Tablet"))
        XCTAssertNotNil(model.incomingRequest)
    }

    /// An upgrade must never silently switch auto-accept on: the older lists
    /// carried no per-device choice, so the safe reading is "ask".
    func testMigratedListsArriveWithAutoAcceptOff() {
        UserDefaults.standard.set(["Old Phone"], forKey: "trustedDeviceNames")
        UserDefaults.standard.set(["Older Phone"], forKey: "knownDeviceNames")
        let fresh = AppModel(service: SpyService())

        XCTAssertTrue(fresh.isKnown("Old Phone"))
        XCTAssertTrue(fresh.isKnown("Older Phone"))
        XCTAssertFalse(fresh.autoAccepts("Old Phone"), "migration must not enable auto-accept")
        XCTAssertFalse(fresh.autoAccepts("Older Phone"), "migration must not enable auto-accept")

        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "trustedDeviceNames"),
                     "legacy key should be cleared")
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "knownDeviceNames"),
                     "legacy key should be cleared")
    }

    // MARK: Consent bookkeeping

    func testAcceptingRecordsTheSender() {
        model.serviceDidReceiveIncomingRequest(request(from: "Galaxy S24"))
        model.respondToIncoming(accept: true)

        XCTAssertEqual(spy.consentResponses.map(\.accept), [true])
        XCTAssertTrue(model.isKnown("Galaxy S24"))
        XCTAssertFalse(model.autoAccepts("Galaxy S24"),
                       "a plain accept must not enable auto-accept")
        XCTAssertEqual(model.transfers.count, 1)
        XCTAssertNil(model.incomingRequest)
    }

    /// A stale client asking for "always" cannot bypass future consent.
    func testAcceptingWithAlwaysStillRequiresNextConsent() {
        model.serviceDidReceiveIncomingRequest(request(from: "Galaxy S24"))
        model.respondToIncoming(accept: true, alwaysAccept: true)

        XCTAssertFalse(model.autoAccepts("Galaxy S24"))

        model.serviceDidReceiveIncomingRequest(request(from: "Galaxy S24", id: "t2"))
        XCTAssertNotNil(model.incomingRequest)
        XCTAssertEqual(spy.consentResponses.map(\.accept), [true])
    }

    func testDecliningDoesNotRecordOrStartATransfer() {
        model.serviceDidReceiveIncomingRequest(request(from: "Galaxy S24"))
        model.respondToIncoming(accept: false)

        XCTAssertEqual(spy.consentResponses.map(\.accept), [false])
        XCTAssertFalse(model.isKnown("Galaxy S24"))
        XCTAssertTrue(model.transfers.isEmpty)
        XCTAssertNil(model.incomingRequest)
    }

    func testForgettingRemovesTheSender() {
        model.remember("Tablet", autoAccept: true)
        model.forget("Tablet")
        XCTAssertFalse(model.isKnown("Tablet"))
        XCTAssertFalse(model.autoAccepts("Tablet"))
    }

    func testRememberIsIdempotentAndNeverEnablesTrust() {
        model.remember("Phone", autoAccept: true)
        model.remember("Phone")
        XCTAssertEqual(model.knownDevices.filter { $0.name == "Phone" }.count, 1)
        XCTAssertFalse(model.autoAccepts("Phone"))
    }

    func testKnownDevicesPersistAcrossLaunches() {
        model.remember("Persisted", autoAccept: true)
        let fresh = AppModel(service: SpyService())
        XCTAssertTrue(fresh.isKnown("Persisted"))
        XCTAssertFalse(fresh.autoAccepts("Persisted"))
    }

    // MARK: CLI must not hijack the window's send flow

    func testCliSendIsRefusedWhileTheUserIsMidFlow() {
        let device = RemoteDevice(id: "d1", name: "Pixel", type: .phone)
        model.serviceDidDiscover(device)
        model.selectDevice(device)                       // user is staging
        model.stage(urls: [URL(fileURLWithPath: "/tmp/a.txt")])
        let staged = model.stagedFiles

        var result: AppModel.CliSendResult?
        model.cliSend(paths: ["/etc/hosts"], to: "Pixel") { result = $0 }

        XCTAssertEqual(result?.error, "busy")
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(model.stagedFiles.map(\.url), staged.map(\.url),
                       "the user's staged files must be untouched")
        XCTAssertTrue(spy.sentFiles.isEmpty)
    }

    func testQRAppearsAsSoonAsAFileIsDropped() {
        model.startQRSend()
        guard case .qrStaging = model.connection else {
            return XCTFail("the QR waits until a file is chosen")
        }

        model.stage(urls: [URL(fileURLWithPath: "/etc/hosts")])

        guard case .qrShowing = model.connection else {
            return XCTFail("dropping a file should show the QR without another tap")
        }

        let phone = RemoteDevice(id: "s22", name: "Galaxy S22", type: .phone)
        model.serviceDidMatchQRDevice(phone)
        XCTAssertEqual(spy.sentFiles.map(\.device.name), ["Galaxy S22"])
    }

    func testCliSendReportsUnknownDevice() {
        var result: AppModel.CliSendResult?
        model.cliSend(paths: ["/etc/hosts"], to: "Nope") { result = $0 }
        XCTAssertEqual(result?.error, "device_not_found")
    }

    func testCliSendRejectsUnreadablePaths() {
        let device = RemoteDevice(id: "d1", name: "Pixel", type: .phone)
        model.serviceDidDiscover(device)
        var result: AppModel.CliSendResult?
        model.cliSend(paths: ["/no/such/file/anywhere"], to: "Pixel") { result = $0 }
        XCTAssertEqual(result?.error, "no_readable_files")
    }

    // MARK: Device list ordering

    func testPairedPhoneIsMineAndNotNearby() {
        model.rememberPhone("Redmi Note 14")
        model.serviceDidDiscover(RemoteDevice(
            id: "phone", name: "Redmi Note 14", type: .phone,
            companionHost: "192.168.1.20", companionPort: 47823))
        model.serviceDidDiscover(RemoteDevice(id: "other", name: "Pixel", type: .phone))

        XCTAssertEqual(model.myDevices.map(\.name), ["Redmi Note 14"])
        XCTAssertEqual(model.nearbyDevices.map(\.name), ["Pixel"])
        XCTAssertEqual(model.availableDevices.map(\.name), ["Redmi Note 14", "Pixel"])
        XCTAssertTrue(model.offlinePhoneNames.isEmpty)
    }

    func testPairedPhoneStaysRememberedWhenTheScreenIsOff() {
        model.rememberPhone("Redmi Note 14")
        XCTAssertEqual(model.offlinePhoneNames, ["Redmi Note 14"])
        XCTAssertTrue(model.myDevices.isEmpty)
    }

    func testRemovingAPhoneMovesItToNearbyAndStaysRemoved() {
        model.rememberPhone("Redmi Note 14")
        model.serviceDidDiscover(RemoteDevice(id: "redmi", name: "Redmi Note 14", type: .phone))
        model.forgetPhone("Redmi Note 14")

        XCTAssertTrue(model.myDevices.isEmpty)
        XCTAssertEqual(model.nearbyDevices.map(\.name), ["Redmi Note 14"])
        XCTAssertTrue(model.offlinePhoneNames.isEmpty)

        model.rememberPhone("Redmi Note 14")
        XCTAssertTrue(model.isPhoneRemoved("redmi note 14"))
        XCTAssertTrue(model.myDevices.isEmpty, "a later sighting must not undo Remove")

        let fresh = AppModel(service: SpyService())
        fresh.serviceDidDiscover(RemoteDevice(id: "redmi", name: "Redmi Note 14", type: .phone))
        XCTAssertTrue(fresh.myDevices.isEmpty)
        XCTAssertEqual(fresh.nearbyDevices.map(\.name), ["Redmi Note 14"])
    }

    func testAnUnpairedPhoneStaysNearby() {
        model.serviceDidDiscover(RemoteDevice(
            id: "pixel", name: "Rai's Pixel 8", type: .phone,
            companionHost: "192.168.1.20", companionPort: 47823))

        XCTAssertTrue(model.myDevices.isEmpty)
        XCTAssertEqual(model.nearbyDevices.map(\.name), ["Rai's Pixel 8"])
    }

    func testNearbyKeepsTheAdvertisedName() {
        Preferences().rememberNickname("Pocket", seenAs: "Rai's Pixel 8")
        model.serviceDidDiscover(RemoteDevice(id: "pixel", name: "Rai's Pixel 8", type: .phone))
        model.serviceDidDiscover(RemoteDevice(id: "pixel", name: "Pixel 8", type: .phone))

        XCTAssertEqual(model.nearbyDevices.map(\.name), ["Rai's Pixel 8"])
        model.renameDevice(from: "Rai's Pixel 8", to: "Pocket")
        XCTAssertEqual(model.nearbyDevices.map(\.name), ["Rai's Pixel 8"])
    }

    func testAPairedPhoneCanBeRenamed() {
        model.acceptPairedPhone("Rai's Pixel 8")
        model.serviceDidDiscover(RemoteDevice(id: "pixel", name: "Rai's Pixel 8", type: .phone))
        model.renameDevice(from: "Rai's Pixel 8", to: "rai pixel 8")

        XCTAssertEqual(model.myDevices.map(\.name), ["rai pixel 8"])
        XCTAssertTrue(model.nearbyDevices.isEmpty)
    }

    func testPairingAgainRestoresARemovedPhone() {
        model.rememberPhone("RYZE S22")
        model.forgetPhone("RYZE S22")
        model.acceptPairedPhone("ryze s22")

        XCTAssertFalse(model.isPhoneRemoved("RYZE S22"))
        XCTAssertEqual(model.offlinePhoneNames, ["ryze s22"])
    }

    func testAvailableDevicesPutsKnownFirstAndIsStable() {
        for name in ["Zeta", "Alpha", "Mid"] {
            model.serviceDidDiscover(RemoteDevice(id: "d-\(name)", name: name, type: .phone))
        }
        model.remember("Mid")

        let order = model.availableDevices.map(\.name)
        XCTAssertEqual(order.first, "Mid", "known devices sort first")
        XCTAssertEqual(order, ["Mid", "Alpha", "Zeta"], "ties sort by name, not arbitrarily")
        XCTAssertEqual(model.availableDevices.map(\.name), order, "ordering is stable across reads")
    }

    // MARK: Visibility reflects the engine, never the request

    func testReceiveIsOnUnlessTheUserTurnedItOff() {
        UserDefaults.standard.removeObject(forKey: "startVisible")
        XCTAssertTrue(Preferences().startVisible)
    }

    /// The switch follows intent so it responds instantly; the reported status
    /// follows the engine so it never claims more than is true.
    func testIntentIsImmediateButStatusWaitsForTheEngine() {
        XCTAssertEqual(model.visibilityStatus, .off)

        model.toggleVisibility()
        XCTAssertTrue(model.wantsVisible, "the switch must move immediately")
        XCTAssertTrue(spy.advertising, "the engine was asked to advertise")
        XCTAssertFalse(model.isVisible, "nothing is published yet")
        XCTAssertEqual(model.visibilityStatus, .starting)

        model.serviceDidUpdateVisibility(isVisible: true)
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.visibilityStatus, .on)
    }

    func testTurningOffIsAlsoImmediate() {
        model.setVisible(true)
        model.serviceDidUpdateVisibility(isVisible: true)
        XCTAssertEqual(model.visibilityStatus, .on)

        model.setVisible(false)
        XCTAssertFalse(model.wantsVisible, "the switch must move immediately")
        XCTAssertFalse(spy.advertising, "the engine was asked to stop")
        // Still published until the engine confirms it tore down.
        XCTAssertEqual(model.visibilityStatus, .stopping)

        model.serviceDidUpdateVisibility(isVisible: false)
        XCTAssertEqual(model.visibilityStatus, .off)
    }

    /// Regression: a late "visible" arriving during teardown must not turn the
    /// switch back on after the user has just switched it off.
    func testLateVisibleReportDoesNotRevertTheSwitch() {
        model.setVisible(true)
        model.serviceDidUpdateVisibility(isVisible: true)

        model.setVisible(false)
        XCTAssertFalse(model.wantsVisible)

        // The engine hadn't finished tearing down and reports visible once more.
        model.serviceDidUpdateVisibility(isVisible: true)

        XCTAssertFalse(model.wantsVisible, "the switch flipped itself back on")
        XCTAssertEqual(model.visibilityStatus, .stopping)
    }

    /// Advertising dropping out on its own must show as pending again, not as on.
    func testLosingAdvertisingReturnsToStarting() {
        model.setVisible(true)
        model.serviceDidUpdateVisibility(isVisible: true)
        model.serviceDidUpdateVisibility(isVisible: false)

        XCTAssertTrue(model.wantsVisible, "the user still wants to be visible")
        XCTAssertEqual(model.visibilityStatus, .starting)
    }

    // MARK: Control API default

    func testControlAPIIsOffByDefault() {
        XCTAssertFalse(model.controlAPIEnabled)
    }

    func testControlAPITogglePersists() {
        model.setControlAPIEnabled(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "controlAPIEnabled"))
        model.setControlAPIEnabled(false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "controlAPIEnabled"))
    }

    // MARK: Finder popup progress

    /// The share extension polls this snapshot over loopback. Every state it
    /// can show must be JSON-serializable — `Int64` in the payload used to
    /// make `JSONSerialization` emit an empty body, so the popup stayed stuck.
    func testFinderProgressFollowsTheOutgoingSend() {
        let device = RemoteDevice(id: "d1", name: "Redmi Note 14", type: .phone)
        model.serviceDidDiscover(device)

        XCTAssertEqual(model.finderProgress(deviceName: device.name)["state"] as? String, "idle")

        var started: AppModel.CliSendResult?
        model.cliSend(paths: ["/etc/hosts"], to: device.name) { started = $0 }
        XCTAssertNil(started, "cliSend must not finish until the transfer does")
        assertFinderJSON(model.finderProgress(deviceName: device.name), state: "connecting")
        XCTAssertEqual(model.finderProgress(deviceName: "Other Phone")["state"] as? String, "idle")

        model.serviceDidEstablishConnection(with: device, pin: "4242")
        let waiting = assertFinderJSON(model.finderProgress(deviceName: device.name),
                                       state: "awaitingConsent")
        XCTAssertEqual(waiting["pin"] as? String, "4242")

        model.serviceDidAcceptTransfer(id: device.id)
        let sending = assertFinderJSON(model.finderProgress(deviceName: device.name),
                                       state: "sending")
        XCTAssertEqual(sending["fraction"] as? Double, 0)

        model.serviceDidUpdateProgress(id: device.id, fraction: 0.42)
        let mid = assertFinderJSON(model.finderProgress(deviceName: device.name),
                                   state: "sending")
        XCTAssertEqual(mid["fraction"] as? Double, 0.42)
        XCTAssertNotNil(mid["totalBytes"] as? Int)

        model.serviceDidFinishTransfer(id: device.id, error: nil)
        XCTAssertEqual(started?.ok, true)
        XCTAssertEqual(model.finderProgress(deviceName: device.name)["state"] as? String, "idle")
    }

    @discardableResult
    private func assertFinderJSON(_ snapshot: [String: Any],
                                  state: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> [String: Any] {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshot),
                      "Finder progress payload must be JSON", file: file, line: line)
        XCTAssertEqual(snapshot["state"] as? String, state, file: file, line: line)
        return snapshot
    }
}
