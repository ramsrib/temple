import XCTest
@testable import TempleCore

final class UsageTests: XCTestCase {
    // MARK: Claude endpoint payload

    func testParsesClaudeUsagePayload() throws {
        let payload = """
        {
          "five_hour": { "utilization": 48.2, "resets_at": "2026-07-23T05:00:00+00:00" },
          "seven_day": { "utilization": 38.0, "resets_at": "2026-07-27T22:00:00+00:00" },
          "limits": [
            { "kind": "model_scoped", "group": "weekly", "percent": 54.4,
              "scope": { "model": { "display_name": "Fable" } } },
            { "kind": "overall", "percent": 12 }
          ],
          "extra_usage": { "is_enabled": true, "utilization": 55.1,
                           "used_credits": 275621, "monthly_limit": 500000,
                           "decimal_places": 2, "currency": "USD" }
        }
        """
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(Data(payload.utf8), plan: "team"))
        XCTAssertEqual(usage.plan, "team")
        XCTAssertEqual(usage.fiveHour?.pct, 48.2)
        XCTAssertEqual(usage.weekly?.pct, 38.0)
        // Only *_scoped limits become scoped rows; "overall" is skipped.
        XCTAssertEqual(usage.scoped, [ScopedUsage(label: "Fable", pct: 54.4)])
        XCTAssertEqual(usage.creditsPct, 55.1)
    }

    func testClaudePayloadToleratesMissingFields() throws {
        let usage = try XCTUnwrap(ClaudeUsageReader.parse(Data("{}".utf8), plan: nil))
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.weekly)
        XCTAssertTrue(usage.scoped.isEmpty)
        XCTAssertNil(usage.creditsPct)
        XCTAssertNil(ClaudeUsageReader.parse(Data("not json".utf8), plan: nil))
    }

    func testParsesClaudeCredentials() throws {
        let payload = """
        { "claudeAiOauth": { "accessToken": "tok-123", "expiresAt": 1784769285786,
                             "subscriptionType": "team" } }
        """
        let creds = try XCTUnwrap(ClaudeUsageReader.parseCredentials(Data(payload.utf8)))
        XCTAssertEqual(creds.token, "tok-123")
        XCTAssertEqual(creds.plan, "team")
        // Token-less stubs (Claude Code leaves these behind) must not count.
        XCTAssertNil(ClaudeUsageReader.parseCredentials(
            Data(#"{ "claudeAiOauth": { "accessToken": "" } }"#.utf8)))
    }

    // MARK: Codex rollout snapshot

    private func record(_ rateLimits: String) -> String {
        // rate_limits nested one level down, as in real rollout records.
        #"{"type":"turn_context","payload":{"rate_limits":\#(rateLimits),"model":"gpt"}}"#
    }

    func testCodexSnapshotBucketsWindowsByDurationNotSlot() throws {
        // Normal shape: primary = 5h (300m), secondary = weekly (10080m).
        let normal = record(#"{"plan_type":"pro","primary":{"used_percent":31,"window_minutes":300},"secondary":{"used_percent":17,"window_minutes":10080}}"#)
        let usage = try XCTUnwrap(CodexUsageReader.latestSnapshot(inFileText: normal, capturedAt: nil))
        XCTAssertEqual(usage.plan, "pro")
        XCTAssertEqual(usage.fiveHour?.pct, 31)
        XCTAssertEqual(usage.weekly?.pct, 17)

        // 2026-07-12 shape: the 5h cap dropped server-side and the WEEKLY
        // window moved into the primary slot. Positional reads rendered the
        // weekly figure as a 5-hour window; duration-bucketing must not.
        let weeklyOnly = record(#"{"plan_type":"pro","primary":{"used_percent":17,"window_minutes":10080},"secondary":null}"#)
        let shifted = try XCTUnwrap(CodexUsageReader.latestSnapshot(inFileText: weeklyOnly, capturedAt: nil))
        XCTAssertNil(shifted.fiveHour)
        XCTAssertEqual(shifted.weekly?.pct, 17)
    }

    func testCodexSnapshotTakesTheLastRecordInTheFile() throws {
        let text = [
            record(#"{"primary":{"used_percent":10,"window_minutes":300}}"#),
            #"{"noise":"line"}"#,
            record(#"{"primary":{"used_percent":42,"window_minutes":300}}"#),
        ].joined(separator: "\n")
        let usage = try XCTUnwrap(CodexUsageReader.latestSnapshot(inFileText: text, capturedAt: nil))
        XCTAssertEqual(usage.fiveHour?.pct, 42)
    }

    func testCodexSnapshotIgnoresFilesWithoutRateLimits() {
        XCTAssertNil(CodexUsageReader.latestSnapshot(
            inFileText: #"{"type":"message","text":"hello"}"#, capturedAt: nil))
        XCTAssertNil(CodexUsageReader.latestSnapshot(inFileText: "", capturedAt: nil))
    }

    func testCodexReadScansNewestRolloutFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-usage-\(UUID().uuidString)/sessions/2026/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = dir.appendingPathComponent("rollout-old.jsonl")
        let new = dir.appendingPathComponent("rollout-new.jsonl")
        try record(#"{"primary":{"used_percent":10,"window_minutes":300}}"#)
            .write(to: old, atomically: true, encoding: .utf8)
        try record(#"{"primary":{"used_percent":77,"window_minutes":300}}"#)
            .write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)

        let usage = CodexUsageReader.read(sessionsRoot: dir.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(usage?.fiveHour?.pct, 77)
    }

    // The credential log line's expiry phrase: Claude Code writes epoch
    // milliseconds, older stores wrote seconds, and both must read right.
    func testExpiryDescriptionReadsMillisecondsAndSecondsAlike() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inThreeHours = (now.timeIntervalSince1970 + 3 * 3600 + 12 * 60)
        XCTAssertEqual(ClaudeUsageReader.expiryDescription(inThreeHours * 1000, now: now), "expires in 3h 12m")
        XCTAssertEqual(ClaudeUsageReader.expiryDescription(inThreeHours, now: now), "expires in 3h 12m")
        let twoDaysAgo = now.timeIntervalSince1970 - (2 * 86_400 + 4 * 3600)
        XCTAssertEqual(ClaudeUsageReader.expiryDescription(twoDaysAgo * 1000, now: now), "expired 2d 4h ago")
        XCTAssertEqual(ClaudeUsageReader.expiryDescription(now.timeIntervalSince1970 - 90, now: now), "expired 1m ago")
        XCTAssertEqual(ClaudeUsageReader.expiryDescription(nil, now: now), "no expiry recorded")
    }

    // MARK: The lookup through injected Security calls

    private final class FakeKeychain {
        var previous: Bool?
        var setStatus: OSStatus
        var sets: [Bool] = []
        var queries = 0
        /// nil data = needs a prompt; `denied` = the prompt was shown and refused
        var items: [(service: String, account: String, data: Data?)]
        var denied = false
        init(previous: Bool? = true, setStatus: OSStatus = errSecSuccess,
             items: [(service: String, account: String, data: Data?)] = []) {
            self.previous = previous; self.setStatus = setStatus; self.items = items
        }
    }

    private func install(_ fake: FakeKeychain, credentialsFile: URL = URL(fileURLWithPath: "/nonexistent/credentials.json"),
                         body: (FakeKeychain) -> Void) {
        let saved = ClaudeUsageReader.keychain
        defer { ClaudeUsageReader.keychain = saved }
        ClaudeUsageReader.keychain = .init(
            setInteractionAllowed: { allowed in fake.sets.append(allowed); return fake.setStatus },
            interactionAllowed: { fake.previous },
            copyMatching: { query in
                fake.queries += 1
                let q = query as NSDictionary
                if q[kSecReturnAttributes as String] as? Bool == true {
                    let attrs = fake.items.map { [kSecAttrService as String: $0.service, kSecAttrAccount as String: $0.account] as [String: Any] }
                    return (errSecSuccess, attrs as CFTypeRef)
                }
                let service = q[kSecAttrService as String] as? String
                let account = q[kSecAttrAccount as String] as? String ?? ""
                guard let item = fake.items.first(where: { $0.service == service && $0.account == account }) else {
                    return (errSecItemNotFound, nil)
                }
                guard let data = item.data else { return (fake.denied ? errSecUserCanceled : errSecInteractionNotAllowed, nil) }
                return (errSecSuccess, data as CFTypeRef)
            },
            credentialsFile: credentialsFile)
        body(fake)
    }

    private func token(expiresAt: Double) -> Data {
        Data(#"{"claudeAiOauth":{"accessToken":"tok-\#(Int(expiresAt))","expiresAt":\#(expiresAt),"subscriptionType":"max"}}"#.utf8)
    }

    private func lookup(interactive: Bool) -> ClaudeUsageReader.CredentialLookup {
        let done = DispatchSemaphore(value: 0)
        var result: ClaudeUsageReader.CredentialLookup = .none
        Task.detached { result = await ClaudeUsageReader.loadCredentials(interactive: interactive); done.signal() }
        done.wait()
        return result
    }

    func testUnattendedLookupDisablesPromptsThenRestoresTheSetting() throws {
        install(FakeKeychain(previous: false, items: [("Claude Code-credentials", "me", token(expiresAt: 2e12))])) { fake in
            guard case .found(let creds) = lookup(interactive: false) else { return XCTFail("expected a token") }
            XCTAssertEqual(creds.token, "tok-2000000000000")
            XCTAssertEqual(fake.sets, [false, false], "set to no-prompts for the read, then back to what it was (false)")
            XCTAssertEqual(fake.queries, 2, "one listing, one read")
        }
    }

    func testTheFreshestTokenWinsAndStubsAreSkipped() {
        let items: [(String, String, Data?)] = [
            ("Claude Code-credentials", "unknown", Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)),
            ("Claude Code-credentials", "me", token(expiresAt: 1e12)),
            ("Claude Code-credentials-3f232086", "me", token(expiresAt: 3e12)),
            ("Something else", "x", nil),
        ]
        install(FakeKeychain(items: items)) { _ in
            guard case .found(let creds) = lookup(interactive: false) else { return XCTFail("expected a token") }
            XCTAssertEqual(creds.token, "tok-3000000000000")
        }
    }

    func testAnItemNeedingAPromptReportsPermissionAndSkipsTheFile() throws {
        // A perfectly good credentials file is on disk; the lookup must not
        // fall through to it, because the Keychain may hold newer credentials.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-usage-\(UUID().uuidString).json")
        try token(expiresAt: 2e12).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        install(FakeKeychain(items: [("Claude Code-credentials", "me", nil)]), credentialsFile: file) { fake in
            guard case .needsPermission = lookup(interactive: false) else { return XCTFail("expected needsPermission") }
            XCTAssertEqual(fake.sets, [false, true])
        }
        // And with nothing in the Keychain at all, that same file IS used.
        install(FakeKeychain(items: []), credentialsFile: file) { _ in
            guard case .found(let creds) = lookup(interactive: false) else { return XCTFail("expected the file") }
            XCTAssertEqual(creds.token, "tok-2000000000000")
        }
    }

    func testUnattendedLookupDoesNotReadWhenPromptsCannotBeDisabled() {
        install(FakeKeychain(setStatus: errSecParam, items: [("Claude Code-credentials", "me", token(expiresAt: 2e12))])) { fake in
            guard case .needsPermission = lookup(interactive: false) else { return XCTFail("must not read") }
            XCTAssertEqual(fake.queries, 0, "no Keychain query may follow a switch that could not be set")
        }
        install(FakeKeychain(previous: nil, items: [("Claude Code-credentials", "me", token(expiresAt: 2e12))])) { fake in
            guard case .needsPermission = lookup(interactive: false) else { return XCTFail("must not read") }
            XCTAssertEqual(fake.queries, 0, "nor when the previous setting is unknown")
            XCTAssertEqual(fake.sets, [], "and nothing was changed")
        }
    }

    func testTheUsersOwnClickReadsEvenWhenThePreviousSettingIsUnknown() {
        install(FakeKeychain(previous: nil, items: [("Claude Code-credentials", "me", token(expiresAt: 2e12))])) { fake in
            guard case .found = lookup(interactive: true) else { return XCTFail("expected a token") }
            XCTAssertEqual(fake.sets, [true, true], "allowed for the click, then the system default")
        }
    }

    func testAPromptTheUserRefusedIsPermissionTooNotNoCredentials() {
        // Interactive read, the user hits Deny: still "needs permission" —
        // the item is there, only the grant is missing.
        let fake = FakeKeychain(items: [("Claude Code-credentials", "me", nil)])
        fake.denied = true
        install(fake) { fake in
            guard case .needsPermission = lookup(interactive: true) else { return XCTFail("expected needsPermission") }
            XCTAssertEqual(fake.sets, [true, true])
        }
    }
}
