import SwiftUI
import AppKit

/// App shell: header, Send/Receive switch, the active flow, and a shared list of
/// active transfers. Incoming requests are presented as a global sheet so they
/// surface regardless of the active tab.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // `@Bindable` is what produces `$model` under Observation — the
        // `@Environment` property itself is not a binding source.
        @Bindable var model = model
        return VStack(spacing: 0) {
            header
            // Inline rather than a computed property: `@Bindable` is scoped to
            // `body`, so `$model` isn't visible from one.
            ModeToggle(selection: $model.mode)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.lg)
                .padding(.bottom, Theme.Space.lg)

            // Both tabs stay mounted so the stack's height is the taller of
            // the two and switching cannot resize the window. `.top` because a
            // ZStack otherwise centres the shorter tab in the taller's height.
            ZStack(alignment: .top) {
                SendView()
                    .opacity(model.mode == .send ? 1 : 0)
                    .allowsHitTesting(model.mode == .send)
                    .accessibilityHidden(model.mode != .send)
                ReceiveView()
                    .opacity(model.mode == .receive ? 1 : 0)
                    .allowsHitTesting(model.mode == .receive)
                    .accessibilityHidden(model.mode != .receive)
            }
            .animation(.easeInOut(duration: 0.2), value: model.mode)
            .padding(.horizontal, Theme.Space.lg)

            // Capped and self-scrolling. Sizing it from the space left over
            // needs a root GeometryReader, which leaves the window's ideal
            // height undefined and defeats `.contentSize` resizability.
            if !model.transfers.isEmpty {
                TransfersList(transfers: model.transfers,
                              onClear: { model.clearFinishedTransfers() },
                              onCancel: { model.cancel($0) })
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.top, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.lg)
            }
        }
        // No `maxHeight: .infinity` — that stretches content to the window
        // instead of letting the window size to the content.
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)   // let the wordmark sit on the traffic-light row
        .windowChrome(model.effectiveColorScheme)
        .animation(.easeInOut(duration: 0.2), value: model.connection)
        // ⌘⌥I — which build am I running? Driven by the menu command so the
        // shortcut works wherever focus happens to be.
        .sheet(isPresented: $model.showingBuildInfo) {
            DebugInfoSheet { model.showingBuildInfo = false }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.transferNotice {
                TransferBanner(notice: notice, onOpen: { model.openTransferNotice() },
                               onDismiss: { model.dismissTransferNotice() })
                    .padding(Theme.Space.lg)
            }
        }
        .sheet(isPresented: incomingBinding) {
            if let req = model.incomingRequest {
                IncomingRequestSheet(
                    request: req,
                    isKnown: model.isKnown(req.device.name),
                    onAccept: { always in
                        model.respondToIncoming(accept: true, alwaysAccept: always)
                    },
                    onDecline: { model.respondToIncoming(accept: false) })
            }
        }
    }

    /// Presents the incoming sheet; dismissing it (Esc) counts as declining.
    private var incomingBinding: Binding<Bool> {
        Binding(
            get: { model.incomingRequest != nil },
            set: { presented in
                if !presented, model.incomingRequest != nil {
                    model.respondToIncoming(accept: false)
                }
            })
    }

    private var header: some View { WindowHeader(title: "SWIFT") }

}

/// Confirms a transfer finished, in the window, with one tap to the file.
private struct TransferBanner: View {
    let notice: TransferNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: notice.kind == .failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.kind == .failed ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.success))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).cardTitle()
                Text(notice.message).secondaryStyle().lineLimit(2)
            }
            Spacer(minLength: Theme.Space.sm)
            if notice.kind == .received, !notice.paths.isEmpty {
                Button("Show", action: onOpen)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if notice.kind == .received, !notice.paths.isEmpty { onOpen() }
        }
    }
}

/// Send/Receive switch: a single Apple Liquid-Glass pill that physically slides
/// under the selected segment and springs into place like a magnet snap.
struct ModeToggle: View {
    @Binding var selection: AppMode
    @State private var hovered: AppMode?
    /// Where the pill's leading edge is while a drag is in progress, in points
    /// from the left. Nil when it is resting on the selected segment.
    @State private var dragX: CGFloat?

    private static let modes = AppMode.allCases
    private static let spacing: CGFloat = 6
    /// Inset between the track's outer capsule and the segments. Both the
    /// padding below and the drag maths depend on it.
    private static let trackInset: CGFloat = 4

    var body: some View {
        // No `GlassEffectContainer`: it groups content for glass sampling,
        // which pulls the labels into what the pill refracts and renders the
        // selected word with mirrored, blurred copies. Containers are for
        // blending several glass shapes, which this has only one of.
        Group {
            HStack(spacing: Self.spacing) {
                ForEach(Self.modes) { mode in
                    segment(mode)
                }
            }
            // Behind the labels. Glass refraction includes blur and there is
            // no option separating the two, so over a 12pt label it smears the
            // text. Crisp displacement without blur needs `distortionEffect`
            // with a Metal shader instead.
            .background(alignment: .leading) { pill }
            // Measure the track itself, rather than inferring it from one
            // segment's width times the count — that assumed equal segments and
            // silently drifted if they were ever not.
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { trackWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in trackWidth = new }
                }
            }
        }
        .padding(Self.trackInset)
        .background(Capsule(style: .continuous).fill(Theme.trackFill))
        // Drag anywhere on the track to slide the pill. Simultaneous and with a
        // minimum distance, so a plain click still reaches the segment's own tap
        // underneath and only real movement starts a drag.
        .simultaneousGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .local)
                .onChanged { value in
                    guard trackWidth > 0 else { return }
                    let width = segmentWidth(in: trackWidth)
                    let step = width + Self.spacing
                    // Centre the pill on the pointer, allowing for the track
                    // inset between the gesture's space and the segments.
                    let proposed = value.location.x - Self.trackInset - width / 2
                    let x = min(max(proposed, 0), step * CGFloat(Self.modes.count - 1))
                    dragX = x
                    let nearest = Int((x / step).rounded())
                    let mode = Self.modes[min(max(nearest, 0), Self.modes.count - 1)]
                    if mode != selection { selection = mode }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) {
                        dragX = nil
                    }
                }
        )

    }

    private var pill: some View {
        GeometryReader { geo in
            let x = dragX ?? restingX(in: geo.size.width)
            Capsule(style: .continuous)
                .fill(.clear)
                // `.clear`, not `.regular`. `.regular` is the adaptive *frosted*
                // material — it blurs and lightens whatever is behind it, which
                // is what made this read as a milky blob rather than glass.
                // `.clear` is transparent: the window shows through it cleanly
                // and the lensing stays at the rim, where it belongs.
                .glassEffect(.clear.interactive(), in: Capsule(style: .continuous))
                .frame(width: segmentWidth(in: geo.size.width), height: geo.size.height)
                .offset(x: x)
                // Only animate the resting position; while dragging the pill
                // should track the pointer exactly, with no easing behind it.
                .animation(dragX == nil ? .spring(response: 0.3, dampingFraction: 0.68) : nil,
                           value: x)
                // Decoration only: sitting behind the labels, it can never
                // receive a press, which also puts `.interactive()`'s response
                // out of reach. The drag lives on the track instead.
                .allowsHitTesting(false)
        }
    }

    /// Width of the whole track, measured from the segments.
    @State private var trackWidth: CGFloat = 0

    private func segmentWidth(in total: CGFloat) -> CGFloat {
        let count = CGFloat(Self.modes.count)
        return (total - Self.spacing * (count - 1)) / count
    }

    private func restingX(in total: CGFloat) -> CGFloat {
        let index = CGFloat(Self.modes.firstIndex(of: selection) ?? 0)
        return index * (segmentWidth(in: total) + Self.spacing)
    }

    private func segment(_ mode: AppMode) -> some View {
        let isOn = selection == mode
        let isHover = hovered == mode && !isOn

        return Text(mode.rawValue)
            .font(Theme.Font.card)
            .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            // Hover shows a faint fill (like the list rows), not a color change.
            .background {
                if isHover {
                    Capsule(style: .continuous).fill(Theme.hoverFill)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.15)) {
                    if inside { hovered = mode } else if hovered == mode { hovered = nil }
                }
            }
            .onTapGesture {
                // Snappy spring with a touch of overshoot — the "magnet" settle.
                withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { selection = mode }
            }
    }
}
