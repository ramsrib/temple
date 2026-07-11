import SwiftUI
import AppKit
import TempleCore

/// The empty-state / ⌘N launcher (ADR-008/012, U4): a quiet, typographic home —
/// wordmark + tagline, a "Get started" action list (agent choice = which "New …"
/// row you pick), and a "Recent projects" list. Monochrome, list-driven; no
/// cards, segmented controls, or prominent buttons. Spawn-terminal MVP — a row
/// click opens a fresh terminal (no prompt input).
struct LauncherView: View {
    @EnvironmentObject var model: AppModel

    private let recentLimit = 5

    private var recentProjects: [Project] {
        // Noise-filtered + launch-frozen order (raw index.projects would leak
        // ambient noise like the cwd="/" codex runs into the home page).
        Array(model.displayProjects.prefix(recentLimit))
    }

    var body: some View {
        VStack {
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 30) {
                masthead
                getStarted
                if !recentProjects.isEmpty { recent }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 44)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // With no tab bar, the launcher IS the top band: its empty area behaves
        // like the native title bar (drag / double-click). Rows capture their
        // own clicks, so only the empty chrome triggers this.
        .background(WindowActionStrip())
    }

    // MARK: Masthead

    private var masthead: some View {
        HStack(spacing: 16) {
            Image(systemName: "building.columns")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Temple")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("A home for your agent sessions.")
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Get started

    private var getStarted: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionRule("Get started")

            LauncherRow(icon: .agent(.claude), title: "New Claude Code session", shortcut: "⌘T") {
                newSession(.claude)
            }
            LauncherRow(icon: .agent(.codex), title: "New Codex session") {
                newSession(.codex)
            }
            LauncherRow(icon: .symbol("folder.badge.plus"), title: "Open folder…") {
                openFolder()
            }
            LauncherRow(icon: .symbol("command"), title: "Command palette", shortcut: "⌘K") {
                model.commandPalettePresented = true
            }
            LauncherRow(icon: .symbol("gearshape"), title: "Settings", shortcut: "⌘,") {
                model.openSessions.openSettings()
            }
        }
    }

    // MARK: Recent projects

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionRule("Recent projects")

            ForEach(recentProjects) { project in
                LauncherRow(icon: .symbol("folder"),
                            title: project.name,
                            trailing: RelativeTime.string(from: project.lastActivity)) {
                    model.openSessions.newSessionDefaultAgent(projectPath: project.path)
                }
            }
        }
    }

    // MARK: Actions

    /// Start `agent` in the last-used project; if none is known, ask for a folder.
    private func newSession(_ agent: Agent) {
        if let path = model.launcherDefaultProject {
            model.openSessions.newSession(agent: agent, projectPath: path)
        } else {
            pickFolder { path in
                model.openSessions.newSession(agent: agent, projectPath: path)
            }
        }
    }

    private func openFolder() {
        pickFolder { path in
            model.openSessions.newSessionDefaultAgent(projectPath: path)
        }
    }

    private func pickFolder(_ then: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            then(url.path)
        }
    }
}

// MARK: - Row & section building blocks

/// An uppercase, letter-spaced section label trailed by a hairline rule.
private struct SectionRule: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
        }
        .padding(.bottom, 8)
    }
}

/// One home-list row: leading icon + label, optional right-aligned shortcut /
/// metadata, hover highlight. The whole row is the hit target.
private struct LauncherRow: View {
    enum Icon {
        case symbol(String)
        case agent(Agent)
    }

    let icon: Icon
    let title: String
    var shortcut: String? = nil
    var trailing: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                iconView
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Palette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        case .agent(let agent):
            AgentBadge(agent: agent, size: 15)
        }
    }
}
