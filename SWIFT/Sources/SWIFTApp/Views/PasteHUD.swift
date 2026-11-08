import AppKit
import SwiftUI

/// The small ring that appears while a phone copy is landing on the pasteboard.
/// Same idea as the iPhone paste indicator and the AirDrop progress circle:
/// you can see the paste happening before ⌘V.
@MainActor
final class PasteHUD {
    static let shared = PasteHUD()

    enum Phase {
        case pasting
        case done
    }

    private var panel: NSPanel?
    private var host: NSHostingView<PasteHUDView>?

    func show(phase: Phase) {
        let view = PasteHUDView(phase: phase)
        if panel == nil {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 168, height: 76)
            let panel = NSPanel(
                contentRect: host.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = host
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            self.panel = panel
            self.host = host
        } else {
            host?.rootView = view
        }
        place()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func place() {
        guard let panel, let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.maxY - size.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}

private struct PasteHUDView: View {
    let phase: PasteHUD.Phase
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: phase == .pasting ? 0.72 : 1)
                    .stroke(
                        phase == .pasting ? Theme.accent : Theme.success,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase == .pasting && spinning ? 360 : -90))
                    .animation(
                        phase == .pasting
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.2),
                        value: spinning
                    )
                Image(systemName: phase == .pasting ? "doc.on.clipboard" : "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            Text(phase == .pasting ? "Copying" : "Copied")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 168, height: 76)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { spinning = phase == .pasting }
        .onChange(of: phase) { _, newPhase in
            spinning = newPhase == .pasting
        }
    }
}
