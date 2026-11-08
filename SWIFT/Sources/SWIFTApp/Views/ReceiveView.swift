import SwiftUI
import AppKit

/// Receive flow: make the Mac visible over the network. Android then finds it by
/// name in its own Quick Share device picker. The accept/decline prompt is
/// presented globally from RootView.
struct ReceiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            // Mirrors Send's "NEARBY DEVICES" slot so content lands at the same Y.
            SectionHeader(title: "Visibility")

            visibilityCard

            if model.isVisible {
                instructions
            }
        }
    }

    private var visibilityCard: some View {
        Card {
            // Bound to intent, so it moves the instant it's clicked rather than
            // waiting on mDNS.
            ToggleElement(
                title: statusTitle,
                subtitle: statusDetail,
                subtitleColor: model.visibilityStatus == .failed
                    ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary),
                isOn: Binding(get: { model.wantsVisible }, set: { model.setVisible($0) }),
                switchStyle: .glass,
                // No colour override: the style's defaults are already the
                // green/red this toggle wants.
                accessibilityLabel: "Visible to nearby devices")
            .animation(.easeInOut(duration: 0.2), value: model.visibilityStatus)
        }
    }

    private var statusTitle: String {
        switch model.visibilityStatus {
        case .on:       return "Visible as"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .failed:   return "Couldn't become visible"
        case .off:      return "Not visible"
        }
    }

    private var statusDetail: String {
        switch model.visibilityStatus {
        case .on:       return "\(model.deviceName) · stays ready"
        case .starting: return "Announcing on the local network"
        case .stopping: return "Withdrawing from the network"
        case .failed:   return "Check that SWIFT is allowed on your local network."
        case .off:      return "Turn on to receive files"
        }
    }

    private var instructions: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("On your Android device").cardTitle()
                step(1, "Select a file and tap Share, then Quick Share.")
                step(2, "Choose “\(model.deviceName)” from the list of nearby devices.")
                step(3, "Confirm the PIN, and files land in [\(model.downloadDirectory.lastPathComponent)](swift://folder).")
            }
            .tint(Theme.orange)
            .environment(\.openURL, OpenURLAction { _ in
                NSWorkspace.shared.open(model.downloadDirectory)
                return .handled
            })
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Text("\(n)")
                .font(Theme.Font.glyph)
                // Muted badge number — same color as secondaryStyle's, kept
                // at its own small size to fit the fixed 16pt circle.
                .foregroundStyle(Theme.textMuted)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(0.08), in: Circle())
            Text(text).primaryStyle()
            Spacer(minLength: 0)
        }
    }
}
