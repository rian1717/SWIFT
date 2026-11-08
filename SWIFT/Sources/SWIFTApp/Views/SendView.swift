import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Send flow: discover nearby devices → pick one → stage files → send.
/// Or, for a device that isn't listed: stage files → show a QR the device scans.
struct SendView: View {
    @Environment(AppModel.self) private var model
    @State private var phoneToRemove: String?
    @State private var renameTarget: String?
    @State private var renameDraft = ""
    @State private var showingAddPhone = false

    /// Whether this tab is on screen.
    ///
    /// Both tabs stay mounted (see `RootView`) and SwiftUI does not stop an
    /// indefinite animation in a view it isn't drawing, so every one here is
    /// gated on this. Finite animations need no gate.
    private var isActive: Bool { model.mode == .send }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            switch model.connection {
            case .idle:
                discoveryList
            case .staging(let device):
                stagingCard(title: "Send to \(device.name)") { sendButton }
            case .connecting(let device):
                statusCard(text: "Connecting to \(device.name)…", pin: nil)
            case .awaitingConsent(_, let pin):
                statusCard(text: "Waiting for the other device to accept…", pin: pin)
            case .qrStaging:
                stagingCard(title: "Send with QR code") { showQRButton }
            case .qrShowing(let payload):
                qrCard(payload)
            }
        }
    }

    // MARK: Discovery

    private var discoveryList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if !model.myDevices.isEmpty || !model.offlinePhoneNames.isEmpty {
                SectionHeader(title: "My devices")
                Card(padding: Theme.Space.xs) {
                    VStack(spacing: 0) {
                        ElementList(items: model.myDevices) { device in
                            HStack(spacing: 0) {
                                DeviceElement(
                                    device: device,
                                    subtitle: "Paired",
                                    action: { model.selectDevice(device) },
                                    onDropFiles: { urls in
                                        model.selectDevice(device)
                                        model.stage(urls: urls)
                                    })
                                renameButton(device.name)
                                removePhoneButton(device.name)
                            }
                        }
                        ForEach(model.offlinePhoneNames, id: \.self) { name in
                            HStack(spacing: 0) {
                                ActionElement(
                                    icon: "iphone.gen3",
                                    iconColor: Theme.textMuted,
                                    title: name,
                                    subtitle: "Open SWIFT on the phone",
                                    action: {},
                                    trailing: { EmptyView() }
                                )
                                renameButton(name)
                                removePhoneButton(name)
                            }
                        }
                    }
                }
            }

            SectionHeader(title: "Nearby devices") {
                if isActive, !model.nearbyDevices.isEmpty {
                    SearchingSymbol(size: CGSize(width: 24, height: 18), isActive: isActive)
                }
                addPhoneButton
            }

            if !model.nearbyDevices.isEmpty || (model.myDevices.isEmpty && model.offlinePhoneNames.isEmpty) {
                if model.nearbyDevices.isEmpty {
                    emptyDiscovery
                } else {
                    Card(padding: Theme.Space.xs) {
                        ElementList(items: model.nearbyDevices) { device in
                            HStack(spacing: 0) {
                                DeviceElement(device: device, action: { model.selectDevice(device) },
                                              onDropFiles: { urls in
                                                  model.selectDevice(device)
                                                  model.stage(urls: urls)
                                              })
                            }
                        }
                    }
                }
            }

            Card(padding: Theme.Space.xs) {
                ActionElement(
                    icon: "qrcode",
                    title: "Use a QR code",
                    subtitle: "For a device that can't see you over mDNS",
                    action: { model.startQRSend() })
            }
        }
        .alert(
            "Remove \(phoneToRemove ?? "this phone")?",
            isPresented: Binding(
                get: { phoneToRemove != nil },
                set: { if !$0 { phoneToRemove = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let phoneToRemove { model.forgetPhone(phoneToRemove) }
                phoneToRemove = nil
            }
            Button("Cancel", role: .cancel) { phoneToRemove = nil }
        } message: {
            Text("It leaves My devices. You can still send a file while it is nearby. Pair it again to put it back, and copies from it stop until then.")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let renameTarget { model.renameDevice(from: renameTarget, to: renameDraft) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("This name is kept on this Mac for a phone you have paired.")
        }
    }

    /// A small menu-style button. The code stays out of the way until asked for.
    private var addPhoneButton: some View {
        Button {
            model.startAddPhone()
            showingAddPhone = true
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 19)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add phone")
        .accessibilityLabel("Add phone")
        .popover(isPresented: $showingAddPhone, arrowEdge: .bottom) {
            VStack(spacing: Theme.Space.sm) {
                if let name = model.addedPhoneName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.trusted)
                    Text("Added \(name)").cardTitle()
                } else if let payload = model.addPhonePayload {
                    QRCodeView(payload: payload, size: 110)
                    Text("Scan with the phone's camera to add its real name.")
                        .secondaryStyle()
                        .multilineTextAlignment(.center)
                } else {
                    Text("The code isn't available right now.").secondaryStyle()
                }
            }
            .padding(Theme.Space.lg)
            .frame(width: 230)
            .onDisappear { model.stopAddPhone() }
        }
    }

    private func renameButton(_ name: String) -> some View {
        Button {
            renameTarget = name
            renameDraft = name
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("Rename \(name)")
        .accessibilityLabel("Rename \(name)")
    }

    private func removePhoneButton(_ name: String) -> some View {
        Button {
            phoneToRemove = name
        } label: {
            Image(systemName: "minus.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help("Remove \(name) from My devices")
        .accessibilityLabel("Remove \(name)")
    }

    private var emptyDiscovery: some View {
        VStack(spacing: Theme.Space.sm) {
            SearchingSymbol(isActive: isActive)
            Text("Looking for devices…")
                .cardTitle()
            Text("A phone appears here when Quick Share is open, or when SWIFT is open on it.")
                .secondaryStyle()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .cardSurface()
    }

    // MARK: Staging (shared by device-send and QR-send)

    private func stagingCard(title: String,
                             @ViewBuilder primary: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionHeader(title: title) {
                Button("Back") { model.cancelSend() }
                    .buttonStyle(.glass).controlSize(.small).tint(.secondary)
            }

            DropZoneView { urls in model.stage(urls: urls) }

            if !model.stagedFiles.isEmpty {
                stagedList
                primary()
            }
        }
    }

    private var sendButton: some View {
        Button(action: { model.sendStagedFiles() }) {
            Label("Send \(sendTitle)", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
    }

    private var showQRButton: some View {
        Button(action: { model.showQRCode() }) {
            Label("Show QR code", systemImage: "qrcode").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
    }

    private var stagedList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.stagedFiles) { file in
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        Text(file.name).primaryStyle().lineLimit(1)
                        Spacer()
                        Text(file.displaySize).secondaryStyle()
                        Button {
                            model.removeStaged(file)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 6)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: QR display (waiting for a scan)

    private func qrCard(_ payload: String) -> some View {
        VStack(spacing: Theme.Space.lg) {
            QRCodeView(payload: payload)

            VStack(spacing: 4) {
                Text("Scan to receive \(sendTitle.lowercased())").cardTitle()
                Text("Open the camera or Quick Share on your Android device and scan this code.")
                    .secondaryStyle()
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Space.sm) {
                if isActive { ProgressView().controlSize(.small) }
                Text("Waiting for a device to scan…").secondaryStyle()
            }

            Button("Cancel", role: .cancel) { model.cancelSend() }
                .buttonStyle(.glass).controlSize(.large).tint(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.sm)
    }

    // MARK: Status

    private func statusCard(text: String, pin: String?) -> some View {
        Card {
            VStack(spacing: Theme.Space.md) {
                if pin == nil, isActive { ProgressView() }
                Text(text).cardTitle().multilineTextAlignment(.center)
                if let pin { PinBadge(pin: pin) }
                Button("Cancel", role: .cancel) { model.cancelSend() }
                    .buttonStyle(.glass).controlSize(.large).tint(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var sendTitle: String {
        let n = model.stagedFiles.count
        return n == 1 ? "1 file" : "\(n) files"
    }
}

// MARK: - Drop zone

/// A glass panel you can drag files onto — or click anywhere to open the file
/// picker. Matches the app's other blue panels.
struct DropZoneView: View {
    let onFiles: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? Theme.accent : .secondary)
                .symbolEffect(.bounce, value: isTargeted)

            Text(isTargeted ? "Release to add" : "Drag files here")
                .cardTitle()
            Text("or click to choose")
                .secondaryStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? Theme.accent : Color.secondary.opacity(0.35))
                .padding(4)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { chooseFiles() }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFileURLs(providers) { urls in
                if !urls.isEmpty { onFiles(urls) }
            }
            return true
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

// MARK: - Device row

/// A single discovered device in the send list. An `ActionElement` — tap to
/// select it — that also accepts a drag-and-drop of files (AirDrop-style),
/// swapping its subtitle/trailing/tint to show the drop target while one is
/// dragged over it.
struct DeviceElement: View {
    let device: RemoteDevice
    var subtitle: String? = nil
    let action: () -> Void
    var onDropFiles: (([URL]) -> Void)? = nil

    @State private var dropTargeted = false

    var body: some View {
        ActionElement(
            icon: device.type.symbol,
            title: device.name,
            subtitle: dropTargeted ? "Drop to send" : (subtitle ?? device.type.rawValue.capitalized),
            subtitleColor: dropTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary),
            tint: dropTargeted ? Theme.accent.opacity(0.14) : nil,
            action: action,
            trailing: {
                Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "chevron.right")
                    .font(.system(size: dropTargeted ? 14 : 11, weight: .semibold))
                    .foregroundStyle(dropTargeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
            }
        )
        .accessibilityLabel("Send to \(device.name), \(device.type.rawValue)")
        .modifier(DropIfAvailable(enabled: onDropFiles != nil, isTargeted: $dropTargeted) { providers in
            loadDroppedFileURLs(providers) { urls in
                if !urls.isEmpty { onDropFiles?(urls) }
            }
            return true
        })
    }
}

/// Only attach an `onDrop` when a handler is supplied (avoids swallowing drops
/// on rows that don't send).
private struct DropIfAvailable: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: perform)
        } else {
            content
        }
    }
}

// MARK: - Dropped file URLs

/// Resolve dropped item providers into file URLs, then deliver on the main queue.
///
/// `loadObject` completions fire concurrently on arbitrary queues, so the
/// results are written into pre-allocated slots under a lock rather than
/// appended. Slot indexing also keeps the user's drop order, which racing
/// appends did not.
func loadDroppedFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let lock = NSLock()
    var slots = [URL?](repeating: nil, count: providers.count)
    let group = DispatchGroup()
    for (index, provider) in providers.enumerated() {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL {
                lock.lock()
                slots[index] = url
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(slots.compactMap { $0 }) }
}
