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
        .init(keys: "⌘⇧[ / ⌘⇧]", action: "Previous / next project (returns to its last session)"),
    ]

    private static let navigation: [Shortcut] = [
        .init(keys: "⌘P", action: "Switch project — hold ⌘ and tap P to walk, release to land"),
        .init(keys: "⌘K", action: "Command palette (recent sessions + search)"),
        .init(keys: "⌘F", action: "Focus sidebar search"),
        .init(keys: "↑ ↓ / Return", action: "Browse the sidebar / open the highlighted session"),
        .init(keys: "⌘B", action: "Toggle the sidebar"),
    ]

    private static let app: [Shortcut] = [
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘/", action: "This panel"),
        .init(keys: "Esc", action: "Dismiss palette / dialogs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 16, weight: .semibold))

            section("Sessions & tabs", Self.sessions)
            section("Navigation", Self.navigation)
            section("App", Self.app)
        }
        .padding(28)
        .frame(width: 540)
        .panelChrome()
    }

    private func section(_ title: String, _ shortcuts: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            .padding(.bottom, 6)
            ForEach(shortcuts) { shortcut in
                HStack(spacing: 16) {
                    Text(shortcut.action)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 24)
                    keycaps(shortcut.keys)
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// "⌘⇧[ / ⌘⇧]" → keycap chips with a plain "/" between alternatives.
    private func keycaps(_ keys: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, token in
                if token == "/" {
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(String(token))
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 24)
                        .frame(height: 22)
                        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Palette.hairline))
                }
            }
        }
        .layoutPriority(1)
    }
}
