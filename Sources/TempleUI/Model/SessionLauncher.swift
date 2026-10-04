import Foundation
import TempleCore
import TempleTerminalAPI

/// Builds the launch command + identity for a **new** empty agent session
/// (ADR-008, ADR-012 — agent + directory only, never git/worktree).
public enum SessionLauncher {

    /// The identity of a new session, before any host builds its command.
    public struct Spec: Equatable {
        public var sessionID: String?     // known immediately for Claude; nil (provisional) for Codex
        public var agent: Agent
        public var projectPath: String
        public var title: String
        public var isProvisional: Bool
    }

    /// Prepare a new session.
    /// - Claude: mint a UUID (the launcher passes `--session-id`); id known at once.
    /// - Codex: launch bare; the id is adopted later by the reconciler (U4).
    public static func newSession(agent: Agent, projectPath: String,
                                  uuid: String = UUID().uuidString.lowercased()) -> Spec {
        switch agent {
        case .claude:
            return Spec(sessionID: uuid, agent: .claude, projectPath: projectPath,
                        title: Agent.claude.newSessionTitle, isProvisional: false)
        case .codex:
            return Spec(sessionID: nil, agent: .codex, projectPath: projectPath,
                        title: Agent.codex.newSessionTitle, isProvisional: true)
        }
    }

    public static func resumeArgv(_ session: Session) -> [String] {
        guard session.canResume, let agent = session.agent else { return [] }
        return agent.resumeArgv(sessionID: session.id)
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
    func reconcile(host: HostID, projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void)
    func transcriptPath(for sessionID: String) -> URL?
}

public extension CodexAdopting {
    func reconcile(host: HostID, projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        if host.isLocal { reconcile(projectPath: projectPath, startedAt: startedAt, adopt: adopt) }
    }
    func transcriptPath(for sessionID: String) -> URL? { nil }
}

/// No-op implementation for tests that do not exercise adoption.
@MainActor
public final class NoopCodexReconciler: CodexAdopting {
    public init() {}
    public func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        // Intentionally does nothing until Track C's matcher is wired in.
    }
}
