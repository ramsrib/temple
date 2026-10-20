import SwiftUI
import TempleCore

/// ⌘/ — a centered reference card of every keyboard shortcut. Esc or a click
/// outside dismisses (same overlay pattern as the ⌘K palette).
struct ShortcutsView: View {
    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    /// The agents by name, not "default" and "the other": a line read
    /// alone must say which agent it starts (cold read, docs/copy-review.md).
    var defaultAgent: Agent = .claude
    var otherAgent: Agent = .codex

    private var sessions: [Shortcut] {
        let usual = defaultAgent.displayName, other = otherAgent.displayName
        return [
            .init(keys: "⌘T", action: "New \(usual) session in the current project"),
            .init(keys: "⌥⌘T", action: "New \(other) session in the current project"),
            .init(keys: "⌘N", action: "New \(usual) session in a project you pick"),
            .init(keys: "⌥⌘N", action: "New \(other) session in a project you pick"),
        ] + Self.tabs
    }

    private static let tabs: [Shortcut] = [
        .init(keys: "⌘W", action: "Close the current tab (asks first if the agent is working)"),
        .init(keys: "⌘⇧T", action: "Reopen the last closed tab"),
        .init(keys: "⌘O", action: "Open a project folder Temple hasn't seen yet"),
        .init(keys: "⌘⇧H", action: "Go to the home page"),
        .init(keys: "⌘⇧[ / ⌘⇧]", action: "Previous / next tab"),
        .init(keys: "⌘1–8", action: "Switch to session 1–8 in the current project"),
        .init(keys: "⌘9", action: "Switch to the current project's last session"),
        .init(keys: "⌃⇥ / ⌃⇧⇥", action: "Last visited tab — hold ⌃ to walk the list, ⇧ reverses"),
        .init(keys: "⌘F", action: "Find in the terminal"),
        .init(keys: "⌘G / ⌘⇧G", action: "Next / previous match (Return / ⇧Return in the find field)"),
    ]

    private static let navigation: [Shortcut] = [
        .init(keys: "⌘P", action: "Switch project — hold ⌘ and tap P to walk, release to land"),
        .init(keys: "⌥⌘[ / ⌥⌘]", action: "Previous / next project (returns to its last session)"),
        .init(keys: "⌘K / ⌘⇧P", action: "Command palette (recent sessions + search)"),
        .init(keys: "⌘Y", action: "Session history"),
        .init(keys: "⌘⇧Y", action: "Archived sessions, in History"),
        .init(keys: "↑ ↓ / Return", action: "Browse the sidebar / open the highlighted session"),
        .init(keys: "⌘B", action: "Toggle the sidebar"),
    ]

    private static let history: [Shortcut] = [
        .init(keys: "⌘F", action: "Search History"),
        .init(keys: "⌘A", action: "Select every row in the list"),
        .init(keys: "⌘I", action: "Import the selection into the sidebar"),
        .init(keys: "⌘C", action: "Copy the selection's resume commands"),
        .init(keys: "⌘⌫", action: "Archive the selection"),
        .init(keys: "⌘Z", action: "Undo an import, archive or restore"),
    ]

    private static let app: [Shortcut] = [
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘R", action: "Refresh History's list; on Settings, check for \(Agent.allCases.map(\.displayName).joined(separator: " and ")) again"),
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
    /// A host is enabled: one line on how scrolling works in sessions
    /// there (tmux owns their scrollback). Absent otherwise.
    var remoteNote = false

    static let remoteScrollingNote = RemoteCopy.scrollingNote

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 16, weight: .semibold))
                .padding([.horizontal, .top], 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Sessions & tabs", sessions)
                    section("Navigation", Self.navigation)
                    section("On the History tab", Self.history)
                    section("App", Self.app)
                    if remoteNote {
                        Text(Self.remoteScrollingNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
