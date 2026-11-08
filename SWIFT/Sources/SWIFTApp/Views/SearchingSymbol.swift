import SwiftUI
import AppKit

/// The "looking for devices" mark: arc pairs launched from a central source,
/// expanding outward and fading. Drawn at two sizes — the empty discovery card
/// and, once devices are found, the Nearby devices header.
///
/// **Everything is pre-drawn; only `opacity` and `transform` animate.** That
/// constraint is the design, not an optimisation. This window is a translucent
/// material over the desktop, so any per-frame redraw recomposites it: on the
/// idle Send tab a SwiftUI `.symbolEffect` measured 5.4% of a CPU core against
/// 0.16% for this, and the cost barely moved with how much was animated —
/// what costs is the per-frame trip through the view graph. Layer animations
/// run in the render server, so elaborateness here is free. Measure any
/// change; a plain `ProgressView` is the reference for "free".
struct SearchingSymbol: View {
    /// How big to draw it. The geometry derives from the view's bounds, so the
    /// same code serves the empty-state mark and the header one.
    var size = CGSize(width: 58, height: 52)
    /// False when the Send tab isn't the visible one. SwiftUI does not stop an
    /// indefinite animation in a view it isn't drawing, and both tabs stay
    /// mounted so switching between them can't resize the window.
    var isActive: Bool

    var body: some View {
        Cascade(isActive: isActive)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)   // "Looking for devices…" already says this
    }
}

// MARK: - Shared

private enum Art {
    /// The source dot at the centre of the mark.
    static func dotLayer(radius: CGFloat, centre: CGPoint, tint: NSColor) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                            width: radius * 2, height: radius * 2),
                          transform: nil)
        dot.fillColor = tint.cgColor
        return dot
    }
}

// MARK: - Cascade

/// Arc pairs launched from the centre one after another, growing outward and
/// fading.
///
/// Adapts rather than shrinks. At full size, three expanding waves; below
/// `compactBelow` there is too little radius for spacing and travel to read,
/// so it drops to the source plus one arc pair lighting in turn, no expansion.
private struct Cascade: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> ArtView { ArtView() }
    func updateNSView(_ view: ArtView, context: Context) {
        view.tint = NSColor(Theme.accent)
        view.setAnimating(isActive)
    }

    /// Layer-backed: draws once, then animates properties only.
    final class ArtView: NSView {
        private var waves: [CALayer] = []
        private var source = CAShapeLayer()
        private var compact = false
        private var animating = false

        var tint: NSColor = .systemBlue {
            didSet { if tint != oldValue { rebuildAndRestart() } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            rebuildAndRestart()
        }

        func setAnimating(_ on: Bool) {
            guard on != animating else { return }
            animating = on
            if on { addAnimations() } else { removeAnimations() }
        }

        private func rebuildAndRestart() {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            build()
            if animating { addAnimations() }
        }

        private static let waveCount = 3
        private static let period: CFTimeInterval = 3.1
        /// Below this, there is not enough radius for expanding waves to read.
        private static let compactBelow: CGFloat = 30
        /// Waves are drawn at a fraction of the space available and then scaled
        /// past it, so they carry on travelling outward instead of stopping at
        /// the radius they were drawn at.
        private static let drawnFraction = 0.82
        private static let finalScale = 1.0 / 0.82

        // Compact form.
        private static let compactPeriod: CFTimeInterval = 1.7
        private static let compactStagger = 0.30
        private static let compactRise = 0.07
        private static let compactDecay = 0.42
        /// Kept clearly visible at rest: at this size a part that fades out
        /// entirely just looks like it is missing.
        private static let compactResting: Float = 0.3

        private func build() {
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let extent = min(bounds.width, bounds.height)
            compact = extent < Self.compactBelow

            let outer = extent / 2 - (compact ? 1 : 2)
            guard outer > 0 else { return }
            let radius = compact ? outer : outer * Self.drawnFraction
            let stroke = max(1.0, radius * (compact ? 0.14 : 0.085))
            let span = CGFloat.pi / 4.6            // a touch under ±40°

            func arcPair(at radius: CGFloat) -> CALayer {
                let pair = CALayer()
                pair.frame = bounds
                for mid in [CGFloat(0), CGFloat.pi] {   // right side, then left
                    let arc = CAShapeLayer()
                    let path = CGMutablePath()
                    path.addArc(center: centre, radius: radius,
                                startAngle: mid - span, endAngle: mid + span,
                                clockwise: false, transform: .identity)
                    arc.path = path
                    arc.frame = bounds
                    arc.fillColor = nil
                    arc.strokeColor = tint.cgColor
                    // Thin: the layer transform scales the stroke too, so a
                    // heavy wave ends up heavier still at full size.
                    arc.lineWidth = stroke
                    arc.lineCap = .round               // soft ends, not cut off
                    pair.addSublayer(arc)
                }
                layer?.addSublayer(pair)
                return pair
            }

            if compact {
                waves = [arcPair(at: radius)]
                waves.forEach { $0.opacity = Self.compactResting }
            } else {
                waves = (0..<Self.waveCount).map { _ in
                    let pair = arcPair(at: radius)
                    pair.opacity = 0
                    return pair
                }
            }

            // Its own layer so it can flash as each wave leaves.
            source = Art.dotLayer(radius: max(1.3, radius * (compact ? 0.20 : 0.135)),
                                  centre: centre, tint: tint)
            layer?.addSublayer(source)
        }

        private func addAnimations() {
            compact ? addCompactAnimations() : addFullAnimations()
        }

        /// Source and arc pair lighting in turn, no expansion.
        private func addCompactAnimations() {
            let start = CACurrentMediaTime()
            let parts: [CALayer] = [source] + waves

            for (index, part) in parts.enumerated() {
                let onset = Double(index) * Self.compactStagger
                let peak  = min(onset + Self.compactRise, 0.95)
                let done  = min(peak + Self.compactDecay, 0.97)

                // keyTimes must span 0...1 or Core Animation discards the
                // schedule silently, which looks like a missing fade.
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values   = [Self.compactResting, Self.compactResting,
                                  1, Self.compactResting, Self.compactResting]
                pulse.keyTimes = [0,
                                  NSNumber(value: onset),
                                  NSNumber(value: peak),
                                  NSNumber(value: done),
                                  1]
                pulse.timingFunctions = [
                    CAMediaTimingFunction(name: .linear),
                    CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .linear),
                    CAMediaTimingFunction(name: .linear)
                ]
                pulse.duration = Self.compactPeriod
                pulse.beginTime = start
                pulse.repeatCount = .greatestFiniteMagnitude
                part.add(pulse, forKey: "radiate")
            }
        }

        /// Three waves launched from the centre, expanding and fading.
        private func addFullAnimations() {
            let start = CACurrentMediaTime()
            for (index, wave) in waves.enumerated() {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                // Starts tight to the dot, so there is as much travel as the
                // space allows before it fades.
                grow.fromValue = 0.16
                grow.toValue = Self.finalScale

                // Full strength at the peak, then held past halfway so the
                // wave is still visible at its widest.
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values   = [0.0, 1.0, 0.72, 0.0]
                fade.keyTimes = [0, 0.16, 0.62, 1]

                let group = CAAnimationGroup()
                group.animations = [grow, fade]
                group.duration = Self.period
                group.beginTime = start + Double(index) * Self.period / Double(Self.waveCount)
                group.repeatCount = .greatestFiniteMagnitude
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.fillMode = .backwards
                wave.add(group, forKey: "cascade")
            }

            // One flash per wave. Never to zero: the source pulses, not blinks.
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values   = [1.0, 0.62, 1.0]
            flash.keyTimes = [0, 0.22, 1]
            flash.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            flash.duration = Self.period / Double(Self.waveCount)
            flash.beginTime = start
            flash.repeatCount = .greatestFiniteMagnitude
            source.add(flash, forKey: "emit")
        }

        private func removeAnimations() {
            layer?.sublayers?.forEach { $0.removeAllAnimations() }
            source.opacity = 1
            waves.forEach { $0.opacity = compact ? 1 : 0 }
        }
    }
}
