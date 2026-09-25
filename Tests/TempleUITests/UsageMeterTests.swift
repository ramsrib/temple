import XCTest
@testable import TempleUI
import TempleCore

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Records what each fetch was asked (interactive or not), across tasks.
private actor AskRecorder {
    private(set) var asks: [Bool] = []
    func record(_ interactive: Bool) { asks.append(interactive) }
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
        model.claudeFetch = { _ in .usage(claudeReading) }
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
        model.claudeFetch = { _ in .noCredentials }
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
        model.claudeFetch = { _ in await calls.bump(); return .noCredentials }
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
        model.claudeFetch = { _ in await calls.bump(); return .noCredentials }
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
        model.claudeFetch = { _ in await calls.bump(); return .usage(reading) }
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
        model.claudeFetch = { _ in .usage(reading) }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertNil(model.claudeStaleSince)         // fresh: the card says nothing

        // Every later refresh comes back empty. The numbers on screen stop
        // being true, and nothing in the card used to admit it.
        model.claudeFetch = { _ in .endpointFailure(status: nil) }
        for missed in 1..<UsageMeterModel.staleAfterMissedRefreshes {
            await model.refreshNow()
            XCTAssertNil(model.claudeStaleSince, "\(missed) miss(es) is still a hiccup")
        }
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 12)  // last good reading stands
        XCTAssertEqual(model.claudeStaleSince, model.claudeUpdatedAt)

        model.claudeFetch = { _ in .usage(reading) }      // recovers, and shuts up again
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
        model.claudeFetch = { _ in .usage(reading) }
        model.codexFetch = { CodexUsage(plan: "pro", capturedAt: nil,
                                        fiveHour: nil, weekly: UsageWindow(pct: 9)) }
        await model.refreshNow()
        model.claudeFetch = { _ in .noCredentials }
        await model.refreshNow()                     // trips it; the only failure

        let calls = Counter()
        model.claudeFetch = { _ in await calls.bump(); return .noCredentials }
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
        model.claudeFetch = { _ in .usage(reading) }
        model.codexFetch = { CodexUsage(plan: "pro", capturedAt: nil,
                                        fiveHour: nil, weekly: UsageWindow(pct: 9)) }
        await model.refreshNow()
        let claudeRead = model.claudeUpdatedAt

        model.claudeFetch = { _ in .endpointFailure(status: nil) }
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
        model.claudeFetch = { _ in await calls.bump(); return .endpointFailure(status: nil) }
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
        model.claudeFetch = { _ in await calls.bump(); return .rateLimited }
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
        model.claudeFetch = { _ in await calls.bump(); return .endpointFailure(status: nil) }
        model.codexFetch = { nil }
        await model.refreshNow()
        await model.refreshNow()
        let total = await calls.value
        XCTAssertEqual(total, 2)   // no prompt involved — free to retry
    }

    func testTransientFailureKeepsTheLastGoodReading() async {
        let model = UsageMeterModel()
        let claudeReading = claude(fiveHour: 48)
        model.claudeFetch = { _ in .usage(claudeReading) }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)

        model.claudeFetch = { _ in .endpointFailure(status: nil) }   // hiccup on the next poll
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)
    }

    func testOneProviderAloneStillShows() async {
        let model = UsageMeterModel()
        model.claudeFetch = { _ in .endpointFailure(status: nil) }
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

    func testARefusedTokenSaysSoAtOnceAndKeepsTheLastReading() async {
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 48)
        model.claudeFetch = { _ in .usage(reading) }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertFalse(model.claudeSignInStale)

        let calls = Counter()
        model.claudeFetch = { _ in await calls.bump(); return .unauthorized }
        await model.refreshNow()
        XCTAssertTrue(model.claudeSignInStale, "a 401 is definitive — no three-strike wait")
        XCTAssertEqual(model.claudeHeadlinePct, 48, "the old figures stay, labelled")
        // Not a breaker: a new sign-in lands in the Keychain without any
        // click here, so polling must keep going to notice it.
        await model.refreshNow()
        let total = await calls.value
        XCTAssertEqual(total, 2)

        model.claudeFetch = { _ in .usage(reading) }   // signed in again
        await model.refreshNow()
        XCTAssertFalse(model.claudeSignInStale)
    }

    func testARefusedTokenOnTheFirstFetchIsStillReported() async {
        // Started with a dead token: no figures to show, but the state must
        // exist for the footer to hang the card on.
        let model = UsageMeterModel()
        model.claudeFetch = { _ in .unauthorized }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertNil(model.claudeHeadlinePct)
        XCTAssertTrue(model.claudeSignInStale)
    }

    func testOnlyTheExplicitControlMayRaiseTheKeychainPrompt() async {
        // Production floors: opening the card refreshes on the way in, and
        // the permission click comes seconds later. It must still ask.
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 20)
        let asks = AskRecorder()
        model.claudeFetch = { interactive in
            await asks.record(interactive)
            return interactive ? .usage(reading) : .needsPermission
        }
        model.codexFetch = { nil }

        await model.refreshNow()                       // an unattended poll
        var seen = await asks.asks
        XCTAssertEqual(seen, [false])
        XCTAssertTrue(model.claudeNeedsPermission)
        XCTAssertNil(model.claudeHeadlinePct)

        await model.refreshNow()                       // breaker: no second ask
        seen = await asks.asks
        XCTAssertEqual(seen, [false])

        model.manualRefresh()                          // opening the card
        await settle(model)
        seen = await asks.asks
        XCTAssertEqual(seen, [false], "the card's own refresh is floored and never asks")

        model.manualRefresh(retryingCredentials: true) // the refresh control, seconds later
        await settle(model)
        seen = await asks.asks
        XCTAssertEqual(seen, [false, true])
        XCTAssertFalse(model.claudeNeedsPermission)
        XCTAssertEqual(model.claudeHeadlinePct, 20)
    }

    func testAPermissionClickDuringAPollRunsOnceThePollEnds() async {
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 20)
        let asks = AskRecorder()
        model.claudeFetch = { interactive in
            await asks.record(interactive)
            try? await Task.sleep(nanoseconds: 30_000_000)   // a poll long enough to click into
            return interactive ? .usage(reading) : .needsPermission
        }
        model.codexFetch = { nil }

        async let poll: Void = model.refreshNow()
        // Click only once the poll is genuinely in flight.
        for _ in 0..<200 where await asks.asks.isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        model.manualRefresh(retryingCredentials: true)   // lands mid-poll
        await poll
        for _ in 0..<200 where model.claudeHeadlinePct == nil { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
        let seen = await asks.asks
        XCTAssertEqual(seen, [false, true], "the click was held and then asked interactively")
        XCTAssertEqual(model.claudeHeadlinePct, 20)
        XCTAssertFalse(model.claudeNeedsPermission)
    }

    func testSigningOutClearsThePermissionState() async {
        let model = UsageMeterModel()
        model.claudeFetch = { _ in .needsPermission }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertTrue(model.claudeNeedsPermission)
        model.claudeFetch = { _ in .noCredentials }
        model.manualRefresh(retryingCredentials: true)
        await settle(model)
        XCTAssertFalse(model.claudeNeedsPermission, "nothing left to grant permission for")
    }

    func testAnyAnswerFromTheEndpointClearsThePermissionState() async {
        // Permission granted, token then rejected: the card must move on to
        // the sign-in line, not keep saying permission is the problem.
        let model = UsageMeterModel()
        model.claudeFetch = { interactive in interactive ? .unauthorized : .needsPermission }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertTrue(model.claudeNeedsPermission)

        model.manualRefresh(retryingCredentials: true)
        await settle(model)
        XCTAssertFalse(model.claudeNeedsPermission)
        XCTAssertTrue(model.claudeSignInStale)

        // Likewise for a 429 and a plain endpoint failure.
        for outcome in [ClaudeUsageReader.Outcome.rateLimited, .endpointFailure(status: 503)] {
            let m = UsageMeterModel()
            m.claudeFetch = { interactive in interactive ? outcome : .needsPermission }
            m.codexFetch = { nil }
            await m.refreshNow()
            XCTAssertTrue(m.claudeNeedsPermission)
            m.manualRefresh(retryingCredentials: true)
            await settle(m)
            XCTAssertFalse(m.claudeNeedsPermission, "\(outcome)")
        }
    }

    func testRefreshNowIsExclusiveOnceItStarts() async {
        let model = UsageMeterModel()
        let calls = Counter()
        model.claudeFetch = { _ in await calls.bump(); try? await Task.sleep(nanoseconds: 50_000_000); return .noCredentials }
        model.codexFetch = { nil }
        async let a: Void = model.refreshNow()
        async let b: Void = model.refreshNow()
        _ = await (a, b)
        let total = await calls.value
        XCTAssertEqual(total, 1, "the second call found the first in flight and did nothing")
    }

    /// A manual refresh runs in its own Task; give it the turns it needs.
    private func settle(_ model: UsageMeterModel) async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testASecondClickWhileThePromptIsUpDoesNotQueueASecondPrompt() async {
        let model = UsageMeterModel()
        let reading = claude(fiveHour: 20)
        let asks = AskRecorder()
        model.claudeFetch = { interactive in
            await asks.record(interactive)
            try? await Task.sleep(nanoseconds: 30_000_000)   // the prompt is "up"
            return interactive ? .usage(reading) : .needsPermission
        }
        model.codexFetch = { nil }
        async let first: Void = model.refreshNow(interactive: true)
        for _ in 0..<200 where await asks.asks.isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        model.manualRefresh(retryingCredentials: true)   // impatient second click
        await first
        await settle(model)
        let seen = await asks.asks
        XCTAssertEqual(seen, [true], "one prompt, not two")
    }
}
