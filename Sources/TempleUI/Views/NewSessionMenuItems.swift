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
/// - The default agent comes first and shows `⌘T`, so the menu teaches the
///   keyboard path that makes it unnecessary. The hint appears only where it is
///   true: `⌘T` starts a session in the *active* project, so a `+` on some other
///   project's row shows no shortcut.
/// - An agent we have *proof* won't launch is disabled and says which kind of
///   proof. Only a failure can be proven (AGENTS.md), so there is deliberately
///   no tick, badge or reassurance on the agent that looks fine.
struct NewSessionMenuItems: View {
    @EnvironmentObject var model: AppModel
    /// The project to start in. Non-optional on purpose: a `+` with nowhere to
    /// start is not shown at all (see `TabStripTrailingCluster`), so there is no
    /// such thing here as a row disabled for want of a project.
    let projectPath: String

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
        let launchable = model.toolchain.canLaunch(agent)
        Button {
            model.openSessions.newSession(agent: agent, projectPath: projectPath)
        } label: {
            Label {
                Text(launchable ? agent.displayName
                                : "\(agent.displayName) — \(problem(agent))")
            } icon: {
                if let image = AgentIcon.menuImage(for: agent) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "terminal")
                }
            }
        }
        .disabled(!launchable)
        // The optional overload, so the row keeps one identity whether or not it
        // carries the shortcut.
        .keyboardShortcut(showsShortcut(agent) ? KeyboardShortcut("t") : nil)
    }

    /// Why we know this one won't run, in the fewest words that stay true. The
    /// CLI's own account of it is in Settings and the launcher's warning banner;
    /// a menu row is the wrong place to quote a paragraph.
    private func problem(_ agent: Agent) -> String {
        if model.toolchain.argumentComplaint(for: agent) != nil { return "arguments rejected" }
        if let check = model.toolchain.overrideCheck(for: agent), !check.isUsable {
            return "command doesn't run"
        }
        // Found-but-broken is not missing: the shell reaches a `claude`, it just
        // fails to run. Saying "not found" there sends the user hunting for an
        // install they already have. `ToolchainResolution.problem` draws the same
        // line, at length; this is the short form of it.
        if let resolution = model.toolchain.resolution(for: agent), !resolution.installs.isEmpty {
            return "doesn't run"
        }
        return "not found"
    }

    /// `⌘T` is only the truth for the default agent in the *active* project.
    private func showsShortcut(_ agent: Agent) -> Bool {
        agent == model.settings.defaultAgent
            && projectPath == model.openSessions.activeProjectPath
    }
}
