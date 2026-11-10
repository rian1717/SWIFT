import SwiftUI
import AppKit

/// One row in the Services card: a toggle bound to a model property.
private struct ServiceToggle: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// Longer, hover-only detail — for a caveat that matters but would make
    /// the always-visible subtitle wrap messily.
    var help: String? = nil
    let isOn: Binding<Bool>
}

/// Settings, styled to match the app: tinted glass cards, the same type system,
/// and sized to its content — the window grows and shrinks as cards like
/// Known Senders appear or their lists change, rather than a fixed height.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        // No explicit height in this chain: a plain VStack reports its real
        // intrinsic size, which is what lets `.contentSize` resizability track
        // it as cards appear. A self-measured frame feeds back and collapses.
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                section("This Mac") { nameCard }
                section("Downloads") { downloadsCard }
                section("Appearance") { appearanceCard }
                section("Services") { servicesCard }
                section("Clipboard") { clipboardCard }
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: 400)
        .ignoresSafeArea(.container, edges: .top)   // let the title sit on the traffic-light row
        .windowChrome(model.effectiveColorScheme)
    }

    private var header: some View { WindowHeader(title: "Settings") }

    /// A category label above its card, matching the grouped-list shape used
    /// everywhere else.
    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionHeader(title: title)
            content()
        }
    }

    private var nameCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveName)
                Text("Phones see this name. A model name does not replace it.")
                    .secondaryStyle()
                Button("Save", action: saveName)
                    .buttonStyle(.glass)
                    .orangeAccent()
            }
        }
        .onAppear { draft = model.deviceName }
    }

    private func saveName() { model.setDeviceName(draft) }

    private var downloadsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.downloadDirectory.path)
                        .primaryStyle().lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(.glass)
                        .orangeAccent()
                }
                Text("Received files are saved here.").secondaryStyle()
            }
        }
    }

    private var appearanceCard: some View {
        Card {
            // Same row shape as "Visible on launch": a label on the left,
            // the control right-aligned — not a full-width picker with no
            // label, which was the odd one out among these rows. Labeled
            // "Theme", not "Appearance" again — the section header already
            // says that; repeating it as the row label too was redundant.
            HStack {
                Text("Theme").primaryStyle()
                Spacer()
                Picker("", selection: Binding(
                    get: { model.appearance },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// Both background services as rows in one standard list card, so they
    /// line up exactly with every other multi-row card (e.g. Known senders).
    private var servicesCard: some View {
        var rows = [
                ServiceToggle(
                    id: "visible",
                    title: "Visible on launch",
                    subtitle: "Stay ready to receive. You do not switch to Receive each time.",
                    isOn: Binding(get: { model.startVisible },
                                  set: { model.setStartVisible($0) })),
                // Named for what it is: a local HTTP server. The swiftapp command
                // is one client of it, not the whole story.
                ServiceToggle(
                    id: "api",
                    title: "Local API server",
                    subtitle: "Lets the swiftapp command drive the app.",
                    help: "Serves 127.0.0.1:\(String(ControlServer.port)). Anything running as you can then send any file it can read.",
                    isOn: Binding(get: { model.controlAPIEnabled },
                                  set: { model.setControlAPIEnabled($0) }))
            ]
        // Offered for an installed copy only, so a build run from the project
        // folder never registers itself.
        if model.canLaunchAtLogin {
            rows.insert(ServiceToggle(
                id: "login",
                title: "Open at login",
                subtitle: model.launchAtLoginNeedsApproval
                    ? "Allow SWIFT in System Settings → General → Login Items."
                    : "SWIFT starts quietly in the menu bar when you log in.",
                isOn: Binding(get: { model.launchAtLogin },
                              set: { model.setLaunchAtLogin($0) })), at: 1)
        }
        return Card {
            ElementList(items: rows) { item in
                ToggleElement(title: item.title, subtitle: item.subtitle, isOn: item.isOn)
                    .help(item.help ?? "")
            }
        }
    }

    private var clipboardCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ToggleElement(
                    title: "Paste phone copies here",
                    subtitle: "Copy on Android, then press ⌘V on this Mac.",
                    isOn: Binding(get: { model.clipboardEnabled },
                                  set: { model.setClipboardEnabled($0) })
                )
                if model.clipboardEnabled {
                    Text(model.clipboardStatus).secondaryStyle()
                    if !model.clipboardPairingLink.isEmpty {
                        HStack(alignment: .center, spacing: Theme.Space.lg) {
                            QRCodeView(payload: model.clipboardPairingLink, size: 148)
                            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                                Text("Pairing code").primaryStyle()
                                Text(model.clipboardPairCodeSpaced)
                                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                Text("On the phone, open SWIFT and tap this Mac. The Mac asks you to allow it. Scan this code if the Mac does not appear.")
                                    .secondaryStyle()
                                Button("Copy pairing link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(model.clipboardPairingLink, forType: .string)
                                }
                                .help("Send this link to your phone and paste it into SWIFT, or type the 8-digit code instead")
                            }
                        }
                    }
                    Text("Then turn on clipboard access on the phone. If Android says that setting is restricted, open the SWIFT app page and choose Allow restricted settings. iPhone copies already paste through Apple Handoff when both devices use the same Apple ID.")
                        .secondaryStyle()
                }
            }
        }
        .onAppear { model.refreshClipboardLink() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.downloadDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.setDownloadDirectory(url)
        }
    }
}
