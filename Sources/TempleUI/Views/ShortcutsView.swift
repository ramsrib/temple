import SwiftUI

/// ⌘/ — a centered reference card of every keyboard shortcut. Esc or a click
/// outside dismisses (same overlay pattern as the ⌘K palette).
struct ShortcutsView: View {
    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    private static let sessions: [Shortcut] = [
        .init(keys: "⌘T", action: "New session in the current project (default agent)"),
        .init(keys: "⌘W", action: "Close the current tab (asks first if the agent is working)"),
        .init(keys: "⌘N", action: "Go to the home page"),
        .init(keys: "⌘1–9", action: "Switch to tab 1–9 in the active project"),
        .init(keys: "⌃⇥ / ⌃⇧⇥", action: "Next / previous tab"),
    ]

    private static let navigation: [Shortcut] = [
        .init(keys: "⌘K", action: "Command palette (recent sessions + search)"),
        .init(keys: "⌘F", action: "Focus sidebar search"),
        .init(keys: "↑ ↓ / Return", action: "Browse the sidebar / open the highlighted session"),
        .init(keys: "⌘B / ⌘\\", action: "Toggle the sidebar"),
    ]

    private static let app: [Shortcut] = [
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘/", action: "This panel"),
        .init(keys: "Esc", action: "Dismiss palette / dialogs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 16, weight: .semibold))

            section("Sessions & tabs", Self.sessions)
            section("Navigation", Self.navigation)
            section("App", Self.app)
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 30, y: 10)
    }

    private func section(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            ForEach(shortcuts) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(shortcut.keys)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 96, alignment: .leading)
                    Text(shortcut.action)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
