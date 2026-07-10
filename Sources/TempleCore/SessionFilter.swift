import Foundation

/// Classifies ambient/automation sessions that should be hidden by default.
public enum SessionFilter {
    public static func isNoise(_ session: AgentSession) -> Bool {
        isNoise(session, pathExists: FileManager.default.fileExists(atPath:))
    }

    /// Injectable filesystem check keeps classification deterministic in tests.
    public static func isNoise(
        _ session: AgentSession,
        pathExists: (String) -> Bool
    ) -> Bool {
        if session.projectPath == "/" || !pathExists(session.projectPath) { return true }
        guard session.agent == .codex, let origin = session.originator?.lowercased() else {
            return false
        }
        return origin == "codex_exec" || origin == "codex_sdk_ts"
    }

    public static func filtered(
        _ sessions: [AgentSession],
        includeNoise: Bool
    ) -> [AgentSession] {
        includeNoise ? sessions : sessions.filter { !isNoise($0) }
    }

    public static func filtered(
        _ sessions: [AgentSession],
        includeNoise: Bool,
        pathExists: (String) -> Bool
    ) -> [AgentSession] {
        includeNoise ? sessions : sessions.filter { !isNoise($0, pathExists: pathExists) }
    }
}

public extension SessionIndex {
    func filteringNoise(includeNoise: Bool) -> SessionIndex {
        let sessions = SessionFilter.filtered(allSessions, includeNoise: includeNoise)
        let grouped = Dictionary(grouping: sessions, by: \.projectPath)
        return SessionIndex(projects: grouped.map { path, sessions in
            Project(path: path, sessions: sessions.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { $0.lastActivity > $1.lastActivity })
    }
}
