import CryptoKit
import Foundation

/// A phone paired with its own key. The key is worked out on each side during
/// pairing and never crosses the network, so someone listening on the Wi-Fi
/// can neither read the copies nor send their own.
struct ClipboardPhone: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var key: Data
    /// The highest request number this phone has used. An older one is a replay.
    var counter: UInt64
}

/// The crypto shared with the Android app. `ClipCrypto.kt` must match it byte for byte.
enum ClipboardCrypto {
    static let phoneLabel = Data("swift-clip-v2 phone".utf8)
    static let macLabel = Data("swift-clip-v2 mac".utf8)
    static let authorizationScheme = "SWIFT "

    /// How the phone proves it may pair: the 8-digit code, the token from an
    /// older pairing, or nothing, in which case the Mac asks the person.
    enum Auth: String {
        case code, token, approve
    }

    enum Failure: Error {
        case badKey, badMessage
    }

    /// Both sides derive this. `secret` binds the key to the code or old token,
    /// so a stranger who answers in the Mac's place cannot finish pairing.
    static func pairingKey(macPrivate: P256.KeyAgreement.PrivateKey, phonePublic: Data,
                           secret: String) throws -> SymmetricKey {
        guard let phone = try? P256.KeyAgreement.PublicKey(x963Representation: phonePublic) else {
            throw Failure.badKey
        }
        let shared = try macPrivate.sharedSecretFromKeyAgreement(with: phone)
        let raw = shared.withUnsafeBytes { Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: raw),
            salt: Data(("swift-clip-v2|" + secret).utf8),
            info: phonePublic + macPrivate.publicKey.x963Representation,
            outputByteCount: 32)
    }

    static func proof(_ key: SymmetricKey, _ label: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label, using: key))
    }

    /// Constant time.
    static func verify(_ given: Data, _ key: SymmetricKey, _ label: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: label, using: key)
    }

    /// `nonce ‖ ciphertext ‖ tag`. The plaintext is an 8-byte request number,
    /// then the request body. The path and phone id are authenticated too, so a
    /// captured message cannot be replayed against another endpoint or phone.
    static func seal(_ payload: Data, counter: UInt64, key: SymmetricKey, path: String, id: String,
                     nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        var plain = Data()
        withUnsafeBytes(of: counter.bigEndian) { plain.append(contentsOf: $0) }
        plain.append(payload)
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad(path: path, id: id))
        guard let combined = box.combined else { throw Failure.badMessage }
        return combined
    }

    static func open(_ body: Data, key: SymmetricKey, path: String, id: String) throws -> (counter: UInt64, payload: Data) {
        guard body.count >= 12 + 16 + 8,
              let box = try? AES.GCM.SealedBox(combined: body),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad(path: path, id: id)),
              plain.count >= 8 else {
            throw Failure.badMessage
        }
        let counter = plain.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (counter, Data(plain.dropFirst(8)))
    }

    private static func aad(path: String, id: String) -> Data {
        Data("\(path) \(id)".utf8)
    }

    static func newPhoneID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The phones that hold a key, saved by the app.
@MainActor
final class ClipboardPhoneStore {
    private(set) var phones: [ClipboardPhone]
    private let persist: ([ClipboardPhone]) -> Void

    init(phones: [ClipboardPhone], persist: @escaping ([ClipboardPhone]) -> Void) {
        self.phones = phones
        self.persist = persist
    }

    func phone(id: String) -> ClipboardPhone? {
        phones.first { $0.id == id }
    }

    func add(_ phone: ClipboardPhone) {
        phones.removeAll { $0.id == phone.id }
        phones.append(phone)
        persist(phones)
    }

    @discardableResult
    func remove(id: String) -> ClipboardPhone? {
        guard let index = phones.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = phones.remove(at: index)
        persist(phones)
        return removed
    }

    /// Removing a phone deletes its key. It cannot send again by changing its name.
    func remove(where matches: (String) -> Bool) {
        let before = phones.count
        phones.removeAll { matches($0.name) }
        if phones.count != before { persist(phones) }
    }

    /// Accepts only a number higher than any this phone used before.
    func advance(id: String, to counter: UInt64, save: Bool) -> Bool {
        guard let index = phones.firstIndex(where: { $0.id == id }),
              counter > phones[index].counter else { return false }
        phones[index].counter = counter
        if save { persist(phones) }
        return true
    }
}
