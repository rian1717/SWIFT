import SwiftUI
import AppKit

/// Design tokens. Surfaces are tinted glass — material with a restrained blue
/// wash rather than neutral grey — and adapt to light/dark.
enum Theme {

    // MARK: Colour

    static let accent = Color(red: 0.16, green: 0.51, blue: 0.96)

    /// Status. System red/green rather than fixed triples, so they follow the
    /// user's Increase Contrast and Differentiate Without Colour settings.
    /// Strictly "this worked" / "this went wrong" — anything that merely wants
    /// to look green or red uses a role token below.
    static let success = Color.green
    static let danger = Color.red

    /// Decorative accent. A different role from `danger`: nothing is wrong.
    static let orange = Color(red: 0.85, green: 0.55, blue: 0.15)

    /// Roles. Same hues as the status pair, deliberately separate tokens: an
    /// inbound transfer isn't a success, nor is a switch being on. Sharing one
    /// token would make restyling success repaint all of them.
    static let inbound = Color.green
    static let outbound = accent
    static let switchOn = Color.green
    static let switchOff = Color.red
    static let trusted = Color.green

    /// Fixed dark navy on white regardless of theme — a QR code needs constant
    /// contrast to scan.
    static let qrInk = Color(red: 0.09, green: 0.13, blue: 0.34)

    // MARK: Text

    static let textProminent: Color = .primary
    static let textMuted: Color = .secondary
    static let textWindowHeader = Color.primary.opacity(0.9)

    // MARK: Surfaces

    /// Blue lift over the window's material for cards. Cards carry no material
    /// of their own, so this does most of the work of separating one from the
    /// window; `cardBorder` only closes the shape.
    static let panelTint = dynamic(
        dark: NSColor(srgbRed: 0.14, green: 0.26, blue: 0.46, alpha: 0.22),
        light: NSColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 0.28))

    /// The same wash, fainter, for the whole window.
    static let windowTint = dynamic(
        dark: NSColor(srgbRed: 0.09, green: 0.16, blue: 0.30, alpha: 0.18),
        light: NSColor(srgbRed: 0.65, green: 0.78, blue: 0.95, alpha: 0.14))

    /// Pointer hover on any row or segment.
    static let hoverFill = Color.primary.opacity(0.06)

    /// The recessed track a segmented control's pill slides in.
    static let trackFill = Color.primary.opacity(0.05)

    /// Rules drawn *inside* a surface: row separators, expanded-transfer
    /// dividers. Applied at full strength — not scaled down at the call site.
    static let hairline = dynamic(
        dark: NSColor(white: 1, alpha: 0.08),
        light: NSColor(white: 0, alpha: 0.06))

    /// The outline separating a card from the window. Drawn at 0.5pt: one
    /// physical pixel on Retina. At 1pt it reads as a drawn border, not an edge.
    static let cardBorder = dynamic(
        dark: NSColor(white: 1, alpha: 0.14),
        light: NSColor(white: 0, alpha: 0.10))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Spacing (tightened grid)
    enum Space {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    // MARK: Radius
    enum Radius {
        static let card: CGFloat = 10
        static let control: CGFloat = 7
    }

    // MARK: Density
    /// How prominent a row is. Service-level rows are `regular`; per-item rows
    /// inside a list read as subordinate and use `compact`. Row height and
    /// switch size come from the same case so they cannot disagree.
    enum Density {
        case regular, compact

        var rowMinHeight: CGFloat {
            switch self {
            case .regular: return 34
            case .compact: return 26
            }
        }
        var switchSize: CGSize {
            switch self {
            case .regular: return CGSize(width: 34, height: 20)
            case .compact: return CGSize(width: 26, height: 15)
            }
        }
        var knobInset: CGFloat {
            switch self {
            case .regular: return 2
            case .compact: return 1.5
            }
        }
    }

}

// MARK: - Typography

extension Theme {
    /// The type scale — size and weight only. Separate from the `*Style()`
    /// helpers below, which bind a size to a colour; use these directly when a
    /// scale size is needed in a different colour rather than re-typing it.
    enum Font {
        /// Group header — most prominent.
        static let section = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Card headline.
        static let card = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Body content.
        static let body = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Muted subtext.
        static let caption = SwiftUI.Font.system(size: 10, weight: .regular)
        /// Window title on the traffic-light row.
        static let windowHeader = SwiftUI.Font.system(size: 12, weight: .light)
        /// Small glyph accents — chevrons, badge arrows, direction marks.
        static let glyph = SwiftUI.Font.system(size: 9, weight: .semibold)
    }
}

extension View {
    /// Hierarchy comes from size and weight, not colour: section, card and body
    /// text deliberately share one text colour.
    func sectionStyle() -> some View {
        font(Theme.Font.section).foregroundStyle(Theme.textProminent)
    }
    func cardTitle() -> some View {
        font(Theme.Font.card).foregroundStyle(Theme.textProminent)
    }
    func primaryStyle() -> some View {
        font(Theme.Font.body).foregroundStyle(Theme.textProminent)
    }
    func secondaryStyle() -> some View {
        font(Theme.Font.caption).foregroundStyle(Theme.textMuted)
    }
    /// Window title, sitting on the traffic-light row.
    func windowHeaderStyle() -> some View {
        font(Theme.Font.windowHeader).foregroundStyle(Theme.textWindowHeader)
    }
}

// MARK: - Button recipes

extension View {
    /// A borderless button in the app's warm accent. Both modifiers are
    /// required: `.tint` alone leaves the label black in light appearance.
    func orangeAccent() -> some View {
        tint(Theme.orange).foregroundStyle(Theme.orange)
    }
}
