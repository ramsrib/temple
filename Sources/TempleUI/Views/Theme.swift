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

    /// A menu swatch that stays colored. SF-symbol Label icons get template-
    /// rendered by NSMenu, so a `foregroundStyle` tint comes out monochrome —
    /// a drawn, non-template NSImage is the only reliable way to put real
    /// color in a context-menu item. The ring marks the current selection.
    func menuSwatch(selected: Bool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            if selected {
                NSColor.labelColor.withAlphaComponent(0.8).setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
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
