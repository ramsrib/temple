import Foundation
import TempleCore

extension TranscriptSummary {
    var catalogTitle: String {
        sharedTitleHint ?? recordedTitle ?? legacyTitleHint ?? firstPrompt ?? historyPrompt ?? laterPromptHint
            ?? "New \(agent.displayName) session"
    }
    var catalogDirectory: String { cwd ?? directoryHint ?? "" }
}
