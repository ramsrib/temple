import Foundation

/// Classifies ambient/automation sessions that should be hidden by default.
public enum SessionFilter {
    public static func isNoise(_ session: TranscriptSummary) -> Bool {
        isNoise(session) { session.locator.host.isLocal ? FileManager.default.fileExists(atPath: $0) : true }
    }

    /// Injectable filesystem check keeps classification deterministic in tests.
    public static func isNoise(
        _ session: TranscriptSummary,
        pathExists: (String) -> Bool
    ) -> Bool {
        if (session.cwd ?? session.directoryHint ?? "") == "/" || !pathExists((session.cwd ?? session.directoryHint ?? "")) { return true }
        guard session.agent == .codex, let origin = session.originator?.lowercased() else {
            return false
        }
        return origin == "codex_exec" || origin == "codex_sdk_ts"
    }

    public static func filtered(
        _ sessions: [TranscriptSummary],
        includeNoise: Bool
    ) -> [TranscriptSummary] {
        includeNoise ? sessions : sessions.filter { !isNoise($0) }
    }

    public static func filtered(
        _ sessions: [TranscriptSummary],
        includeNoise: Bool,
        pathExists: (String) -> Bool
    ) -> [TranscriptSummary] {
        includeNoise ? sessions : sessions.filter { !isNoise($0, pathExists: pathExists) }
    }
}
