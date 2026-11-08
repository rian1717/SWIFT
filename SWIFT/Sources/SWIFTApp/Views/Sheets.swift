import AppKit
import SwiftUI

/// Accept/decline prompt for an incoming transfer. Presented as a sheet from the
/// app root, so it appears over either tab — an incoming request is never hidden.
struct IncomingRequestSheet: View {
    @Environment(AppModel.self) private var model
    let request: IncomingRequest
    /// True when we've accepted from a device using this name before.
    let isKnown: Bool
    /// Accept the current transfer. The Boolean is retained for model API
    /// compatibility and is always false.
    let onAccept: (_ alwaysAccept: Bool) -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: request.device.type.symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, Theme.Space.sm)

            VStack(spacing: 3) {
                Text("\(request.device.name) wants to send")
                    .sectionStyle()
                    .multilineTextAlignment(.center)
                Text("\(request.summary) · \(request.displaySize)")
                    .secondaryStyle()
            }

            PinBadge(pin: request.pin)

            if isKnown {
                Label("You've accepted from this device before", systemImage: "clock.arrow.circlepath")
                    .secondaryStyle()
            }

            Label("Confirm the PIN on both devices", systemImage: "lock.shield")
                .secondaryStyle()

            HStack(spacing: Theme.Space.md) {
                Button("Decline", role: .cancel, action: onDecline)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .orangeAccent()

                // Not `.defaultAction`: the sheet appears unprompted and
                // activates the app, so Return must not accept a transfer.
                Button(action: { onAccept(false) }) {
                    Text("Accept").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 290)
        .windowChrome(model.effectiveColorScheme)
    }
}

// MARK: - Build info

/// ⌘⌥I — which build is running. Build number and commit are the answer, so
/// they lead; everything else is a caption.
struct DebugInfoSheet: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    @State private var justCopied = false

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Build").secondaryStyle()

            VStack(spacing: 3) {
                Text(BuildInfo.build)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())

                Text(justCopied ? "Copied to clipboard" : BuildInfo.commit)
                    .font(.system(size: 11, design: .monospaced))
                    // Resting state reads Theme.textMuted directly (same
                    // source secondaryStyle uses); the copied-flash state is
                    // the real Theme.success signal.
                    .foregroundStyle(justCopied ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.textMuted))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .help("Click to copy build info")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Build \(BuildInfo.build), commit \(BuildInfo.commit)")
            .accessibilityHint("Copies build info to the clipboard")
            .animation(.easeInOut(duration: 0.15), value: justCopied)

            Text("\(BuildInfo.version) · built \(BuildInfo.builtAt)")
                .secondaryStyle()

            if !BuildInfo.isPackaged {
                Label("Running unpackaged (swift run) — no build stamp.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            Button("Done", action: onClose)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.orange)
                .keyboardShortcut(.cancelAction)
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
        .frame(width: 260)
        .windowChrome(model.effectiveColorScheme)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BuildInfo.summary, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
    }
}
