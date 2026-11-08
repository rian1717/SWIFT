import CryptoKit
import XCTest
@testable import SWIFTApp

/// The same numbers are checked in the Android app's `ClipCryptoTest`, so the
/// two sides cannot drift apart.
final class ClipboardCryptoVectorTests: XCTestCase {
    let mac = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    let phone = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))

    func testPairingKeyAndProofsMatchTheAndroidApp() throws {
        let phonePub = phone.publicKey.x963Representation
        XCTAssertEqual(hex(phonePub), "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285")
        let key = try ClipboardCrypto.pairingKey(macPrivate: mac, phonePublic: phonePub, secret: "12345678")
        XCTAssertEqual(hex(key.withUnsafeBytes { Data($0) }), "dadd1743181f388a2dd6e12c5b28e52e68a8af13d70b99c25d07a799a28a2647")
        XCTAssertEqual(hex(ClipboardCrypto.proof(key, ClipboardCrypto.phoneLabel)), "7dd0453d5bd97615e500fab3871c2a8321b5831f9bd6e9b609d2eb6080939986")
        XCTAssertEqual(hex(ClipboardCrypto.proof(key, ClipboardCrypto.macLabel)), "9d4c0da798f383bb81b9d222597555dae4e8fce056080a1a32e030b4e626ee61")
    }

    func testSealedMessageMatchesTheAndroidApp() throws {
        let key = try ClipboardCrypto.pairingKey(macPrivate: mac, phonePublic: phone.publicKey.x963Representation, secret: "12345678")
        let sealed = try ClipboardCrypto.seal(Data("hello".utf8), counter: 7, key: key, path: "/clip", id: "abc",
                                              nonce: try AES.GCM.Nonce(data: Data(0..<12)))
        XCTAssertEqual(hex(sealed), "000102030405060708090a0bc5bac521ef475881655ca36811e652d3c025468895e985c88ac92c24a3")
        let opened = try ClipboardCrypto.open(sealed, key: key, path: "/clip", id: "abc")
        XCTAssertEqual(opened.counter, 7)
        XCTAssertEqual(opened.payload, Data("hello".utf8))
        // The same bytes sent to another endpoint or as another phone do not open.
        XCTAssertThrowsError(try ClipboardCrypto.open(sealed, key: key, path: "/clip/status", id: "abc"))
        XCTAssertThrowsError(try ClipboardCrypto.open(sealed, key: key, path: "/clip", id: "abd"))
    }

    func testAWrongCodeGivesADifferentKey() throws {
        let phonePub = phone.publicKey.x963Representation
        let right = try ClipboardCrypto.pairingKey(macPrivate: mac, phonePublic: phonePub, secret: "12345678")
        let wrong = try ClipboardCrypto.pairingKey(macPrivate: mac, phonePublic: phonePub, secret: "12345679")
        XCTAssertFalse(ClipboardCrypto.verify(ClipboardCrypto.proof(wrong, ClipboardCrypto.phoneLabel), right, ClipboardCrypto.phoneLabel))
    }
}

/// The real server, on a spare port, driven the way the phone drives it.
@MainActor
final class ClipboardServerSecurityTests: XCTestCase {
    private let code = "24681357"
    private let token = String(repeating: "ab", count: 32)
    private var server: ClipboardServer!
    private var store: ClipboardPhoneStore!
    private var saved: [ClipboardPhone] = []
    private var applied: [String] = []
    private var removedNames: Set<String> = []
    private var paired: [String] = []
    private var port: UInt16 = 0

    override func setUp() async throws {
        port = UInt16.random(in: 49_200...60_000)
        store = ClipboardPhoneStore(phones: []) { [weak self] in self?.saved = $0 }
        server = ClipboardServer(token: token, pairCode: code, deviceName: "Test Mac",
                                 identity: P256.KeyAgreement.PrivateKey(), phones: store,
                                 port: port, advertise: false)
        server.applyPayload = { [weak self] payload in
            self?.applied.append(payload.text ?? "")
            return "ok"
        }
        server.phoneIsRemoved = { [weak self] in self?.removedNames.contains($0) ?? false }
        server.onPairedPhone = { [weak self] in self?.paired.append($0) }
        let ready = expectation(description: "listening")
        server.onListening = { if $0 { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
    }

    override func tearDown() async throws {
        server.stop()
    }

    func testPairedPhoneSendsAnEncryptedCopy() async throws {
        let phone = try await pair(secret: code, auth: "code")
        XCTAssertEqual(paired, ["Pixel"])
        XCTAssertEqual(saved.count, 1, "the key is saved for the next launch")
        let reply = try await send(phone, path: "/clip", json: #"{"source":"Pixel","kind":"text","text":"secret"}"#, counter: 10)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(applied, ["secret"])
    }

    func testACapturedCopyCannotBeSentAgain() async throws {
        let phone = try await pair(secret: code, auth: "code")
        let body = try phone.seal(#"{"source":"Pixel","kind":"text","text":"one"}"#, path: "/clip", counter: 5)
        let first = try await post("/clip", body: body, auth: "SWIFT \(phone.id)")
        let again = try await post("/clip", body: body, auth: "SWIFT \(phone.id)")
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(again.status, 401)
        XCTAssertEqual(applied, ["one"])
    }

    func testAWrongCodeIsRefusedAndNothingIsSaved() async throws {
        do {
            _ = try await pair(secret: "11111111", auth: "code")
            XCTFail("paired with the wrong code")
        } catch PairFailure.refused(let reason) {
            XCTAssertTrue(reason.contains("bad_code"))
        }
        XCTAssertTrue(saved.isEmpty)
    }

    func testARemovedPhoneCannotSendEvenUnderAnotherName() async throws {
        let phone = try await pair(secret: code, auth: "code")
        store.remove { $0 == "Pixel" }
        let status = try await send(phone, path: "/clip/status", json: "{}", counter: 1)
        XCTAssertEqual(status.status, 401)
        XCTAssertTrue(status.body.contains("removed"))
        let copy = try await send(phone, path: "/clip", json: #"{"source":"Another name","kind":"text","text":"x"}"#, counter: 2)
        XCTAssertEqual(copy.status, 401)
        XCTAssertTrue(applied.isEmpty)
    }

    func testAnOldPhoneMovesToItsOwnKeyWithTheToken() async throws {
        let phone = try await pair(secret: token, auth: "token")
        let reply = try await send(phone, path: "/clip/status", json: "{}", counter: 1)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(paired.isEmpty, "an upgrade is not a new pairing")
    }

    func testARemovedOldPhoneDoesNotGetAKey() async throws {
        removedNames = ["Pixel"]
        do {
            _ = try await pair(secret: token, auth: "token")
            XCTFail("a removed phone got a key")
        } catch PairFailure.refused(let reason) {
            XCTAssertTrue(reason.contains("removed"))
        }
    }

    func testOldPhonesStillWork() async throws {
        let reply = try await post("/clip", body: Data(#"{"source":"Old","kind":"text","text":"legacy"}"#.utf8),
                                   auth: "Bearer \(token)")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(applied, ["legacy"])
    }

    // MARK: - A phone, as the Android app does it

    private struct Phone {
        let id: String
        let key: SymmetricKey
        func seal(_ json: String, path: String, counter: UInt64) throws -> Data {
            try ClipboardCrypto.seal(Data(json.utf8), counter: counter, key: key, path: path, id: id)
        }
    }

    private enum PairFailure: Error { case refused(String) }

    private func pair(secret: String, auth: String) async throws -> Phone {
        let hello = try await get("/clip/hello")
        let helloJSON = try JSONSerialization.jsonObject(with: Data(hello.body.utf8)) as! [String: Any]
        let macPublic = try P256.KeyAgreement.PublicKey(
            x963Representation: Data(base64Encoded: helloJSON["key"] as! String)!)
        let mine = P256.KeyAgreement.PrivateKey()
        let shared = try mine.sharedSecretFromKeyAgreement(with: macPublic).withUnsafeBytes { Data($0) }
        let phonePublic = mine.publicKey.x963Representation
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared),
                                         salt: Data(("swift-clip-v2|" + secret).utf8),
                                         info: phonePublic + macPublic.x963Representation, outputByteCount: 32)
        let request: [String: Any] = [
            "device": "Pixel", "auth": auth, "pub": phonePublic.base64EncodedString(),
            "proof": ClipboardCrypto.proof(key, ClipboardCrypto.phoneLabel).base64EncodedString(),
        ]
        let reply = try await post("/clip/pair", body: try JSONSerialization.data(withJSONObject: request), auth: nil)
        guard reply.status == 200 else { throw PairFailure.refused(reply.body) }
        let json = try JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as! [String: Any]
        XCTAssertNil(json["token"], "the shared token is never sent to a phone that has a key")
        let macProof = Data(base64Encoded: json["proof"] as! String)!
        XCTAssertTrue(ClipboardCrypto.verify(macProof, key, ClipboardCrypto.macLabel), "the Mac proves it knew the code")
        return Phone(id: json["id"] as! String, key: key)
    }

    private func send(_ phone: Phone, path: String, json: String, counter: UInt64) async throws -> (status: Int, body: String) {
        try await post(path, body: try phone.seal(json, path: path, counter: counter), auth: "SWIFT \(phone.id)")
    }

    private func get(_ path: String) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    private func post(_ path: String, body: Data, auth: String?) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
