import AppKit
import SWIFTCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

@objc(ShareViewController)
@MainActor
final class ShareViewController: NSViewController {
    private let model = ShareExtensionModel()

    override func loadView() {
        let root = ShareExtensionView(
            model: model,
            cancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: CocoaError(.userCancelled))
            })
        // A hosting controller added as a child while this controller is still
        // inside loadView can cause AppKit to ask for the parent view again,
        // recursively stalling Finder's share sheet. A hosting view has no
        // child-controller lifecycle and is sufficient for an extension.
        view = NSHostingView(rootView: root)
        preferredContentSize = NSSize(width: 380, height: 460)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onFinished = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .map(SendableProvider.init)
        Task {
            let urls = await Self.loadURLs(from: providers)
            model.configure(urls: urls)
        }
    }

    override func viewWillDisappear() {
        model.stop()
        super.viewWillDisappear()
    }

    private nonisolated static func loadURLs(
        from providers: [SendableProvider]
    ) async -> [URL] {
        return await withTaskGroup(of: URL?.self) { group in
            for box in providers where box.provider.hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier) {
                group.addTask {
                    await loadURL(from: box)
                }
            }
            var result: [URL] = []
            for await url in group {
                if let url { result.append(url) }
            }
            return result
        }
    }

    /// Finder providers occasionally fail to invoke their callback. Never let
    /// that wedge the share sheet indefinitely.
    private nonisolated static func loadURL(from box: SendableProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            let result = OneShotURL(continuation)
            box.provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { url, _, _ in
                result.resume(url)
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                result.resume(nil)
            }
        }
    }
}

private final class SendableProvider: @unchecked Sendable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
}

private final class OneShotURL: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?

    init(_ continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func resume(_ url: URL?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: url)
    }
}

@MainActor
@Observable
private final class ShareExtensionModel {
    enum Phase: Equatable {
        case loading
        case searching
        case ready
        case connecting(String)
        case waiting(pin: String)
        case transferring(Int)
        case completed
        case failed(String)
    }

    var phase: Phase = .loading
    var devices: [SWIFTDevice] = []
    var fileNames: [String] = []
    var onFinished: (() -> Void)?

    private var urls: [URL] = []
    private var selectedDevice: SWIFTDevice?
    private let engine = SWIFTEngine(
        deviceName: Host.current().localizedName ?? "SWIFT Mac",
        receiveDirectory: FileManager.default.temporaryDirectory)

    init() {
        engine.onDeviceFound = { [weak self] device in
            guard let self else { return }
            if !self.devices.contains(where: { $0.id == device.id }) {
                self.devices.append(device)
                self.devices.sort {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
            if self.phase == .searching { self.phase = .ready }
        }
        engine.onDeviceLost = { [weak self] id in
            self?.devices.removeAll { $0.id == id }
        }
        engine.onOutgoingEvent = { [weak self] _, event in
            guard let self else { return }
            switch event {
            case .connected(let pin):
                self.phase = .waiting(pin: pin)
            case .accepted:
                self.phase = .transferring(0)
            case .progress(let fraction):
                self.phase = .transferring(Int(fraction * 100))
            case .finished:
                self.phase = .completed
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    self.onFinished?()
                }
            case .failed(let error):
                self.phase = .failed(error.userMessage)
            }
        }
    }

    func configure(urls: [URL]) {
        self.urls = urls
        fileNames = urls.map(\.lastPathComponent)
        phase = urls.isEmpty ? .failed("No readable files were provided") : .searching
        if !urls.isEmpty { engine.startDiscovery() }
    }

    func send(to device: SWIFTDevice) {
        do {
            let outgoing = try urls.map(OutgoingFile.from)
            guard !outgoing.isEmpty else {
                phase = .failed("No readable files were provided")
                return
            }
            selectedDevice = device
            phase = .connecting(device.name)
            engine.send(files: outgoing, to: device)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        phase = devices.isEmpty ? .searching : .ready
    }

    func stop() {
        if let selectedDevice {
            engine.cancelTransfer(id: selectedDevice.id)
        }
        engine.stopDiscovery()
    }
}

private struct ShareExtensionView: View {
    @Bindable var model: ShareExtensionModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Send with SWIFT")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.plain)
            }

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading, .searching:
            status("Searching for Android devices…", symbol: "dot.radiowaves.left.and.right")
        case .ready:
            if model.devices.isEmpty {
                status("Open Quick Share on your Android device", symbol: "iphone.radiowaves.left.and.right")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.devices) { device in
                            Button { model.send(to: device) } label: {
                                HStack {
                                    Image(systemName: symbol(for: device.type))
                                    Text(device.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        case .connecting(let name):
            status("Connecting to \(name)…", symbol: "link")
        case .waiting(let pin):
            VStack(spacing: 12) {
                status("Confirm this PIN on both devices", symbol: "lock.shield")
                Text(pin)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        case .transferring(let percent):
            VStack(spacing: 12) {
                status("Sending… \(percent)%", symbol: "arrow.up.circle")
                ProgressView(value: Double(percent), total: 100)
            }
        case .completed:
            status("Sent", symbol: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 12) {
                status(message, symbol: "exclamationmark.triangle.fill")
                Button("Try Again") { model.retry() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34))
            Text(text).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        if model.fileNames.count == 1 { return model.fileNames[0] }
        return "\(model.fileNames.count) selected items"
    }

    private func symbol(for type: SWIFTDevice.DeviceType) -> String {
        switch type {
        case .phone: "iphone.gen3"
        case .tablet: "ipad"
        case .computer: "laptopcomputer"
        case .unknown: "questionmark.circle"
        }
    }
}
