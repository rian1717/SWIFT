import SwiftUI
import AppKit

/// Window title on the traffic-light row. The 28pt band that aligns it with
/// the traffic lights lives here so both windows share it.
struct WindowHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .windowHeaderStyle()
            .frame(maxWidth: .infinity, minHeight: 28)
    }
}

/// Section header with an optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title).sectionStyle()
            Spacer()
            trailing()
        }
        .frame(minHeight: 19)   // fixed height so tabs share identical top geometry
        // Align the header with the card's *content*, not its outer edge — the
        // card extends further left (macOS grouped-list convention).
        .padding(.horizontal, Theme.Space.lg)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

/// A pure-SwiftUI on/off switch. Composites in a single pass, unlike the
/// AppKit switch hosted in a translucent material, which flickers.
///
/// A `ToggleStyle` rather than a view, so `Toggle` supplies keyboard
/// activation, button role and accessibility.
struct GlassToggleStyle: ToggleStyle {
    var density: Theme.Density = .regular
    var onColor: Color = Theme.switchOn
    var offColor: Color = Theme.switchOff

    func makeBody(configuration: Configuration) -> some View {
        let box = density.switchSize
        return Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(onColor) : AnyShapeStyle(offColor))
                .frame(width: box.width, height: box.height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(density.knobInset)
                        .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.72),
                           value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == GlassToggleStyle {
    static var glass: GlassToggleStyle { GlassToggleStyle() }

    static func glass(density: Theme.Density,
                      on: Color = Theme.switchOn,
                      off: Color = Theme.switchOff) -> GlassToggleStyle {
        GlassToggleStyle(density: density, onColor: on, offColor: off)
    }
}

/// Rows inside a `Card` — the one shape every list in the app uses.
///
/// Separators are overlaid on each row's bottom edge rather than inserted as
/// views, so they add no height.
struct ElementList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .bottom) {
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, 20)
                                .padding(.trailing, 4)
                        }
                    }
            }
        }
    }
}

/// A row whose state is a switch: optional icon, title, subtitle and a
/// trailing accessory before the switch.
///
/// The switch is always last and flush with the card's trailing edge, so every
/// switch in the app lines up regardless of what row it sits in.
struct ToggleElement<Accessory: View>: View {
    /// `.system` everywhere except the Receive tab's visibility row, which
    /// earns the custom glass treatment.
    enum SwitchStyle { case system, glass }

    var icon: String? = nil
    /// Neutral by default: a row icon carries no status of its own.
    var iconColor: Color = .secondary
    let title: String
    var subtitle: String? = nil
    var subtitleColor: AnyShapeStyle = AnyShapeStyle(.secondary)
    @Binding var isOn: Bool
    var density: Theme.Density = .regular
    var switchStyle: SwitchStyle = .system
    /// Glass-only: what on/off mean beyond "enabled" — e.g. red for "not
    /// trusted" rather than the default switchOn/switchOff pairing.
    var glassOnColor: Color = Theme.switchOn
    var glassOffColor: Color = Theme.switchOff
    /// VoiceOver label, when the visible title alone isn't specific enough
    /// (e.g. it should name a device the title doesn't mention).
    var accessibilityLabel: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).primaryStyle().lineLimit(1)
                if let subtitle {
                    Text(subtitle).secondaryStyle().foregroundStyle(subtitleColor)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            accessory()
            toggle
        }
        .frame(minHeight: density.rowMinHeight)
    }

    /// One `Toggle` under two styles. The row draws the visible title, so the
    /// label here is only for VoiceOver.
    @ViewBuilder private var toggle: some View {
        switch switchStyle {
        case .system:
            // The system switch assumes System Settings' larger type and
            // reads oversized against this scale, so every row shrinks it.
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(accessibilityLabel ?? title)
        case .glass:
            Toggle("", isOn: $isOn)
                .toggleStyle(.glass(density: density, on: glassOnColor, off: glassOffColor))
                .labelsHidden()
                .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

extension ToggleElement where Accessory == EmptyView {
    init(icon: String? = nil,
         iconColor: Color = .secondary,
         title: String,
         subtitle: String? = nil,
         subtitleColor: AnyShapeStyle = AnyShapeStyle(.secondary),
         isOn: Binding<Bool>,
         density: Theme.Density = .regular,
         switchStyle: SwitchStyle = .system,
         glassOnColor: Color = Theme.switchOn,
         glassOffColor: Color = Theme.switchOff,
         accessibilityLabel: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle,
                  subtitleColor: subtitleColor, isOn: isOn,
                  density: density, switchStyle: switchStyle,
                  glassOnColor: glassOnColor, glassOffColor: glassOffColor,
                  accessibilityLabel: accessibilityLabel, accessory: { EmptyView() })
    }
}

/// Default trailing affordance for `ActionElement`; a named type so the
/// generic form can default to it.
struct ActionChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A row you tap to act on: icon, title, optional subtitle, trailing view
/// (a chevron unless overridden) and a hover highlight.
struct ActionElement<Trailing: View>: View {
    let icon: String
    var iconColor: Color = Theme.accent
    let title: String
    var subtitle: String? = nil
    var subtitleColor: AnyShapeStyle = AnyShapeStyle(.secondary)
    /// Overrides the resting/hover background — e.g. a drag-and-drop target
    /// highlight. Leave nil for the default hover-only behavior.
    var tint: Color? = nil
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).primaryStyle()
                    if let subtitle {
                        Text(subtitle).secondaryStyle().foregroundStyle(subtitleColor)
                    }
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(tint ?? (hovering ? Theme.hoverFill : Color.clear))
        )
        .onHover { hovering = $0 }
    }
}

extension ActionElement where Trailing == ActionChevron {
    init(icon: String,
         iconColor: Color = Theme.accent,
         title: String,
         subtitle: String? = nil,
         subtitleColor: AnyShapeStyle = AnyShapeStyle(.secondary),
         tint: Color? = nil,
         action: @escaping () -> Void) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle,
                  subtitleColor: subtitleColor, tint: tint, action: action,
                  trailing: { ActionChevron() })
    }
}

/// The verification PIN, shown large so the user can match it to the other device.
struct PinBadge: View {
    let pin: String
    var body: some View {
        VStack(spacing: 4) {
            Text(pin)
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .tracking(6)
                .monospacedDigit()
                // Large monospaced for digit legibility.
                .foregroundStyle(Theme.textProminent)
                .contentTransition(.numericText())
            Text("Make sure this matches the code on the other device")
                .secondaryStyle()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.md)
        .cardSurface(radius: Theme.Radius.control)
    }
}
