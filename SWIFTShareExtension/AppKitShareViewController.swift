import AppKit
import SWIFTCore
import UniformTypeIdentifiers

/// Native AppKit surface for Finder's Share menu.
///
/// The view is built synchronously in `loadView`, so Finder receives a usable
/// remote view immediately. File-provider and network work starts afterwards.
@objc(AppKitShareViewController)
@MainActor
final class AppKitShareViewController: NSViewController {
    private let engine = SWIFTEngine(
        deviceName: Host.current().localizedName ?? "SWIFT Mac",
        receiveDirectory: FileManager.default.temporaryDirectory)
    /// Hands the file to the running SWIFT app. That app is the one whose
    /// send already reaches the phone.
    private let appClient = ShareAppClient()

    private let summaryLabel = NSTextField(labelWithString: "Preparing selected files…")
    private let statusLabel = NSTextField(labelWithString: "Searching for Android devices…")
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let devicesStack = NSStackView()

    private var urls: [URL] = []
    private var devices: [String: SWIFTDevice] = [:]
    private var selectedDeviceID: String?
    /// True from the tap until the transfer ends. A second click in that
    /// window must not open another connection.
    private var sendInFlight = false

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 460))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active

        let title = NSTextField(labelWithString: "SWIFT")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "arrow.left.arrow.right.circle.fill",
            accessibilityDescription: "SWIFT") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = .init(pointSize: 22, weight: .medium)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelShare))
        cancel.bezelStyle = .inline

        let header = NSStackView(views: [icon, title, NSView(), cancel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.maximumNumberOfLines = 2

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.usesThreadedAnimation = true
        progress.isHidden = true

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8
        devicesStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let loading = NSStackView(views: [spinner, statusLabel])
        loading.orientation = .vertical
        loading.alignment = .centerX
        loading.spacing = 12

        let content = NSStackView(views: [header, summaryLabel, NSBox.separator(), loading, progress, devicesStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        loading.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        devicesStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        devicesStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = NSSize(width: 400, height: 460)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireEngine()
        loadSelectedURLs()
        engine.startDiscovery()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        engine.startDiscovery()
    }

    override func viewWillDisappear() {
        // The sheet used to cancel the socket here. That ran as soon as the
        // view left the screen, including while a transfer was still opening,
        // so the phone never got the file. Cancel is the only thing that
        // aborts a send. The process teardown drops discovery with the view.
        super.viewWillDisappear()
    }

    private func wireEngine() {
        engine.onDeviceFound = { [weak self] device in
            self?.add(device)
        }
        engine.onDeviceLost = { [weak self] id in
            self?.removeDevice(id: id)
        }
        appClient.onEvent = { [weak self] event, object in
            guard let self else { return }
            switch event {
            case "pin":
                let pin = object["pin"] as? String ?? ""
                self.setStatus("Confirm PIN \(pin) on the phone")
            case "accepted":
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.progress.isHidden = false
                self.setStatus("Sending…")
            case "progress":
                let fraction = (object["fraction"] as? NSNumber)?.doubleValue ?? 0
                self.progress.doubleValue = fraction
                self.setStatus("Sending… \(Int(fraction * 100))%")
            case "sent":
                self.sendInFlight = false
                self.progress.doubleValue = 1
                self.setStatus("Sent")
                self.finish(after: .milliseconds(600))
            case "failed":
                self.sendInFlight = false
                self.setStatus(Self.message(for: object["error"] as? String))
                self.restoreDeviceButtons()
            default:
                break
            }
        }
    }

    private static func message(for error: String?) -> String {
        switch error {
        case "device_not_found": return "SWIFT can't see that phone yet"
        case "busy": return "SWIFT is already sending"
        case "no_readable_files": return "SWIFT couldn't open that file"
        default: return error ?? "Couldn't send"
        }
    }

    private func loadSelectedURLs() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            .map(ShareProvider.init)

        guard !providers.isEmpty else {
            summaryLabel.stringValue = "No files were provided"
            return
        }

        Task {
            let loaded = await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask { await Self.loadURL(from: provider) }
                }
                var values: [URL] = []
                for await url in group {
                    if let url { values.append(url) }
                }
                return values
            }
            let copies = Self.readableCopies(of: loaded)
            urls = copies
            if copies.isEmpty {
                summaryLabel.stringValue = loaded.first?.lastPathComponent ?? "Selected file"
                setStatus("SWIFT couldn’t open that file")
            } else if copies.count == 1 {
                summaryLabel.stringValue = copies[0].lastPathComponent
            } else {
                summaryLabel.stringValue = "\(copies.count) selected files"
            }
        }
    }

    /// Finder hands the extension a scoped URL. The main app cannot read that
    /// URL, so the file is copied somewhere it can.
    private nonisolated static func readableCopies(of sources: [URL]) -> [URL] {
        sources.compactMap { source in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("swift-share-\(UUID().uuidString)", isDirectory: true)
            let dest = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                return dest
            } catch {
                return FileManager.default.isReadableFile(atPath: source.path) ? source : nil
            }
        }
    }

    private nonisolated static func loadURL(from box: ShareProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            let result = ShareURLResult(continuation)
            box.provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL else {
                    result.resume(nil)
                    return
                }
                result.resume(url as URL)
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                result.resume(nil)
            }
        }
    }

    private func add(_ device: SWIFTDevice) {
        guard devices[device.id] == nil else { return }
        devices[device.id] = device

        let button = NSButton(
            title: device.name,
            target: self,
            action: #selector(selectDevice(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(device.id)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.image = NSImage(
            systemSymbolName: symbol(for: device.type),
            accessibilityDescription: device.name)
        devicesStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true

        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "Choose a nearby device"
    }

    private func removeDevice(id: String) {
        devices[id] = nil
        guard let button = devicesStack.arrangedSubviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier?.rawValue == id }) else { return }
        devicesStack.removeArrangedSubview(button)
        button.removeFromSuperview()

        if devices.isEmpty {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Open Quick Share on your Android device"
        }
    }

    @objc private func selectDevice(_ sender: NSButton) {
        guard !sendInFlight else { return }
        guard !urls.isEmpty,
              let id = sender.identifier?.rawValue,
              let device = devices[id] else {
            setStatus("The selected file is not ready yet")
            return
        }

        selectedDeviceID = id
        sendInFlight = true
        devicesStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = false }
        spinner.isHidden = false
        spinner.startAnimation(nil)
        progress.isHidden = false
        progress.isIndeterminate = false
        progress.doubleValue = 0
        setStatus("Connecting to \(device.name)…")
        let address = engine.dialAddress(for: device.id)
        appClient.send(files: urls, to: device.name, deviceID: device.id,
                       host: address?.host, port: address?.port)
    }

    private func restoreDeviceButtons() {
        selectedDeviceID = nil
        progress.stopAnimation(nil)
        progress.isIndeterminate = false
        progress.doubleValue = 0
        progress.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        devicesStack.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = true }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func finish(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func cancelShare() {
        appClient.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
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

private final class ShareProvider: @unchecked Sendable {
    let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }
}

private final class ShareURLResult: @unchecked Sendable {
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

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
