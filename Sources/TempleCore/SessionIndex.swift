import Foundation

/// The project → sessions model that drives the sidebar.
public struct SessionIndex: Codable, Equatable, Sendable {
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
        FileDescriptorLimit.ensureRaised()
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

    /// Ranked, case-insensitive sidebar search. An empty query returns nothing.
    public func search(_ query: String) -> [AgentSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        let scored = allSessions.compactMap { session -> (AgentSession, Int)? in
            let title = session.title.lowercased()
            let project = URL(fileURLWithPath: session.projectPath).lastPathComponent.lowercased()
            let agentName = session.agent.displayName.lowercased()
            let agentRaw = session.agent.rawValue.lowercased()
            let score: Int
            if title == needle {
                score = 500
            } else if title.hasPrefix(needle) {
                score = 400
            } else if title.contains(needle) {
                score = 300
            } else if project.contains(needle) {
                score = 200
            } else if agentName.contains(needle) || agentRaw.contains(needle) {
                score = 100
            } else {
                return nil
            }
            return (session, score)
        }
        return scored.sorted {
            $0.1 == $1.1 ? $0.0.updatedAt > $1.0.updatedAt : $0.1 > $1.1
        }.map(\.0)
    }
}
