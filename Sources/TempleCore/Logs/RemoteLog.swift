import Foundation
import os

/// Sessions on hosts, as they live and drop: every remote tab's client exit
/// (with ssh's own status), the host's verdict on the run, each automatic
/// reattach, retry and give-up, and each refused or stale result, one
/// timestamped line each, to the unified log and to
/// `<state dir>/logs/remote.log`.
///
/// The file exists for the report "after my Mac slept the remote tab broke
/// and only a relaunch fixed it" (2026-11-16): nothing in Temple recorded
/// what happened, so the report could not be traced. A line names the host
/// and the run's handle, never terminal contents, a command line or a
/// credential. The file lives under `TempleState.directory`, so a demo run
/// writes its own copy.
public enum RemoteLog {
    /// Where the file goes: nil until the app sets it at launch, in both
    /// entry points (AGENTS.md, "Two entry points"). Tests that want the
    /// file set it themselves.
    public nonisolated(unsafe) static var fileURL: URL?
    public static var defaultFileURL: URL {
        TempleState.directory.appendingPathComponent("logs/remote.log")
    }
    static let capBytes = 512 * 1024

    private static let logger = Logger(subsystem: "com.sriramb.temple.remote", category: "lifecycle")
    private static let queue = DispatchQueue(label: "com.sriramb.temple.remote-log", qos: .utility)
    private nonisolated(unsafe) static var reportedFailure: String?

    /// A transition worth keeping: persisted by the unified log too.
    public static func notice(_ message: String) {
        let line = redacted(message)
        logger.notice("\(line, privacy: .public)")
        append("notice", line)
    }

    /// Something went wrong on the way (a refused open, a stale verdict).
    public static func error(_ message: String) {
        let line = redacted(message)
        logger.error("\(line, privacy: .public)")
        append("error", line)
    }

    /// Lines carry an error's own words (ssh's, tmux's, the socket
    /// directory's), which can name local or remote paths: a home folder
    /// is a person's name, a key path says where their keys are. Every
    /// path is cut to `<path>` before either sink sees it; the host and the
    /// run's handle, which carry neither, stay.
    static func redacted(_ message: String) -> String {
        var text = message
        // The home folder first, whole, spaces and all ("/Users/Jane Doe"):
        // the general pattern below stops at a space.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, home != "/" { text = text.replacingOccurrences(of: home, with: "~") }
        // Secrets first, while the URLs and assignments that carry them are
        // whole: ssh's first stderr line can be a failing ProxyCommand's,
        // naming a URL with a password or a token in it.
        for (pattern, template) in secrets {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        for pattern in [quotedPath, barePath] {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<path>")
        }
        return text
    }

    /// What can carry a credential in an error's words: a URL's user and
    /// password, a URL's query, a `Bearer` token, and a value assigned to a
    /// name that says it is one (`token=`, `api_key: `, `--password `).
    /// Best effort, as any pattern is; the host and handle never match.
    private static let secrets: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@'"]+@"#), "$1<redacted>@"),
        (try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+.-]*://[^\s?'"]*)\?[^\s'"]*"#), "$1?<redacted>"),
        (try! NSRegularExpression(pattern: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#), "$1 <redacted>"),
        // `name=value`, `name: value`, JSON's `"name": "value"`, and a
        // command line's `--name value`, the value bare or quoted; never a
        // plain word after the name ("authentication failed" stays).
        (try! NSRegularExpression(
            pattern: #"(?i)\b([\w-]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|auth|credential|signature)[\w-]*['"]?)(\s*[=:]\s*)(?!<redacted>|(?:bearer|basic)\s)(?:"[^"]*"|'[^']*'|[^\s'",;}]+)"#),
         "$1$2<redacted>"),
        (try! NSRegularExpression(
            pattern: #"(?i)(--[\w-]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|auth|credential|signature)[\w-]*)(\s+)(?!-)(?:"[^"]*"|'[^']*'|[^\s'",;]+)"#),
         "$1$2<redacted>"),
    ]

    /// A quoted path, spaces included: `'/Users/Jane Doe/.ssh/id'`,
    /// `"~/My Keys/id"`. The quotes stay; what is inside goes.
    private static let quotedPath = try! NSRegularExpression(
        pattern: #"(?<=['"])(?:~/|/)[^'"]*(?=['"])"#)
    /// `~/…` or an absolute path that starts a word: a `/` not after a
    /// letter, digit, `.`, `:`, `-` or another `/` (so `https://host/x`,
    /// `1/2` and `and/or` stay), then up to whitespace, a quote, a bracket,
    /// a comma or a colon. A bare `~` (as in "~30 seconds") is not a path.
    private static let barePath = try! NSRegularExpression(
        pattern: #"(?:~/|(?<![\w.:/-])/)[^\s'"(),;:]*"#)

    /// Waits for every line queued so far. Tests use it; the app doesn't.
    @discardableResult
    static func flush(timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private static func append(_ level: String, _ message: String) {
        let at = Date()
        guard let url = fileURL else { return }
        queue.async {
            do {
                try LogFile.append("\(LogFile.stamp.string(from: at)) \(level) \(message)\n", to: url, capBytes: capBytes)
                reportedFailure = nil
            } catch {
                let reason = LogFile.redactingHome("\(url.path): \(error)")
                if reportedFailure != reason {
                    reportedFailure = reason
                    logger.error("remote log file cannot be written — \(reason, privacy: .public)")
                }
            }
        }
    }
}
