import Foundation

/// A single resumable agent session, discovered on disk.
public struct AgentSession: Identifiable, Hashable, Sendable {
    public let id: String
    public let agent: Agent
    /// The true working directory the session ran in (read from file contents).
    public let projectPath: String
    /// Human-readable title — typically the first user prompt.
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date
    /// The session file on disk (`.jsonl`).
    public let filePath: URL

    public init(
        id: String,
        agent: Agent,
        projectPath: String,
        title: String,
        createdAt: Date?,
        updatedAt: Date,
        filePath: URL
    ) {
        self.id = id
        self.agent = agent
        self.projectPath = projectPath
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
    }

    /// argv + working directory to resume this session in a terminal surface.
    public var resume: (argv: [String], cwd: String) {
        (agent.resumeArgv(sessionID: id), projectPath)
    }
}
