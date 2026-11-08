import Foundation

/// Fake engine that drives the dummy UI through every state with realistic
/// timing, so the interface can be reviewed before the real protocol lands.
///
/// Nothing here touches the network. Enabled with `SWIFT_MOCK=1`; the real
/// engine is `NearbySWIFTService`.
@MainActor
final class MockSWIFTService: SWIFTService {
    weak var delegate: SWIFTServiceDelegate?

    private var advertising = false
    private var discovering = false

    private let sampleDevices = [
        RemoteDevice(id: "dev-pixel", name: "Pixel 8 Pro", type: .phone),
        RemoteDevice(id: "dev-galaxy", name: "Galaxy S24", type: .phone),
        RemoteDevice(id: "dev-tab", name: "Galaxy Tab S9", type: .tablet),
    ]

    // MARK: Receive side

    func startAdvertising(deviceName: String) {
        advertising = true
        delegate?.serviceDidUpdateVisibility(isVisible: true)

        // Simulate an Android device sending us something ~6s after we go visible.
        schedule(6.0) { [weak self] in
            guard let self, self.advertising else { return }
            let req = IncomingRequest(
                id: "in-\(UUID().uuidString.prefix(6))",
                device: RemoteDevice(id: "dev-pixel", name: "Pixel 8 Pro", type: .phone),
                fileNames: ["sunset.jpg"],
                totalBytes: 2_412_000,
                pin: Self.randomPin()
            )
            self.delegate?.serviceDidReceiveIncomingRequest(req)
        }
    }

    func stopAdvertising() {
        advertising = false
        delegate?.serviceDidUpdateVisibility(isVisible: false)
    }

    func setReceiveDirectory(_ url: URL) {}

    func respondToIncoming(id: String, accept: Bool) {
        guard accept else {
            delegate?.serviceDidFinishTransfer(id: id, error: nil)   // declined = clean close
            return
        }
        // `serviceDidAcceptTransfer` is a send-side event (the real engine only
        // fires it when a remote device accepts *our* send) — the caller already
        // inserted this transfer's row before calling us, so firing it here too
        // would hit AppModel's "unknown id" fallback and insert a bogus duplicate.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let resolved = [TransferFile(name: "sunset.jpg", url: downloads?.appendingPathComponent("sunset.jpg"))]
        simulateProgress(id: id, resolve: resolved)
    }

    // MARK: Send side

    func startDiscovery() {
        discovering = true
        // Devices trickle in like real mDNS discovery.
        for (i, device) in sampleDevices.enumerated() {
            schedule(0.8 + Double(i) * 0.9) { [weak self] in
                guard let self, self.discovering else { return }
                self.delegate?.serviceDidDiscover(device)
            }
        }
    }

    func stopDiscovery() {
        discovering = false
    }

    func sendFiles(_ files: [FileItem], to device: RemoteDevice) {
        let id = device.id   // matches the real engine, which keys by device id
        // Handshake completes → PIN, then the remote user accepts, then bytes flow.
        schedule(1.2) { [weak self] in
            self?.delegate?.serviceDidEstablishConnection(with: device, pin: Self.randomPin())
            self?.schedule(1.8) {
                self?.delegate?.serviceDidAcceptTransfer(id: id)
                self?.simulateProgress(id: id)
            }
        }
    }

    func cancelTransfer(id: String) {
        cancelled.insert(id)
    }

    // MARK: QR send

    private var qrActive = false

    func prepareQRCode() -> String? {
        qrActive = true
        // Pretend a device scans it ~4s later and becomes reachable.
        schedule(4.0) { [weak self] in
            guard let self, self.qrActive else { return }
            self.delegate?.serviceDidMatchQRDevice(
                RemoteDevice(id: "dev-pixel", name: "Pixel 8 Pro", type: .phone))
        }
        return "https://quickshare.google/qrcode#key=MOCK-\(UUID().uuidString.prefix(8))"
    }

    func finishAddPhone(_ device: RemoteDevice) {}

    func cancelQRCode() {
        qrActive = false
    }

    // MARK: Simulation helpers

    private var cancelled = Set<String>()

    private func simulateProgress(id: String, step: Double = 0.06, resolve: [TransferFile]? = nil) {
        func tick(_ fraction: Double) {
            guard !cancelled.contains(id) else {
                delegate?.serviceDidFinishTransfer(id: id, error: "Cancelled")
                return
            }
            if fraction >= 1.0 {
                delegate?.serviceDidUpdateProgress(id: id, fraction: 1.0)
                if let resolve { delegate?.serviceDidResolveFiles(id: id, files: resolve) }
                delegate?.serviceDidFinishTransfer(id: id, error: nil)
                return
            }
            delegate?.serviceDidUpdateProgress(id: id, fraction: fraction)
            schedule(0.12) { tick(fraction + step) }
        }
        tick(0)
    }

    private func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    private static func randomPin() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}

// MARK: - Demo fixtures

/// Sample transfers for `SWIFT_MOCK=1`.
///
/// Deliberately neutral — no real filenames, people or devices — because this is
/// what ends up in screenshots. Lives outside AppModel because it's fixture
/// data, not app state.
enum DemoData {

    static func transfers() -> [ActiveTransfer] {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        func file(_ n: String) -> TransferFile { TransferFile(name: n, url: dl.appendingPathComponent(n)) }

        let devices = ["Pixel 8 Pro", "Galaxy S24", "Galaxy Tab S9"]
        // (filename, direction, bytes) — newest first
        let items: [(String, TransferDirection, Int64)] = [
            ("Mountain-sunset.jpg", .outgoing,  1_800_000),
            ("Release-notes.pdf",   .incoming,    320_000),
            ("IMG_2481.heic",       .outgoing,  4_500_000),
        ]
        var demo: [ActiveTransfer] = items.enumerated().map { i, it in
            ActiveTransfer(id: "demo-\(i)", direction: it.1, deviceName: devices[i % devices.count],
                           title: it.0, totalBytes: it.2, fraction: 1, phase: .completed, files: [file(it.0)])
        }

        // One in-progress transfer at the top for a richer screenshot.
        demo.insert(ActiveTransfer(id: "demo-live", direction: .outgoing, deviceName: "Pixel 8 Pro",
                                   title: "Travel-video.mov", totalBytes: 84_000_000, fraction: 0.62,
                                   phase: .transferring, files: [file("Travel-video.mov")]), at: 0)

        return demo
    }
}
