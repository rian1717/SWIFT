import AppKit
import SWIFTCore

/// Copies the selected files where the SWIFT app can read them, then asks that
/// app to send. The sheet does not open its own connection to the phone.
@MainActor
final class ShareAppClient {
    private var jobID: String?
    private var finished = false
    var onEvent: ((String, [String: Any]) -> Void)?

    func send(files: [URL], to deviceName: String, deviceID: String, host: String?, port: Int?) {
        ShareSocket.prepareDirectory()
        let folder = URL(fileURLWithPath: ShareSocket.directory, isDirectory: true)
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        let paths: [String]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            paths = try files.map { source in
                let dest = folder.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                return dest.path
            }
        } catch {
            onEvent?("failed", ["error": "SWIFT couldn't open that file"])
            return
        }
        guard !paths.isEmpty else {
            onEvent?("failed", ["error": "SWIFT couldn't open that file"])
            return
        }
        let id = UUID().uuidString
        jobID = id
        finished = false
        Task {
            await self.deliver(id: id, paths: paths, deviceName: deviceName,
                               deviceID: deviceID, host: host, port: port)
        }
    }

    func cancel() {
        guard let id = jobID else { return }
        FileManager.default.createFile(atPath: ShareSocket.jobURL(id, "cancel").path, contents: Data())
    }

    private func deliver(id: String, paths: [String], deviceName: String,
                         deviceID: String, host: String?, port: Int?) async {
        if !FileManager.default.fileExists(atPath: ShareSocket.jobs) {
            openApp()
            for _ in 0..<25 {
                if FileManager.default.fileExists(atPath: ShareSocket.jobs) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        var request: [String: Any] = ["id": id, "deviceName": deviceName, "deviceID": deviceID, "paths": paths]
        if let host, let port {
            request["host"] = host
            request["port"] = port
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        let url = ShareSocket.jobURL(id, "request")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            onEvent?("failed", ["error": "Open SWIFT and try again"])
            return
        }
        chmod(url.path, 0o666)
        let events = ShareSocket.jobURL(id, "events")
        var offset = 0
        var pending = Data()
        for _ in 0..<600 {
            if finished { return }
            if let data = try? Data(contentsOf: events), data.count > offset {
                pending.append(data.dropFirst(offset))
                offset = data.count
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending.prefix(upTo: newline))
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let event = object["event"] as? String else { continue }
                    onEvent?(event, object)
                    if event == "sent" || event == "failed" {
                        finished = true
                        return
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !finished {
            onEvent?("failed", ["error": "Open SWIFT and try again"])
        }
    }

    private func openApp() {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}
