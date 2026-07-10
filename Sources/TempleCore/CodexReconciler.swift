import Foundation

public struct CodexRolloutCandidate: Sendable, Equatable {
    public let sessionID: String
    public let cwd: String
    public let createdAt: Date
    public let filePath: URL

    public init(sessionID: String, cwd: String, createdAt: Date, filePath: URL) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.createdAt = createdAt
        self.filePath = filePath
    }
}

public enum CodexReconciler {
    /// Returns the sole exact-cwd candidate inside the symmetric launch window.
    /// Zero or multiple matches deliberately return nil rather than guessing.
    public static func reconcile(
        launchedCwd: String,
        launchedAt: Date,
        window: TimeInterval,
        candidates: [CodexRolloutCandidate]
    ) -> CodexRolloutCandidate? {
        guard window >= 0 else { return nil }
        let matches = candidates.filter {
            $0.cwd == launchedCwd && abs($0.createdAt.timeIntervalSince(launchedAt)) <= window
        }
        return matches.count == 1 ? matches.first : nil
    }
}
