import Foundation
import TempleCore

extension TranscriptSummary {
    var catalogTitle: String {
        sharedTitleHint ?? recordedTitle ?? legacyTitleHint ?? firstPrompt ?? historyPrompt ?? laterPromptHint
            ?? agent.newSessionTitle
    }
    var catalogDirectory: String { cwd ?? directoryHint ?? "" }
}
