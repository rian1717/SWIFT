import Foundation
import Network

/// Finds phones running the SWIFT app. They advertise only while the
/// screen is on, the same way an iPhone appears when its screen wakes.
@MainActor
final class CompanionBrowser {
    var onFound: ((RemoteDevice) -> Void)?
    var onLost: ((String) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "swift.companion")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_swiftdevice._tcp", domain: nil),
            using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            let additions = changes.compactMap { change -> NWBrowser.Result? in
                if case .added(let result) = change { return result }
                return nil
            }
            let removals = changes.compactMap { change -> String? in
                if case .removed(let result) = change,
                   case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in
                for result in additions { self?.publish(result) }
                for name in removals { self?.onLost?(name) }
            }
        }
        browser.start(queue: queue)
    }

    private func publish(_ result: NWBrowser.Result) {
        guard case let .bonjour(record) = result.metadata,
              case let .service(name, _, _, _) = result.endpoint,
              let phone = record.dictionary["name"], !phone.isEmpty,
              let host = record.dictionary["ip"], !host.isEmpty,
              let port = Int(record.dictionary["port"] ?? ""), port > 0
        else { return }
        let device = RemoteDevice(id: name, name: phone, type: .phone,
                                  companionHost: host, companionPort: port)
        Task { @MainActor in self.onFound?(device) }
    }
}

/// Sends files to the SWIFT app on a paired phone.
enum CompanionSender {
    static func send(files: [FileItem], host: String, port: Int, token: String,
                     progress: @escaping (Double) -> Void,
                     done: @escaping (String?) -> Void) {
        guard !token.isEmpty else {
            done("Turn on Paste phone copies here, so this phone can receive.")
            return
        }
        let total = max(files.count, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            for (index, file) in files.enumerated() {
                do {
                    try upload(file, host: host, port: port, token: token)
                    progress(Double(index + 1) / Double(total))
                } catch {
                    done(error.localizedDescription)
                    return
                }
            }
            done(nil)
        }
    }

    private static func upload(_ file: FileItem, host: String, port: Int, token: String) throws {
        guard let url = URL(string: "http://\(host):\(port)/share") else {
            throw NSError(domain: "SWIFT", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "The phone’s address could not be used."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "file"
        request.setValue(encoded, forHTTPHeaderField: "X-SWIFT-Name")
        let wait = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.uploadTask(with: request, fromFile: file.url) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                failure = error
            } else if !(200..<300).contains(code) {
                failure = NSError(domain: "SWIFT", code: code,
                                  userInfo: [NSLocalizedDescriptionKey: "The phone did not accept \(file.name)."])
            }
            wait.signal()
        }
        task.resume()
        wait.wait()
        if let failure { throw failure }
    }
}
