import Foundation
import UserNotifications

/// Localhost control API endpoints, plus the debug hooks that only exist
/// under SWIFT_MOCK. Kept apart from the model's own state machine.
extension AppModel {
    // MARK: Finder share extension

    /// Live state of the send the Finder popup started, polled over loopback.
    func finderProgress(deviceName: String) -> [String: Any] {
        if let transfer = transfers.first(where: {
            $0.direction == .outgoing && $0.deviceName == deviceName && !$0.phase.isTerminal
        }) {
            return ["state": "sending", "fraction": transfer.fraction,
                    "totalBytes": Int(clamping: transfer.totalBytes)]
        }
        switch connection {
        case .awaitingConsent(let device, let pin) where device.name == deviceName:
            return ["state": "awaitingConsent", "pin": pin]
        case .connecting(let device) where device.name == deviceName:
            return ["state": "connecting"]
        default:
            return ["state": "idle"]
        }
    }

    // MARK: CLI / control API


    func devicesForCLI() -> [[String: Any]] {
        availableDevices.map { ["name": $0.name, "id": $0.id, "type": $0.type.rawValue, "known": isKnown($0.name)] }
    }

    func transfersForCLI() -> [[String: Any]] {
        transfers.map {
            ["title": $0.title, "device": $0.deviceName, "percent": Int($0.fraction * 100),
             "phase": "\($0.phase)"]
        }
    }

    /// Send files to a device by name (or id), invoking `completion` when the
    /// transfer finishes. Reuses the normal send flow so the GUI reflects it.
    func cliSend(paths: [String], to name: String, completion: @escaping (CliSendResult) -> Void) {
        // The send flow is single-slot and shares its state with the window, so a
        // CLI send while the user is mid-flow would silently discard their staged
        // files. Refuse instead of clobbering.
        guard case .idle = connection, cliPending.isEmpty else {
            completion(CliSendResult(ok: false, pin: nil, error: "busy")); return
        }
        guard let device = discoveredDevices.first(where: {
            $0.name == name || $0.id == name || namesMatch($0.name, name)
        }) else {
            completion(CliSendResult(ok: false, pin: nil, error: "device_not_found")); return
        }
        let files = paths.compactMap { p -> FileItem? in
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return FileItem(url: url, sizeBytes: size)
        }
        guard !files.isEmpty else { completion(CliSendResult(ok: false, pin: nil, error: "no_readable_files")); return }
        cliPending[device.id] = completion
        stagedFiles = files
        connection = .connecting(device)
        service.sendFiles(files, to: device)
        scheduleConnectTimeout(for: device)
    }

    func finishCli(_ deviceID: String, ok: Bool, error: String?) {
        guard let completion = cliPending.removeValue(forKey: deviceID) else { return }
        completion(CliSendResult(ok: ok, pin: cliPins.removeValue(forKey: deviceID), error: error))
    }

    /// Release every parked CLI request (used when the control API is switched
    /// off mid-flight, so no HTTP client is left hanging).
    func failAllPendingCli(error: String) {
        let pending = cliPending
        cliPending.removeAll()
        cliPins.removeAll()
        for (_, completion) in pending {
            completion(CliSendResult(ok: false, pin: nil, error: error))
        }
    }

    // MARK: Debug (SWIFT_MOCK only — see ControlServer's /debug/* gating)

    /// Synthesizes an incoming request as if it had just arrived over the
    /// network, exercising the exact same path a real one takes — explicit
    /// consent, app activation, the window-reopen token — from a single CLI
    /// call instead of a GUI test run.
    func debugFireIncomingRequest(deviceName: String, files: [String], bytes: Int64, pin: String) {
        let request = IncomingRequest(
            id: "debug-\(UUID().uuidString.prefix(6))",
            device: RemoteDevice(id: "debug-\(deviceName)", name: deviceName, type: .phone),
            fileNames: files.isEmpty ? ["debug-file.txt"] : files,
            totalBytes: bytes,
            pin: pin)
        serviceDidReceiveIncomingRequest(request)
    }

    /// What the system has actually recorded as delivered, plus current
    /// permission status — the only reliable way to confirm a notification
    /// really reached the system, rather than screenshotting a banner that's
    /// gone in a few seconds.
    /// A delivered notification, as a concrete `Sendable` value.
    ///
    /// This crossed an isolation boundary as `[[String: Any]]`, which Swift 6
    /// rejects and is right to: `Any` can hold anything, so the compiler cannot
    /// know the payload is safe to send. Modelling it removes the doubt rather
    /// than silencing it.
    struct DeliveredNotification: Sendable {
        let id: String
        let title: String
        let body: String

        var asJSON: [String: String] { ["id": id, "title": title, "body": body] }
    }

    func debugNotificationStatus(
        completion: @escaping @MainActor (_ delivered: [DeliveredNotification],
                                         _ authorization: String) -> Void
    ) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                let delivered = notifications.map {
                    DeliveredNotification(id: $0.request.identifier,
                                          title: $0.request.content.title,
                                          body: $0.request.content.body)
                }
                let authorization: String
                switch settings.authorizationStatus {
                case .authorized:    authorization = "authorized"
                case .denied:        authorization = "denied"
                case .notDetermined: authorization = "notDetermined"
                case .provisional:   authorization = "provisional"
                case .ephemeral:     authorization = "ephemeral"
                @unknown default:    authorization = "unknown"
                }
                Task { @MainActor in completion(delivered, authorization) }
            }
        }
    }

    /// Devices currently reachable. Paired phones come first, then everyone else
    /// with previously-seen names ahead of strangers.
    var availableDevices: [RemoteDevice] {
        myDevices + nearbyDevices
    }

    /// Jump into the send flow targeting a specific device (from the menu).
    func prepareSend(to device: RemoteDevice) {
        mode = .send
        connection = .staging(device)
    }
}
