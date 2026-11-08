import Darwin
import Foundation
import SWIFTCore

/// Watches /tmp/swift-share/jobs for a request from the share sheet and runs
/// it through the app's own send flow.
@MainActor
final class ShareBridge {
    private weak var model: AppModel?
    private var watchFD: Int32 = -1
    private var watch: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var names: [String: String] = [:]
    private var activeID: String?

    func start(model: AppModel) {
        guard watchFD < 0 else { return }
        self.model = model
        ShareSocket.prepareDirectory()
        let fd = open(ShareSocket.jobs, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = source
        scan()
    }

    func send(_ object: [String: Any]) {
        guard let id = activeID else { return }
        emit(id, object)
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ShareSocket.jobs)) ?? []
        for name in names where name.hasSuffix(".cancel") {
            let id = String(name.dropLast(".cancel".count))
            let device = self.names[id]
            try? FileManager.default.removeItem(at: ShareSocket.jobURL(id, "cancel"))
            if let device { model?.cancelShareSend(named: device) }
        }
        for name in names where name.hasSuffix(".request") {
            let id = String(name.dropLast(".request".count))
            guard seen.insert(id).inserted else { continue }
            let url = ShareSocket.jobURL(id, "request")
            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = object["deviceName"] as? String,
                  let paths = object["paths"] as? [String], !paths.isEmpty else {
                emit(id, ["event": "failed", "error": "bad request"])
                continue
            }
            self.names[id] = device
            if let host = object["host"] as? String,
               let port = (object["port"] as? NSNumber)?.intValue,
               let deviceID = object["deviceID"] as? String {
                model?.noteShareTarget(id: deviceID, name: device, host: host, port: port)
            }
            begin(id: id, device: device, paths: paths)
        }
    }

    private func begin(id: String, device: String, paths: [String]) {
        Task { @MainActor in
            for _ in 0..<40 {
                if self.activeID != nil {
                    self.emit(id, ["event": "failed", "error": "busy"])
                    self.names[id] = nil
                    return
                }
                if self.model?.hasDiscoveredDevice(named: device) == true {
                    self.activeID = id
                    self.model?.cliSend(paths: paths, to: device) { result in
                        Task { @MainActor in
                            if result.ok {
                                self.emit(id, ["event": "sent"])
                            } else {
                                self.emit(id, ["event": "failed", "error": result.error ?? "failed"])
                            }
                            if self.activeID == id { self.activeID = nil }
                            self.names[id] = nil
                        }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.emit(id, ["event": "failed", "error": "device_not_found"])
            self.names[id] = nil
        }
    }

    private func emit(_ id: String, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        let url = ShareSocket.jobURL(id, "events")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            chmod(url.path, 0o666)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
