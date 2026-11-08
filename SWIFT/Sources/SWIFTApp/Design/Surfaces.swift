import SwiftUI
import AppKit

// MARK: - Surfaces

/// A tinted panel with a hairline border. Fixed height by default; with
/// `maxHeight` set it fills to that and then scrolls.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.lg
    var maxHeight: CGFloat? = nil
    @ViewBuilder var content: Content

    @State private var metrics = ScrollMetrics()
    @State private var scrollPos = ScrollPosition(edge: .top)
    private var isScrolling: Bool { metrics.content - metrics.container > 1 }

    var body: some View {
        if let maxHeight {
            ScrollView {
                content
                    .padding(padding)
                    .padding(.trailing, isScrolling ? 12 : 0)   // clear the scrollbar
                    .background(ScrollerHider())   // suppress native scroller + its background
            }
            .scrollPosition($scrollPos)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                ScrollMetrics(offset: geo.contentOffset.y,
                              content: geo.contentSize.height,
                              container: geo.containerSize.height)
            } action: { _, new in metrics = new }
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
            .cardSurface()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(alignment: .trailing) {
                if isScrolling {
                    GlassScrollbar(offset: metrics.offset,
                                   content: metrics.content,
                                   container: metrics.container) { y in
                        scrollPos.scrollTo(y: y)
                    }
                    .padding(.trailing, 3)
                }
            }
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }
}

/// Scroll geometry `Card` tracks to drive its custom scrollbar.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var container: CGFloat = 0
}

/// Slim track with a draggable glass thumb, mirroring scroll position.
struct GlassScrollbar: View {
    let offset: CGFloat
    let content: CGFloat
    let container: CGFloat
    let scrollTo: (CGFloat) -> Void

    @State private var dragStartOffset: CGFloat?

    private var scrollable: CGFloat { max(content - container, 0) }

    var body: some View {
        GeometryReader { geo in
            let trackH = geo.size.height - 8            // small inset top/bottom
            let thumbH = max(32, trackH * (container / max(content, 1)))
            let maxThumbY = max(trackH - thumbH, 0)
            let thumbY = scrollable > 0 ? (offset / scrollable) * maxThumbY : 0

            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.10))
                    .frame(width: 3, height: trackH)

                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: 7, height: thumbH)
                    .offset(y: thumbY)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStartOffset ?? offset
                                if dragStartOffset == nil { dragStartOffset = offset }
                                let frac = maxThumbY > 0 ? value.translation.height / maxThumbY : 0
                                scrollTo(min(max(start + frac * scrollable, 0), scrollable))
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
            }
            .frame(width: 12, height: trackH, alignment: .center)
            .padding(.vertical, 4)
        }
        .frame(width: 12)
    }
}

/// Hides the native scrollers so only the glass panel and custom scrollbar
/// show. Must re-apply on layout because SwiftUI re-adds them, and with "always
/// show scroll bars" set, overlay/autohide are ignored — only
/// `hasVerticalScroller = false` hides them.
///
/// Reaches into SwiftUI's hosted `NSScrollView`, which is not API. Failure is
/// cosmetic: native scrollers reappear.
struct ScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderView { HiderView() }
    func updateNSView(_ v: HiderView, context: Context) { v.apply() }

    final class HiderView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); apply() }
        override func layout() { super.layout(); apply() }

        func apply() {
            guard let sv = enclosingScrollView else { return }
            // Idempotent: `layout()` runs constantly, and re-assigning these
            // every pass makes AppKit do teardown/setup work for no change.
            // Only touch the scroll view when it has actually drifted back.
            guard sv.hasVerticalScroller || sv.hasHorizontalScroller
                    || sv.drawsBackground || !sv.autohidesScrollers else { return }
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.drawsBackground = false
        }
    }
}

extension View {
    /// Chrome shared by every top-level surface: window wash, app tint,
    /// appearance and no focus rings.
    func windowChrome(_ colorScheme: ColorScheme) -> some View {
        self
            // Oversized rather than a plain `.background(Theme.windowTint)`:
            // a background is offered its *content's* bounds, so once the
            // window can be taller than its content the wash stopped short of
            // the top and left a visible seam against the title-bar area.
            // The window clips this to its own edges, so it always covers.
            .background {
                Rectangle().fill(Theme.windowTint)
                    .frame(width: 4000, height: 4000)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // `.ultraThinMaterial`, not `.regularMaterial`: regular is opaque
            // enough that no desktop reads through, which is the whole point
            // of putting a wash over a material in the first place.
            .containerBackground(.ultraThinMaterial, for: .window)
            .tint(Theme.accent)
            .preferredColorScheme(colorScheme)
            .focusEffectDisabled()          // mouse-only app — no keyboard focus rings
    }

    /// A tinted panel with no material of its own.
    ///
    /// Materials compound: the window already supplies one, and stacking a
    /// second makes the pair opaque regardless of thickness. Cards separate
    /// with `panelTint` and a border instead.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background { shape.fill(Theme.panelTint) }
            .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }
}
