import Foundation
import Security

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
        /// A token exists but Temple may not read it without a Keychain
        /// prompt, and this read was not allowed to raise one. Only an
        /// explicit refresh (interactive) can clear it; the card says so.
        case needsPermission
        /// Had a token, endpoint didn't answer usefully — retry later, this
        /// path never prompts anyone. `status` is the HTTP status, nil when
        /// the request never got an answer; 200 means the body did not parse.
        case endpointFailure(status: Int?)
        /// The endpoint said 401: the token is expired or revoked, and only a
        /// new Claude Code sign-in will change that. Retrying is free but
        /// pointless, and the user needs to be told which.
        case unauthorized
        /// The endpoint said 429: it is rate-limited server-side, so the
        /// caller should back off well past the normal poll interval.
        case rateLimited
        case usage(ClaudeUsage)

        /// True for every outcome that came back from the endpoint — the
        /// token was found and sent, whatever the answer.
        public var credentialsWereRead: Bool {
            switch self {
            case .usage, .unauthorized, .rateLimited, .endpointFailure: return true
            case .noCredentials, .needsPermission: return false
            }
        }
    }

    /// `interactive` allows the Keychain prompt. Unattended polls pass false:
    /// an item Temple may not read then fails instead of prompting, and the
    /// prompt is raised only by the explicit refresh control, where the
    /// user is looking and "Always Allow" makes every later poll silent.
    public static func read(interactive: Bool) async -> Outcome {
        switch await loadCredentials(interactive: interactive) {
        case .found(let creds): return await fetch(with: creds)
        case .needsPermission: return .needsPermission
        case .none: return .noCredentials
        }
    }

    private static func fetch(with creds: Credentials) async -> Outcome {
        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .endpointFailure(status: nil) }
        switch status {
        case 200:
            guard let usage = parse(data, plan: creds.plan) else {
                UsageLog.info("claude usage: 200 but the body did not parse (\(data.count) bytes)")
                return .endpointFailure(status: 200)
            }
            return .usage(usage)
        case 401: return .unauthorized
        case 429: return .rateLimited
        default: return .endpointFailure(status: status)
        }
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

    enum CredentialLookup {
        case found(Credentials)
        /// At least one item carries a token but reading it needs a prompt
        /// this lookup was not allowed to raise.
        case needsPermission
        case none
    }

    /// The Claude Code OAuth token: Keychain first (the CLI refreshes it in
    /// place there), file fallback. Claude Code leaves token-less STUB items
    /// behind under the same service name, and a plain service lookup can
    /// return a stub — so enumerate the service variants and keep the
    /// freshest item that actually carries a token (ccmeter's logic).
    ///
    /// In-process through the Security framework, not the `security` CLI:
    /// the CLI's Keychain prompts are attributed to `security`, so "Always
    /// Allow" never sticks to Temple, and a child blocked on an unanswered
    /// prompt needed a runner with deadlines, signals and pid races to keep
    /// it from freezing the meter for the life of the process. Here the
    /// prompt is Temple's own, and unattended polls disable it outright.
    /// The Security framework calls the lookup makes, as one replaceable
    /// unit: tests inject failures (a switch that cannot be set, a getter
    /// that fails) and prove no Keychain query follows.
    struct KeychainAccess {
        var setInteractionAllowed: (Bool) -> OSStatus
        var interactionAllowed: () -> Bool?
        var copyMatching: (CFDictionary) -> (status: OSStatus, result: CFTypeRef?)
        var credentialsFile: URL

        static let live = KeychainAccess(
            setInteractionAllowed: { setKeychainInteractionAllowed($0) },
            interactionAllowed: { keychainInteractionAllowed() },
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query, &result)
                return (status, result)
            },
            credentialsFile: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json"))
    }
    static var keychain = KeychainAccess.live

    /// Every lookup runs here, one at a time: the interaction switch below
    /// is process-wide, and two lookups with different policies interleaved
    /// would set each other's. The model's in-flight guard is not relied on.
    private static let lookupQueue = DispatchQueue(label: "com.sriramb.temple.claude-credentials", qos: .utility)

    static func loadCredentials(interactive: Bool) async -> CredentialLookup {
        await withCheckedContinuation { continuation in
            lookupQueue.async { continuation.resume(returning: lookupCredentials(interactive: interactive)) }
        }
    }

    private static func lookupCredentials(interactive: Bool) -> CredentialLookup {
        do {
            // Process-wide, so it is set for exactly this lookup and put back
            // the way it was. Deprecated, and the only switch that applies to
            // login-keychain items — the per-query kSecUseAuthenticationUI
            // covers the data-protection keychain alone (SecItem.h).
            //
            // An unattended lookup that cannot establish "no prompts" does
            // not read at all: a read that might prompt is the failure this
            // whole path exists to prevent. It reports the same state a
            // denied item does, so the card sends the user to the one control
            // that may ask. The interactive lookup is the user's own click;
            // it proceeds, and puts the switch back to the system default if
            // the previous value could not be read.
            let previous = keychain.interactionAllowed()
            if previous == nil, !interactive {
                UsageLog.notice("claude credentials: could not read the keychain interaction setting; not reading unattended")
                return .needsPermission
            }
            let set = keychain.setInteractionAllowed(interactive)
            if set != errSecSuccess {
                UsageLog.notice("claude credentials: could not set keychain interaction to \(interactive) (OSStatus \(set))\(interactive ? "" : "; not reading unattended")")
                if !interactive { return .needsPermission }
            }
            defer { _ = keychain.setInteractionAllowed(previous ?? true) }

            // Attributes only — never touches a secret, never prompts.
            let listQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var candidates: [(service: String, account: String)] = []
            let listing = keychain.copyMatching(listQuery as CFDictionary)
            if listing.status == errSecSuccess, let items = listing.result as? [[String: Any]] {
                for item in items {
                    guard let service = item[kSecAttrService as String] as? String,
                          service.hasPrefix(keychainService) else { continue }
                    candidates.append((service, item[kSecAttrAccount as String] as? String ?? ""))
                }
            }
            if candidates.isEmpty { candidates.append((keychainService, "")) }

            var found: [(creds: Credentials, service: String, account: String)] = []
            var needPrompt = 0
            for (service, account) in candidates {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true,
                ]
                if !account.isEmpty { query[kSecAttrAccount as String] = account }
                let answer = keychain.copyMatching(query as CFDictionary)
                switch answer.status {
                case errSecSuccess:
                    if let data = answer.result as? Data, let creds = parseCredentials(data) {
                        found.append((creds, service, account))
                    }
                case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                    needPrompt += 1
                default:
                    break
                }
            }
            // Which item won, and whether its token is already past its own
            // expiry, is the fact a dead meter turns on — and the model never
            // sees it. One line per read; never the token, never the account
            // (a username or address). The service name is a fixed label
            // plus an opaque suffix.
            if let best = found.max(by: { ($0.creds.expiresAt ?? 0) < ($1.creds.expiresAt ?? 0) }) {
                UsageLog.info("claude credentials: keychain item \(best.service) chosen of \(found.count) with a token (\(candidates.count) enumerated, \(needPrompt) unreadable without a prompt); \(expiryDescription(best.creds.expiresAt))")
                return .found(best.creds)
            }
            if needPrompt > 0 {
                // A transition worth keeping: notice level persists, info does not.
                UsageLog.notice("claude credentials: \(needPrompt) of \(candidates.count) keychain item(s) need a prompt Temple was \(interactive ? "denied" : "not allowed to raise"); the explicit refresh control asks")
                return .needsPermission
            }

            // ~/.claude/.credentials.json — the canonical store off-macOS.
            guard let data = try? Data(contentsOf: keychain.credentialsFile), let creds = parseCredentials(data) else {
                UsageLog.notice("claude credentials: none — \(candidates.count) keychain item(s) enumerated, none with a token, and no credentials file")
                return .none
            }
            UsageLog.info("claude credentials: from ~/.claude/.credentials.json; \(expiryDescription(creds.expiresAt))")
            return .found(creds)
        }
    }

    /// Long deprecated (the header says 10.10) and still the only switch that
    /// governs prompts for login-keychain items. Wrapped so the one
    /// deprecation lives here, with the reason. The status is returned, not
    /// swallowed: a set that failed means an unattended poll could prompt.
    @available(macOS, deprecated: 10.10, message: "the only interaction switch that applies to login-keychain items")
    private static func setKeychainInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    /// nil when the setting could not be read; the caller decides what that
    /// means for the lookup at hand.
    @available(macOS, deprecated: 10.10, message: "paired with the setter above")
    private static func keychainInteractionAllowed() -> Bool? {
        var allowed: DarwinBoolean = true
        return SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess ? allowed.boolValue : nil
    }

    /// "expires in 3h 12m" / "expired 2d 4h ago" / "no expiry recorded".
    /// Claude Code writes `expiresAt` in epoch milliseconds; a value small
    /// enough to be seconds is read as seconds.
    static func expiryDescription(_ expiresAt: Double?, now: Date = Date()) -> String {
        guard let expiresAt else { return "no expiry recorded" }
        let seconds = expiresAt > 1e11 ? expiresAt / 1000 : expiresAt
        let delta = seconds - now.timeIntervalSince1970
        let magnitude = abs(delta)
        let text: String
        switch magnitude {
        case ..<3600: text = "\(Int(magnitude / 60))m"
        case ..<86_400: text = "\(Int(magnitude / 3600))h \(Int(magnitude.truncatingRemainder(dividingBy: 3600) / 60))m"
        default: text = "\(Int(magnitude / 86_400))d \(Int(magnitude.truncatingRemainder(dividingBy: 86_400) / 3600))h"
        }
        return delta >= 0 ? "expires in \(text)" : "expired \(text) ago"
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
