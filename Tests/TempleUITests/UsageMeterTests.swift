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
        // automatic poll must never ask again on its own.
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

    /// Let queued refresh tasks run until `check` holds, or give up. The model
    /// spawns its fetches as unstructured tasks, so a plain `Task.yield()`
    /// proves nothing about whether one of them completed.
    private func settle(until check: () -> Bool) async {
        for _ in 0..<200 where !check() { await Task.yield() }
    }

    func testOnlyTheExplicitControlRetriesTheCredentialLookup() async {
        // The breaker silences UNATTENDED polls; the refresh button is the user
        // standing there asking, and is the only way out. It used to be a
        // one-way latch, so a single transient miss (locked Keychain, a token
        // rotation caught mid-write) froze the Claude figures for the life of
        // the process and the refresh control spun without doing anything.
        let model = UsageMeterModel()
        model.manualFloor = -1                       // no floor between clicks
        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .noCredentials }
        model.codexFetch = { nil }
        await model.refreshNow()
        await model.refreshNow()                     // automatic: still silenced
        var total = await calls.value
        XCTAssertEqual(total, 1)

        // Opening the card refreshes on the way in, but must NOT re-arm the
        // lookup: that gesture is navigation, and a user who denied the prompt
        // would be asked again every time they glanced at their usage.
        model.manualRefresh()
        await settle { false }
        total = await calls.value
        XCTAssertEqual(total, 1, "opening the card must not re-ask for credentials")

        let reading = claude(fiveHour: 61)
        model.claudeFetch = { await calls.bump(); return .usage(reading) }
        model.manualRefresh(retryingCredentials: true)
        // No direct refreshNow() here: the click alone has to do the work, or
        // this passes on an implementation whose button fetches nothing.
        await settle { model.claudeHeadlinePct == 61 }
        total = await calls.value
        XCTAssertEqual(total, 2)
        XCTAssertEqual(model.claudeHeadlinePct, 61)
    }

    func testStalenessIsOnlyReportedOnceTheReaderHasActuallyStopped() async {
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 12)
        model.claudeFetch = { .usage(reading) }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertNil(model.claudeStaleSince)         // fresh: the card says nothing

        // Every later refresh comes back empty. The numbers on screen stop
        // being true, and nothing in the card used to admit it.
        model.claudeFetch = { .endpointFailure }
        for missed in 1..<UsageMeterModel.staleAfterMissedRefreshes {
            await model.refreshNow()
            XCTAssertNil(model.claudeStaleSince, "\(missed) miss(es) is still a hiccup")
        }
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 12)  // last good reading stands
        XCTAssertEqual(model.claudeStaleSince, model.claudeUpdatedAt)

        model.claudeFetch = { .usage(reading) }      // recovers, and shuts up again
        await model.refreshNow()
        XCTAssertNil(model.claudeStaleSince)
    }

    func testATrippedBreakerCountsAsAMissedRefresh() async {
        // The field bug exactly: after the breaker trips, nothing is attempted,
        // so nothing ever FAILS. Staleness counted from failures alone would
        // stay silent forever while the numbers rot — which is what happened
        // for eight days.
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 12)
        model.claudeFetch = { .usage(reading) }
        model.codexFetch = { CodexUsage(plan: "pro", capturedAt: nil,
                                        fiveHour: nil, weekly: UsageWindow(pct: 9)) }
        await model.refreshNow()
        model.claudeFetch = { .noCredentials }
        await model.refreshNow()                     // trips it; the only failure

        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .noCredentials }
        for _ in 0..<UsageMeterModel.staleAfterMissedRefreshes { await model.refreshNow() }
        let attempts = await calls.value
        XCTAssertEqual(attempts, 0, "the breaker means these polls never asked")
        XCTAssertEqual(model.claudeStaleSince, model.claudeUpdatedAt)
    }

    func testCodexSuccessDoesNotDisguiseADeadClaudeReader() async {
        // Both sections share one card. `updatedAt` moves on a Codex-only
        // success, so the Claude section needs its own timestamp or a live
        // Codex read makes stale Claude figures look current.
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 12)
        model.claudeFetch = { .usage(reading) }
        model.codexFetch = { CodexUsage(plan: "pro", capturedAt: nil,
                                        fiveHour: nil, weekly: UsageWindow(pct: 9)) }
        await model.refreshNow()
        let claudeRead = model.claudeUpdatedAt

        model.claudeFetch = { .endpointFailure }
        for _ in 0..<UsageMeterModel.staleAfterMissedRefreshes { await model.refreshNow() }
        XCTAssertEqual(model.claudeUpdatedAt, claudeRead)   // did not move
        XCTAssertNotEqual(model.updatedAt, claudeRead)      // but the card did refresh
        XCTAssertEqual(model.claudeStaleSince, claudeRead)  // and says so anyway
    }

    func testStartIsIdempotentAndDoesNotDoubleTheFirstFetch() async {
        // RootView's onAppear re-runs when the root view is rebuilt. Two calls
        // in the same turn used to queue two initial fetches, each testing a
        // `lastAttempt` neither had moved yet.
        let model = UsageMeterModel()
        let calls = Counter()
        model.claudeFetch = { await calls.bump(); return .endpointFailure }
        model.codexFetch = { nil }
        model.start()
        model.start()
        await settle { false }
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
