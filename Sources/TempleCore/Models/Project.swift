import Foundation

/// A working directory, grouping every agent session that ran in it.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var sessions: [AgentSession]

    public init(path: String, sessions: [AgentSession]) {
        self.path = path
        self.sessions = sessions
    }

    /// Last path component, e.g. `/Users/sri/Projects/active/raven` → `raven`.
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var lastActivity: Date {
        sessions.map(\.updatedAt).max() ?? .distantPast
    }
}
