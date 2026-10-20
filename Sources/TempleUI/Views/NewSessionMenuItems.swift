import SwiftUI
import TempleCore

/// The agent rows shared by every `+` new-session menu — the sidebar's
/// per-project `+` and the tab strip's.
///
/// Both `+` controls already sit inside a project, so the only open question is
/// which agent, and that is all a row says. Three things follow from that:
///
/// - The agent's own mark leads the row, not another `plus`. The `+` you clicked
///   already said "new"; repeating it gave two rows that differed by one word in
///   the middle, where the eye lands last.
/// - The default agent comes first and shows `⌘T`, the other `⌥⌘T`, so the
///   menu teaches the keyboard path that makes it unnecessary. The hints appear
///   only where they are true: both start a session in the *active* project, so
///   a `+` on some other project's row shows no shortcut.
/// - An agent we have *proof* won't launch is disabled and says which kind of
///   proof. Only a failure can be proven (AGENTS.md), so there is deliberately
///   no tick, badge or reassurance on the agent that looks fine.
struct NewSessionMenuItems: View {
    @EnvironmentObject var model: AppModel
    /// The project to start in. Non-optional on purpose: a `+` with nowhere to
    /// start is not shown at all (see `TabStripTrailingCluster`), so there is no
    /// such thing here as a row disabled for want of a project.
    let project: ProjectKey

    var body: some View {
        Section("New session") {
            ForEach(orderedAgents, id: \.self) { agent in
                row(agent)
            }
        }
    }

    /// Default agent first: the row most clicks want, in the position the
    /// pointer is already closest to.
    private var orderedAgents: [Agent] {
        let preferred = model.settings.defaultAgent
        return [preferred] + Agent.allCases.filter { $0 != preferred }
    }

    @ViewBuilder
    private func row(_ agent: Agent) -> some View {
        // The project's own host answers, never this Mac's toolchain for
        // another machine.
        let availability = model.hostRegistry.entry(for: project.host)?.launcher.availability(agent)
            ?? .unavailable(reason: "no launcher for \(project.host.displayName)")
        Button {
            model.openSessions.newSession(agent: agent, project: project)
        } label: {
            Label {
                switch availability {
                case .available: Text(agent.displayName)
                case .unavailable(let reason): Text("\(agent.displayName) — \(reason)")
                }
            } icon: {
                if let image = AgentIcon.menuImage(for: agent) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "terminal")
                }
            }
        }
        .disabled(availability != .available)
        // The optional overload, so the row keeps one identity whether or not it
        // carries the shortcut.
        .keyboardShortcut(shortcut(agent))
    }

    /// `⌘T` / `⌥⌘T` are only the truth in the *active* project.
    private func shortcut(_ agent: Agent) -> KeyboardShortcut? {
        guard project == model.openSessions.activeProjectKey else { return nil }
        return agent == model.settings.defaultAgent
            ? KeyboardShortcut("t")
            : KeyboardShortcut("t", modifiers: [.command, .option])
    }
}
