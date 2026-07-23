import XCTest
@testable import TempleUI
import TempleCore

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

@MainActor
final class UsageMeterTests: XCTestCase {
    private func claude(fiveHour: Double? = nil, weekly: Double? = nil,
                        scoped: [ScopedUsage] = [], credits: Double? = nil) -> ClaudeUsage {
        ClaudeUsage(plan: "team",
                    fiveHour: fiveHour.map(UsageWindow.init),
                    weekly: weekly.map(UsageWindow.init),
                    scoped: scoped, creditsPct: credits)
    }

    func testHeadlineIsTheMostConstrainedWindow() async {
        let model = UsageMeterModel()
        let claudeReading = claude(fiveHour: 48, weekly: 38,
                                   scoped: [ScopedUsage(label: "Fable", pct: 54)])
        model.claudeFetch = { .usage(claudeReading) }
        model.codexFetch = {
            CodexUsage(plan: "pro", capturedAt: nil,
                       fiveHour: UsageWindow(pct: 31), weekly: UsageWindow(pct: 17))
        }
        await model.refreshNow()

        XCTAssertEqual(model.claudeHeadlinePct, 54)   // the scoped cap is the wall
        XCTAssertEqual(model.codexHeadlinePct, 31)
        let claudeTip = model.claudeBreakdown ?? ""
        XCTAssertTrue(claudeTip.contains("Fable: 54%"))
        XCTAssertTrue(claudeTip.contains("Claude (team)"))
        XCTAssertFalse(claudeTip.contains("Codex"))   // per-segment tooltips
    }

    func testNoReadersMeansNoMeter() async {
        let model = UsageMeterModel()
        model.claudeFetch = { .noCredentials }
        model.codexFetch = { nil }
        await model.refreshNow()

        XCTAssertNil(model.claudeHeadlinePct)
        XCTAssertNil(model.codexHeadlinePct)
        XCTAssertNil(model.updatedAt)
    }

    func testNoCredentialsTripsTheBreakerSoThePromptNeverNags() async {
        // The credential lookup is what raises the macOS Keychain prompt —
        // after one no-credentials read (e.g. the user clicked Deny), the
        // poll must never ask again for the rest of the run.
        let model = UsageMeterModel()
        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .noCredentials }
        model.codexFetch = { nil }
        await model.refreshNow()
        await model.refreshNow()
        await model.refreshNow()
        let total = await calls.value
        XCTAssertEqual(total, 1)
    }

    func testRateLimitBacksOffUntilTheWindowPasses() async {
        let model = UsageMeterModel()
        model.rateLimitBackoff = 3600
        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .rateLimited }
        model.codexFetch = { nil }
        await model.refreshNow()
        await model.refreshNow()   // inside the backoff window — no fetch
        var total = await calls.value
        XCTAssertEqual(total, 1)

        model.rateLimitBackoff = -1   // next 429 sets a window already past
        await model.refreshNow()      // still inside the first window
        total = await calls.value
        XCTAssertEqual(total, 1)
    }

    func testEndpointFailureKeepsRetrying() async {
        let model = UsageMeterModel()
        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .endpointFailure }
        model.codexFetch = { nil }
        await model.refreshNow()
        await model.refreshNow()
        let total = await calls.value
        XCTAssertEqual(total, 2)   // no prompt involved — free to retry
    }

    func testTransientFailureKeepsTheLastGoodReading() async {
        let model = UsageMeterModel()
        let claudeReading = claude(fiveHour: 48)
        model.claudeFetch = { .usage(claudeReading) }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)

        model.claudeFetch = { .endpointFailure }   // hiccup on the next poll
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)
    }

    func testOneProviderAloneStillShows() async {
        let model = UsageMeterModel()
        model.claudeFetch = { .endpointFailure }
        model.codexFetch = {
            CodexUsage(plan: "pro", capturedAt: nil, fiveHour: nil,
                       weekly: UsageWindow(pct: 17))
        }
        await model.refreshNow()

        XCTAssertNil(model.claudeHeadlinePct)
        XCTAssertEqual(model.codexHeadlinePct, 17)
        XCTAssertNil(model.claudeBreakdown)
        XCTAssertTrue((model.codexBreakdown ?? "").contains("Codex (pro)"))
        XCTAssertTrue((model.codexBreakdown ?? "").contains("Weekly: 17%"))
    }
}
