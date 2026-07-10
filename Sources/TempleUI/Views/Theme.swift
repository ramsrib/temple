import SwiftUI
import AppKit

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
}
