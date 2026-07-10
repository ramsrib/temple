import Foundation
import TempleCore
import TempleTerminalAPI

/// Builds the launch command + identity for a **new** empty agent session
/// (ADR-008, ADR-012 — agent + directory only, never git/worktree).
public enum SessionLauncher {

    /// The result of preparing a new session for launch.
    public struct Spec: Equatable {
        public var sessionID: String?     // known immediately for Claude; nil (provisional) for Codex
        public var agent: Agent
        public var projectPath: String
        public var title: String
        public var command: TerminalCommand
        public var isProvisional: Bool
    }

    /// Prepare a new session.
    /// - Claude: mint a UUID → `claude --session-id <uuid>`; id known at once.
    /// - Codex: launch bare `codex`; id is adopted later by the reconciler (U4).
    public static func newSession(agent: Agent,
                                  projectPath: String,
                                  claudePath: String = "claude",
                                  codexPath: String = "codex",
                                  uuid: String = UUID().uuidString.lowercased()) -> Spec {
        switch agent {
        case .claude:
            return Spec(
                sessionID: uuid,
                agent: .claude,
                projectPath: projectPath,
                title: "New Claude session",
                command: TerminalCommand(argv: [claudePath, "--session-id", uuid], cwd: projectPath),
                isProvisional: false)
        case .codex:
            return Spec(
                sessionID: nil,
                agent: .codex,
                projectPath: projectPath,
                title: "New Codex session",
                command: TerminalCommand(argv: [codexPath], cwd: projectPath),
                isProvisional: true)
        }
    }

    /// Resume an existing session (the primary action).
    public static func resume(_ session: AgentSession) -> TerminalCommand {
        TerminalCommand(argv: session.resume.argv, cwd: session.resume.cwd)
    }
}

/// Adopts a freshly-launched Codex session's real id (ADR-008 reconcile).
///
/// `WatcherCodexReconciler` supplies the real watcher-backed implementation;
/// the protocol keeps launch-model tests deterministic.
@MainActor
public protocol CodexAdopting: AnyObject {
    /// Begin watching for the rollout file of a Codex session just started in
    /// `projectPath`; call `adopt` with the discovered id when found.
    func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void)
}

/// No-op implementation for tests that do not exercise adoption.
@MainActor
public final class NoopCodexReconciler: CodexAdopting {
    public init() {}
    public func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        // Intentionally does nothing until Track C's matcher is wired in.
    }
}
