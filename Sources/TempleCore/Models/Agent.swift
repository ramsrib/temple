import Foundation

/// A CLI coding agent that Temple wraps.
public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// A session's title before the agent or the user gives it one. Short on
    /// purpose ("Claude", not "Claude Code": it sits in a narrow chip), and
    /// fixed: saved tabs carry these exact words, and the remote paths tell a
    /// placeholder from a real title by comparing against them, so a renamed
    /// one would turn every older saved placeholder into a recorded title.
    /// A change needs the old words kept as an alias in those comparisons.
    public var newSessionTitle: String {
        switch self {
        case .claude: return "New Claude session"
        case .codex: return "New Codex session"
        }
    }

    /// The command the agent installs as, before any user override or `PATH`
    /// resolution (see `LoginShellEnvironment.locate`).
    public var binaryName: String { rawValue }

    /// argv to resume a session with this agent (run in the session's `cwd`).
    ///
    /// - Note: verify against the installed CLI version before relying on it in
    ///   the launch path — both CLIs change quickly (see SESSION-FORMATS.md).
    public func resumeArgv(sessionID: String) -> [String] {
        switch self {
        case .claude: return ["claude", "--resume", sessionID]
        case .codex: return ["codex", "resume", sessionID]
        }
    }
}
