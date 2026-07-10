import Foundation

/// A single resumable agent session, discovered on disk.
public struct AgentSession: Codable, Identifiable, Hashable, Sendable {
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
    /// Best-effort count of turn-bearing records in the bounded head/tail windows.
    public let messageCount: Int?
    /// Most recently observed model identifier/provider.
    public let model: String?
    /// Cleaned snippet from the most recent human or assistant message.
    public let lastMessagePreview: String?
    /// Read-only branch metadata recorded by the CLI.
    public let gitBranch: String?
    /// CLI launch origin, when recorded (primarily Codex).
    public let originator: String?

    public init(
        id: String,
        agent: Agent,
        projectPath: String,
        title: String,
        createdAt: Date?,
        updatedAt: Date,
        filePath: URL,
        messageCount: Int? = nil,
        model: String? = nil,
        lastMessagePreview: String? = nil,
        gitBranch: String? = nil,
        originator: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.projectPath = projectPath
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.messageCount = messageCount
        self.model = model
        self.lastMessagePreview = lastMessagePreview
        self.gitBranch = gitBranch
        self.originator = originator
    }

    /// Decodes caches defensively so additive model evolution can preserve old
    /// snapshots instead of making startup depend on a cache migration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        agent = try container.decodeIfPresent(Agent.self, forKey: .agent) ?? .claude
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        filePath = try container.decodeIfPresent(URL.self, forKey: .filePath)
            ?? URL(fileURLWithPath: "")
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        originator = try container.decodeIfPresent(String.self, forKey: .originator)
    }

    /// argv + working directory to resume this session in a terminal surface.
    public var resume: (argv: [String], cwd: String) {
        (agent.resumeArgv(sessionID: id), projectPath)
    }
}
