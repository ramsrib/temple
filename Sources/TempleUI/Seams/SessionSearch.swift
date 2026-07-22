import Foundation
import TempleCore

/// Title-only session matching (UX "Search": sidebar filter + ⌘K palette).
///
/// `CoreSessionSearch` delegates palette ranking to TempleCore while preserving
/// the sidebar's deliberately local title-only behavior.
public protocol SessionSearch: Sendable {
    /// Filter (sidebar): keep sessions whose title matches. Empty query = all.
    func filter(_ sessions: [AgentSession], query: String) -> [AgentSession]
    /// Rank (⌘K palette): best matches first. Core ranking returns no results
    /// for an empty query. `titleOverrides` maps session id → the displayed
    /// title (rename or agent-generated) so search matches what the user
    /// sees, not only what the session file recorded.
    func rank(_ sessions: [AgentSession], query: String,
              titleOverrides: [String: String]) -> [AgentSession]
}

public extension SessionSearch {
    func rank(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        rank(sessions, query: query, titleOverrides: [:])
    }
}

public struct CoreSessionSearch: SessionSearch {
    public init() {}

    public func filter(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    public func rank(_ sessions: [AgentSession], query: String,
                     titleOverrides: [String: String]) -> [AgentSession] {
        SessionIndex(projects: [Project(path: "", sessions: sessions)])
            .search(query, titleOverrides: titleOverrides)
    }
}

public struct DefaultSessionSearch: SessionSearch {
    public init() {}

    public func filter(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    public func rank(_ sessions: [AgentSession], query: String,
                     titleOverrides: [String: String]) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        // Simple ranking: prefix match > word-boundary match > substring match.
        return sessions
            .compactMap { session -> (AgentSession, Int)? in
                let scores = [session.title, titleOverrides[session.id]]
                    .compactMap { $0.flatMap { Self.score(title: $0, query: q) } }
                guard let score = scores.max() else { return nil }
                return (session, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            .map(\.0)
    }

    static func score(title: String, query: String) -> Int? {
        let t = title.lowercased()
        let q = query.lowercased()
        guard t.contains(q) else { return nil }
        if t.hasPrefix(q) { return 3 }
        // Word-boundary hit?
        for word in t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }) {
            if word.hasPrefix(q) { return 2 }
        }
        return 1
    }
}
