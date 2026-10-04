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
/// `CodexAdopter` asks the owning host's source; the protocol keeps
/// launch-model tests deterministic.
@MainActor
public protocol CodexAdopting: AnyObject {
    /// Begin watching for the rollout file of a Codex session just started in
    /// `projectPath` on `host`; call `adopt` with the discovered id and the
    /// rollout it was found in.
    func reconcile(host: HostID, projectPath: String, startedAt: Date,
                   adopt: @escaping (_ id: String, _ locator: TranscriptLocator?) -> Void)
}

/// Adoption through the owning host's source (`HostSessionSource.adopt`):
/// the one rollout header in the launch window for that folder, or nothing.
@MainActor
public final class CodexAdopter: CodexAdopting {
    private let registry: HostRegistry
    private let window: TimeInterval
    public init(registry: HostRegistry, window: TimeInterval = 5) {
        self.registry = registry; self.window = window
    }
    public func reconcile(host: HostID, projectPath: String, startedAt: Date,
                          adopt: @escaping (String, TranscriptLocator?) -> Void) {
        guard let source = registry.entry(for: host)?.source else { return }
        let request = AdoptionRequest(directory: projectPath, startedAt: startedAt, window: window)
        Task {
            let result = try? await source.adopt(request)
            guard !Task.isCancelled, case .adopted(let id, let locator) = result, locator.host == host else { return }
            adopt(id, locator)
        }
    }
}

/// No-op implementation for tests that do not exercise adoption.
@MainActor
public final class NoopCodexReconciler: CodexAdopting {
    public init() {}
    public func reconcile(host: HostID, projectPath: String, startedAt: Date,
                          adopt: @escaping (String, TranscriptLocator?) -> Void) {}
}
