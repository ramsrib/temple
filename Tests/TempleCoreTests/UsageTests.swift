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
}
