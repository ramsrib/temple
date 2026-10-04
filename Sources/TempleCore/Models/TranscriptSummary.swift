import Foundation

/// Recorded transcript and session-history facts. Nil never means a placeholder.
public struct TranscriptSummary: Hashable, Sendable {
    public let id: String
    public let agent: Agent
    public let locator: TranscriptLocator
    public let modifiedAt: Date
    public let cwd: String?
    public let firstPrompt: String?
    /// Earliest recorded human prompt from Codex history.jsonl, separate from
    /// rollout facts and display-only thread names. Refreshed by enrichment reads.
    public internal(set) var historyPrompt: String?
    public let createdAt: Date?
    public let gitBranch: String?
    public let model: String?
    public let messageCount: Int?
    public let lastMessagePreview: String?
    public let originator: String?
    /// Codex's shared title for the thread: its earliest history.jsonl
    /// prompt, else the session_index.jsonl thread name. Both are recorded by
    /// the CLI, so this is a title fact (see `titleFact`).
    public let sharedTitle: String?
    /// Claude's recorded summary title, distinct from the first prompt.
    public let recordedTitle: String?
    /// Display-only hints, never persisted: Claude's lossy directory decode
    /// and Codex's prompt from a later part of the rollout.
    public let directoryHint: String?
    public let laterPromptHint: String?
    /// Claude's legacy title selection, including synthetic and top-level content.
    /// Display-only: it may not describe a prompt at all.
    public let legacyTitleHint: String?
    /// Codex's resume priority from the rollout's file name (see
    /// `TranscriptName.selectionKey`); nil for Claude and for a file whose
    /// name is not canonical.
    public let selectionKey: String?

    public init(
        id: String,
        agent: Agent,
        locator: TranscriptLocator,
        modifiedAt: Date,
        cwd: String? = nil,
        firstPrompt: String? = nil,
        historyPrompt: String? = nil,
        createdAt: Date? = nil,
        gitBranch: String? = nil,
        model: String? = nil,
        messageCount: Int? = nil,
        lastMessagePreview: String? = nil,
        originator: String? = nil,
        recordedTitle: String? = nil,
        sharedTitle: String? = nil,
        directoryHint: String? = nil,
        laterPromptHint: String? = nil,
        legacyTitleHint: String? = nil,
        selectionKey: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.locator = locator
        self.modifiedAt = modifiedAt
        self.cwd = cwd
        self.firstPrompt = firstPrompt
        self.historyPrompt = historyPrompt
        self.createdAt = createdAt
        self.gitBranch = gitBranch
        self.model = model
        self.messageCount = messageCount
        self.lastMessagePreview = lastMessagePreview
        self.originator = originator
        self.recordedTitle = recordedTitle
        self.sharedTitle = sharedTitle
        self.directoryHint = directoryHint
        self.laterPromptHint = laterPromptHint
        self.legacyTitleHint = legacyTitleHint
        self.selectionKey = selectionKey
    }
}

public extension TranscriptSummary {
    /// The title a transcript can give a row: only what the CLI recorded —
    /// Claude's summary, Codex's shared title, the first prompt, the history
    /// prompt — never a hint or a placeholder. The one chain every fill and
    /// import writes, and the head of what History and templectl display.
    var titleFact: String? { recordedTitle ?? sharedTitle ?? firstPrompt ?? historyPrompt }

    /// A catalog row's title: the recorded facts first, then display hints,
    /// then the agent's placeholder. Shown, never stored.
    var catalogTitle: String { titleFact ?? legacyTitleHint ?? laterPromptHint ?? agent.newSessionTitle }

    /// A catalog row's folder, including Claude's lossy decode as a hint.
    var catalogDirectory: String { cwd ?? directoryHint ?? "" }
}
