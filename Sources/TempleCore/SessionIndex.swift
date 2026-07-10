import Foundation

/// The project → sessions model that drives the sidebar.
public struct SessionIndex: Sendable {
    /// Projects, most-recently-active first; sessions within each newest-first.
    public let projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }

    public var allSessions: [AgentSession] {
        projects.flatMap(\.sessions)
    }

    /// Build the index by merging every store and grouping by working directory.
    public static func build(stores: [SessionStore]) -> SessionIndex {
        let all = stores.flatMap { $0.loadSessions() }
        let grouped = Dictionary(grouping: all, by: \.projectPath)
        let projects = grouped
            .map { path, sessions in
                Project(path: path, sessions: sessions.sorted { $0.updatedAt > $1.updatedAt })
            }
            .sorted { $0.lastActivity > $1.lastActivity }
        return SessionIndex(projects: projects)
    }

    /// The default: Claude Code + Codex from the user's home directory.
    public static func buildDefault() -> SessionIndex {
        build(stores: [ClaudeSessionStore(), CodexSessionStore()])
    }
}
