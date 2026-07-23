import Foundation

// Subscription usage for Claude and Codex, read the way ccmeter reads it
// (https://github.com/ramsrib — dotfiles CLI; the mechanics are ported 1:1):
//
//   Claude : live read of the undocumented OAuth usage endpoint
//            (GET api.anthropic.com/api/oauth/usage) using the Claude Code
//            OAuth token from the Keychain / ~/.claude.
//   Codex  : the most recent rate-limit snapshot Codex persists into its
//            rollout logs — free, but only as fresh as the last Codex turn.
//
// Caveat that shapes everything here: the endpoint is undocumented and the
// log shape is Codex's private business; either can change under us. Every
// reader returns nil on any surprise — the meter degrades to absence, never
// to an error surface.

public struct UsageWindow: Equatable, Sendable {
    public let pct: Double
    public init(pct: Double) { self.pct = pct }
}

public struct ScopedUsage: Equatable, Sendable {
    public let label: String
    public let pct: Double
    public init(label: String, pct: Double) {
        self.label = label
        self.pct = pct
    }
}

public struct ClaudeUsage: Equatable, Sendable {
    public let plan: String?
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?
    public let scoped: [ScopedUsage]
    /// Extra-usage credit spend, when enabled (pct of the monthly limit).
    public let creditsPct: Double?

    public init(plan: String?, fiveHour: UsageWindow?, weekly: UsageWindow?,
                scoped: [ScopedUsage], creditsPct: Double?) {
        self.plan = plan
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scoped = scoped
        self.creditsPct = creditsPct
    }
}

public struct CodexUsage: Equatable, Sendable {
    public let plan: String?
    /// When the snapshot was written (the rollout file's mtime).
    public let capturedAt: Date?
    public let fiveHour: UsageWindow?
    public let weekly: UsageWindow?

    public init(plan: String?, capturedAt: Date?,
                fiveHour: UsageWindow?, weekly: UsageWindow?) {
        self.plan = plan
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

// MARK: - Claude (live endpoint)

public enum ClaudeUsageReader {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint 401s/429s without a claude-code User-Agent; only the
    /// shape matters, not the exact version.
    static let userAgent = "claude-code/2.1.201"
    static let keychainService = "Claude Code-credentials"

    public enum Outcome: Sendable {
        /// No token anywhere — including a DENIED Keychain prompt. The caller
        /// must stop asking for the rest of the run, or the poll re-prompts
        /// the user every cycle.
        case noCredentials
        /// Had a token, endpoint didn't answer usefully — retry later, this
        /// path never prompts anyone.
        case endpointFailure
        /// The endpoint said 429: it is rate-limited server-side, so the
        /// caller should back off well past the normal poll interval.
        case rateLimited
        case usage(ClaudeUsage)
    }

    public static func read() async -> Outcome {
        guard let creds = await loadCredentials() else { return .noCredentials }
        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .endpointFailure }
        if status == 429 { return .rateLimited }
        guard status == 200, let usage = parse(data, plan: creds.plan) else {
            return .endpointFailure
        }
        return .usage(usage)
    }

    /// Pure mapping of the endpoint's JSON — tolerant: absent fields drop out.
    public static func parse(_ data: Data, plan: String?) -> ClaudeUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        func window(_ any: Any?) -> UsageWindow? {
            guard let dict = any as? [String: Any] else { return nil }
            return UsageWindow(pct: (dict["utilization"] as? Double) ?? 0)
        }

        // Model/surface-scoped caps (e.g. Fable) live only in `limits[]`.
        var scoped: [ScopedUsage] = []
        for limit in root["limits"] as? [[String: Any]] ?? [] {
            guard let kind = limit["kind"] as? String, kind.hasSuffix("_scoped") else { continue }
            let scope = limit["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            let label = model ?? (scope?["surface"] as? String) ?? "scoped"
            scoped.append(ScopedUsage(label: label, pct: (limit["percent"] as? Double) ?? 0))
        }

        var creditsPct: Double?
        if let extra = root["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true {
            creditsPct = (extra["utilization"] as? Double) ?? 0
        }

        return ClaudeUsage(plan: plan,
                           fiveHour: window(root["five_hour"]),
                           weekly: window(root["seven_day"]),
                           scoped: scoped,
                           creditsPct: creditsPct)
    }

    // MARK: Credentials

    struct Credentials {
        let token: String
        let expiresAt: Double?
        let plan: String?
    }

    /// The Claude Code OAuth token: Keychain first (the CLI refreshes it in
    /// place there), file fallback. Claude Code leaves token-less STUB items
    /// behind under the same service name, and a plain service lookup can
    /// return a stub — so enumerate the service variants and keep the
    /// freshest item that actually carries a token (ccmeter's logic).
    static func loadCredentials() async -> Credentials? {
        await Task.detached(priority: .utility) { () -> Credentials? in
            var candidates: [(service: String, account: String)] = []
            if let dump = runForStdout("/usr/bin/security", ["dump-keychain"]) {
                for block in dump.components(separatedBy: "\nkeychain: ") {
                    guard let service = firstMatch(#""svce"<blob>="([^"]*)""#, in: block),
                          service.hasPrefix(keychainService) else { continue }
                    let account = firstMatch(#""acct"<blob>="([^"]*)""#, in: block) ?? ""
                    candidates.append((service, account))
                }
            }
            if candidates.isEmpty { candidates.append((keychainService, "")) }

            var found: [Credentials] = []
            for (service, account) in candidates {
                var args = ["find-generic-password", "-s", service]
                if !account.isEmpty { args += ["-a", account] }
                args.append("-w")
                guard let out = runForStdout("/usr/bin/security", args),
                      let creds = parseCredentials(Data(out.utf8)) else { continue }
                found.append(creds)
            }
            if let best = found.max(by: { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }) {
                return best
            }

            // ~/.claude/.credentials.json — the canonical store off-macOS.
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return parseCredentials(data)
        }.value
    }

    /// Pure: the `claudeAiOauth` payload both credential stores carry.
    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return Credentials(token: token,
                           expiresAt: oauth["expiresAt"] as? Double,
                           plan: oauth["subscriptionType"] as? String)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// stdout of a command, or nil on failure. Arguments never touch a shell.
    private static func runForStdout(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Codex (rollout-log snapshot)

public enum CodexUsageReader {
    /// Same root resolution as CodexSessionStore, so `make demo` stays inside
    /// its fake store.
    public static func defaultSessionsRoot() -> URL {
        let base = ProcessInfo.processInfo.environment["TEMPLE_CODEX_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        return base.appendingPathComponent("sessions", isDirectory: true)
    }

    public static func read(sessionsRoot: URL = defaultSessionsRoot()) -> CodexUsage? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sessionsRoot,
                                             includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        var files: [(url: URL, mtime: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, mtime))
        }
        files.sort { $0.mtime > $1.mtime }

        for (url, mtime) in files.prefix(25) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let usage = latestSnapshot(inFileText: text, capturedAt: mtime) {
                return usage
            }
        }
        return nil
    }

    /// The LAST rate-limits record in the file (the most recent turn) — pure.
    public static func latestSnapshot(inFileText text: String, capturedAt: Date?) -> CodexUsage? {
        var last: [String: Any]?
        for line in text.split(separator: "\n") {
            guard line.contains("\"rate_limits\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = findRateLimits(obj) else { continue }
            last = limits
        }
        guard let last else { return nil }

        // Bucket by each window's own duration, NOT by slot: `primary` and
        // `secondary` are just slots, and OpenAI has changed what lives in
        // them mid-session (2026-07-12: dropped the 5h cap server-side, the
        // weekly window moved into `primary`). Positional reads rendered the
        // weekly figure as a 5-hour window "resetting in 6 days".
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        for slot in ["primary", "secondary"] {
            guard let window = last[slot] as? [String: Any] else { continue }
            let pct = (window["used_percent"] as? Double) ?? 0
            let minutes = (window["window_minutes"] as? Double) ?? 0
            if minutes <= 24 * 60 {
                fiveHour = UsageWindow(pct: pct)
            } else {
                weekly = UsageWindow(pct: pct)
            }
        }
        guard fiveHour != nil || weekly != nil else { return nil }
        return CodexUsage(plan: last["plan_type"] as? String,
                          capturedAt: capturedAt,
                          fiveHour: fiveHour, weekly: weekly)
    }

    /// Depth-first search for a `rate_limits` object anywhere in the record.
    private static func findRateLimits(_ any: Any) -> [String: Any]? {
        guard let dict = any as? [String: Any] else {
            if let array = any as? [Any] {
                for element in array {
                    if let found = findRateLimits(element) { return found }
                }
            }
            return nil
        }
        if let limits = dict["rate_limits"] as? [String: Any] { return limits }
        for value in dict.values {
            if let found = findRateLimits(value) { return found }
        }
        return nil
    }
}
