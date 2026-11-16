import SwiftUI
import AppKit
import TempleCore

enum TabColorMark: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension TabColorMark {
    /// The colour a session was marked with, if any.
    @MainActor
    static func color(for session: SessionKey?, in model: AppModel) -> Color? {
        session
            .flatMap { model.overlay.color(for: $0) }
            .flatMap(TabColorMark.init(rawValue:))?
            .color
    }

    /// A list row's fill: a marked row is a quiet wash of its colour, deeper
    /// when selected or under the pointer, so the mark you gave a tab is what
    /// you scan for in ⌘K and the ⌃⇥ switcher as well as in the strip.
    /// Unmarked rows keep the neutral selection and hover fills. The sidebar
    /// and History rows are the deliberate exceptions: at their density a 3pt
    /// leading bar says the same thing without tinting the whole line.
    static func rowFill(_ mark: Color?, selected: Bool, hovering: Bool) -> Color {
        if let mark { return Palette.markWash(mark, selected: selected, hovering: hovering) }
        return selected ? Palette.selectionFill : hovering ? Palette.hoverFill : .clear
    }
}

// MARK: - Adaptive color helper

extension Color {
    /// A color that resolves differently in light vs. dark appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private func mono(light lw: CGFloat, _ la: CGFloat, dark dw: CGFloat, _ da: CGFloat) -> Color {
    Color(light: NSColor(white: lw, alpha: la), dark: NSColor(white: dw, alpha: da))
}

/// Temple's monochrome, Codex-desktop palette. One neutral near-black/gray
/// system — no blue anywhere. Semantic tokens only; tune here, never hardcode
/// grays at call sites. Every token adapts to light vs. dark.
enum Palette {
    /// App-wide tint. Neutral graphite so native controls (segmented pickers,
    /// focus rings, text cursors, toggles) render gray instead of system blue.
    static let accent = Color(light: NSColor(white: 0.34, alpha: 1),
                              dark: NSColor(white: 0.80, alpha: 1))

    /// Selected sidebar row / palette result — a subtle lighter-gray wash.
    static let selectionFill = mono(light: 0.0, 0.085, dark: 1.0, 0.13)

    /// Hover / pressed fill on interactive rows.
    /// Clearly fainter than the selection (design audit, 2026-11: at 0.05
    /// against 0.085 a row under the pointer read as a second selection).
    static let hoverFill = mono(light: 0.0, 0.03, dark: 1.0, 0.045)

    /// Neutral control fill (search field, "New session", chips).
    static let controlFill = mono(light: 0.0, 0.06, dark: 1.0, 0.08)

    /// Hairline rules and separators.
    static let hairline = mono(light: 0.0, 0.11, dark: 1.0, 0.13)

    /// A faint grouped-surface fill for cards / panels (Settings sections).
    /// Quieter than `controlFill` so nested controls read as distinct.
    static let surfaceFill = mono(light: 0.0, 0.035, dark: 1.0, 0.05)

    /// A colour mark's wash over a row, at the strength of the neutral fills
    /// it stands in for. Alphas adapt like every other token here: a fixed
    /// 24% of a saturated colour is a strong pastel on white next to the
    /// 8.5% grey selection, so a marked row read as MORE selected than the
    /// selection in light mode — the mirror of the dark-mode bug that shipped.
    static func markWash(_ mark: Color, selected: Bool, hovering: Bool) -> Color {
        let alpha: (light: Double, dark: Double) =
            selected ? (0.16, 0.26) : hovering ? (0.10, 0.15) : (0.06, 0.10)
        return Color(light: NSColor(mark).withAlphaComponent(alpha.light),
                     dark: NSColor(mark).withAlphaComponent(alpha.dark))
    }

    /// Text on `accent` (a primary button): white on light mode's graphite,
    /// near-black on dark mode's light gray, where white was unreadable.
    static let onAccent = Color(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 0.08, alpha: 1))

    /// A closed session's title in the sidebar: a clear step below the open
    /// sessions' primary, so open reads as open without a box around them
    /// (round 3; 0.82 was too faint a step to read). About 4.6:1 on the
    /// light rail and 6:1 on the dark one.
    static let closedRowText = mono(light: 0, 0.55, dark: 1, 0.52)

    /// Floating-panel surface (⌘K palette, ⌘P switcher, ⌘/ shortcuts).
    /// Opaque window background: the translucent material read as a muddy
    /// gray unrelated to the rest of the app.
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
}

/// True while a floating panel (⌘K / ⌘P / ⌘/) covers the window. Views with
/// hover fills consult it: within one window, AppKit delivers mouse-tracking
/// by RECTANGLE, ignoring z-order — without the gate a row lights up straight
/// through the panel above it.
private struct OverlayActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var overlayActive: Bool {
        get { self[OverlayActiveKey.self] }
        set { self[OverlayActiveKey.self] = newValue }
    }
}

extension View {
    /// Chrome shared by every floating panel (⌘K / ⌘P / ⌘/), so they all
    /// match the app: opaque surface, hairline edge, one soft shadow.
    func panelChrome(cornerRadius: CGFloat = 12) -> some View {
        background(Palette.panelBackground,
                   in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
    }
}

/// The app's text link: bold neutral, as History's Refresh and Settings'
/// Show output are, never the system's blue (the app's accent is neutral).
struct NeutralLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(isEnabled ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == NeutralLinkButtonStyle {
    static var neutralLink: NeutralLinkButtonStyle { NeutralLinkButtonStyle() }
}

/// A sheet's default action (Done, Add, Save): filled with the app's
/// graphite accent, never the system blue AppKit gives a default button.
/// Return still triggers it through `.keyboardShortcut(.defaultAction)`.
struct TemplePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Palette.onAccent : Color.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isEnabled ? Palette.accent : Palette.controlFill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Every other button in a Temple sheet: the neutral control fill, a step
/// deeper under the pointer.
struct TempleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isEnabled: isEnabled)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.controlFill)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && isEnabled ? Palette.hoverFill : .clear)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == TemplePrimaryButtonStyle {
    static var templePrimary: TemplePrimaryButtonStyle { TemplePrimaryButtonStyle() }
}

extension ButtonStyle where Self == TempleButtonStyle {
    static var temple: TempleButtonStyle { TempleButtonStyle() }
}

// MARK: - Panel rows

/// The one look for a row in a floating panel (⌘K, the new session picker,
/// ⌃⇥): an inset rounded fill for the selection, a fainter one under the
/// pointer, and a colour mark as the sidebar's slim bar, never a tint.
/// (Design audit, 2026-11: ⌘K and the picker lit rows edge to edge, ⌃⇥
/// inset, and a marked row was a wash in one and a bar in the other.)
struct PanelRowFill: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var mark: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(selected ? Palette.selectionFill : hovering ? Palette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                if let mark {
                    Capsule().fill(mark).frame(width: 3).padding(.vertical, 9).padding(.leading, 3)
                }
            }
            .padding(.horizontal, 8)
    }
}

extension View {
    func panelRow(selected: Bool, hovering: Bool, mark: Color? = nil) -> some View {
        modifier(PanelRowFill(selected: selected, hovering: hovering, mark: mark))
    }
}
