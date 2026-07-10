import Foundation
import TempleCore

/// Title-only session matching (UX "Search": sidebar filter + ⌘K palette).
///
/// **Seam for Track C3.** The default is a local case-insensitive title match /
/// ranker; when C3's `SessionIndex.search(_:)` lands, swap in a `CoreSessionSearch`
/// adapter at the `AppModel` construction site (one line).
public protocol SessionSearch: Sendable {
    /// Filter (sidebar): keep sessions whose title matches. Empty query = all.
    func filter(_ sessions: [AgentSession], query: String) -> [AgentSession]
    /// Rank (⌘K palette): best matches first. Empty query = recency order (input order).
    func rank(_ sessions: [AgentSession], query: String) -> [AgentSession]
}

public struct DefaultSessionSearch: SessionSearch {
    public init() {}

    public func filter(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    public func rank(_ sessions: [AgentSession], query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        // Simple ranking: prefix match > word-boundary match > substring match.
        return sessions
            .compactMap { session -> (AgentSession, Int)? in
                guard let score = Self.score(title: session.title, query: q) else { return nil }
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
