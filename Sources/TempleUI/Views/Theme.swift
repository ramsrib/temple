import SwiftUI
import AppKit

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
    static func color(for sessionID: String?, in model: AppModel) -> Color? {
        sessionID
            .flatMap { model.overlay.color(for: $0) }
            .flatMap(TabColorMark.init(rawValue:))?
            .color
    }

    /// A list row's fill: a marked row is a quiet wash of its colour, deeper
    /// when selected or under the pointer, so the mark you gave a tab is what
    /// you scan for in ⌘K, the ⌃⇥ switcher and ⌘Y as well as in the strip.
    /// Unmarked rows keep the neutral selection and hover fills. The sidebar
    /// row is the deliberate exception: at its density a 3pt leading bar
    /// says the same thing without tinting the whole line (`SessionRow`).
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
    static let hoverFill = mono(light: 0.0, 0.05, dark: 1.0, 0.07)

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
