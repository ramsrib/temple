import Foundation
import TempleCore

// Explicit transcript facts for isolated catalog fixtures.
func catalogFixture(id: String, agent: Agent, projectPath: String, title: String,
                    createdAt: Date?, updatedAt: Date, filePath: URL,
                    messageCount: Int? = nil, model: String? = nil,
                    lastMessagePreview: String? = nil, gitBranch: String? = nil,
                    originator: String? = nil) -> TranscriptSummary {
    TranscriptSummary(id: id, agent: agent, locator: TranscriptLocator(localURL: filePath),
        modifiedAt: updatedAt, cwd: projectPath, firstPrompt: title, createdAt: createdAt,
        gitBranch: gitBranch, model: model, messageCount: messageCount,
        lastMessagePreview: lastMessagePreview, originator: originator)
}

extension TranscriptSummary {
    var title: String { titleFact ?? legacyTitleHint ?? laterPromptHint ?? (agent == .claude ? "(untitled)" : "(no prompt)") }
    var projectPath: String { cwd ?? directoryHint ?? "(unknown)" }
    var updatedAt: Date { modifiedAt }
    var filePath: URL { locator.localURL! }
    var resume: (argv: [String], cwd: String) { (agent.resumeArgv(sessionID: id), projectPath) }
}
extension EngineSnapshot {
    /// The parsed facts this snapshot authorizes, newest first.
    var allSessions: [TranscriptSummary] {
        facts.values.compactMap(\.summary).sorted { $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt }
    }
}
