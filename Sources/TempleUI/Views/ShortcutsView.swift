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
        .init(keys: "⌘⇧T", action: "Reopen the last closed tab"),
        .init(keys: "⌘N", action: "New session in a project you pick (default agent)"),
        .init(keys: "⌘⇧N", action: "Same picker, the other agent"),
        .init(keys: "⌘O", action: "Open a project folder Temple hasn't seen yet"),
        .init(keys: "⌘⇧H", action: "Go to the home page"),
        .init(keys: "⌘1–9", action: "Switch to tab 1–9 in the active project"),
        .init(keys: "⌃⇥ / ⌃⇧⇥", action: "Last visited tab — hold ⌃ to walk the list, ⇧ reverses"),
        .init(keys: "⌘⇧[ / ⌘⇧]", action: "Previous / next project (returns to its last session)"),
        .init(keys: "⌘F", action: "Find in the terminal"),
        .init(keys: "⌘G / ⌘⇧G", action: "Next / previous match (Return / ⇧Return in the find field)"),
    ]

    private static let navigation: [Shortcut] = [
        .init(keys: "⌘P", action: "Switch project — hold ⌘ and tap P to walk, release to land"),
        .init(keys: "⌘K", action: "Command palette (recent sessions + search)"),
        .init(keys: "⌘Y", action: "Session history"),
        .init(keys: "⌘⇧Y", action: "Archived sessions, in History"),
        .init(keys: "↑ ↓ / Return", action: "Browse the sidebar / open the highlighted session"),
        .init(keys: "⌘B", action: "Toggle the sidebar"),
    ]

    private static let app: [Shortcut] = [
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘/", action: "This panel"),
        .init(keys: "Esc", action: "Dismiss palette / dialogs / find bar"),
        .init(keys: "⌘Q", action: "Quit — closing the window does the same; asks if an agent is working"),
    ]

    /// The tallest the card may be: the window's height less a margin. The
    /// card is about 900 pt tall, and unbounded in a 653 pt window it lost
    /// both ends off the window and grew the window-level stack it floats
    /// in, which pushed the split view (sidebar, History) up under the
    /// traffic lights. Bounded, it keeps its natural height when that fits
    /// and scrolls its sections when it does not.
    var maxHeight: CGFloat = .infinity

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 16, weight: .semibold))
                .padding([.horizontal, .top], 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Sessions & tabs", Self.sessions)
                    section("Navigation", Self.navigation)
                    section("App", Self.app)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .thinScrollers()
        }
        .frame(width: 540)
        // A flexible frame clamps the card's ideal height, which is what the
        // panel's hosting view sizes itself by: min(natural, maxHeight), with
        // nothing measured.
        .frame(maxHeight: maxHeight)
        .panelChrome()
    }

    /// The margin kept between the card and the window's top and bottom.
    static let windowMargin: CGFloat = 24

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
