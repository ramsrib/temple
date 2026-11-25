import Foundation

/// A CLI coding agent that Temple wraps.
public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    /// Google's Antigravity CLI, `agy` (ADR-043): Gemini models in a terminal.
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
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
        case .antigravity: return "New Antigravity session"
        }
    }

    /// A title that names nothing: the placeholder above, or the title the
    /// agent's terminal carries before it has one of its own, its command
    /// and its folder ("claude: storefront"). A row of those could not be
    /// told from the next, and repeated the badge beside it and the project
    /// above it (design audit, 2026-11). Shown as `Session.untitled`.
    public func isPlaceholderTitle(_ title: String, directory: String?) -> Bool {
        if title == newSessionTitle { return true }
        guard let directory, !directory.isEmpty else { return false }
        // The path's text only. `URL(fileURLWithPath:)` asks the disk whether
        // the path is a folder (an lstat), and this runs for every row on
        // every redraw: it made each step of a switcher take hundreds of
        // disk calls on the main thread.
        let folder = (directory as NSString).lastPathComponent
        return title.caseInsensitiveCompare("\(binaryName): \(folder)") == .orderedSame
    }

    /// The agent mints the session's id itself (Codex, and Antigravity at
    /// the first prompt): a new session starts without one, and Temple
    /// learns it afterwards. Claude takes the id Temple hands it
    /// (`--session-id`).
    public var mintsOwnID: Bool { self != .claude }

    /// The agents a row with no agent recorded can be: such rows predate
    /// Temple recording one (ADR-029), and Antigravity came later (ADR-043),
    /// so its absence is never needed for them. Asking for it would leave
    /// every such row unprovable on a Mac without `agy`.
    public static let agentlessRowAgents: [Agent] = [.claude, .codex]

    /// The command the agent installs as, before any user override or `PATH`
    /// resolution (see `LoginShellEnvironment.locate`).
    public var binaryName: String {
        switch self {
        case .claude, .codex: return rawValue
        case .antigravity: return "agy"
        }
    }

    /// argv to resume a session with this agent (run in the session's `cwd`).
    ///
    /// - Note: verify against the installed CLI version before relying on it in
    ///   the launch path — both CLIs change quickly (see SESSION-FORMATS.md).
    public func resumeArgv(sessionID: String) -> [String] {
        switch self {
        case .claude: return ["claude", "--resume", sessionID]
        case .codex: return ["codex", "resume", sessionID]
        case .antigravity: return ["agy", "--conversation", sessionID]
        }
    }
}
