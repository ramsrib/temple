import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class NotificationStateTests: XCTestCase {

    func testBellOnBackgroundTabRaisesAttention() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired: (title: String, body: String)?
        model.attentionHandler = { _, title, body in fired = (title, body) }

        model.openSession(Fixture.row("a", project: "/p/a"))
        model.openSession(Fixture.row("b", project: "/p/b"))  // b is now active
        let aSurface = model.openTab(forSessionID: "a")?.surface as? FakeTerminalSurface

        aSurface?.simulateBell()

        XCTAssertEqual(model.openTab(forSessionID: "a")?.activity, .needsAttention)
        XCTAssertNotNil(fired)
    }

    func testNotificationOnBackgroundTabForwardsMessage() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired: (title: String, body: String)?
        model.attentionHandler = { _, title, body in fired = (title, body) }

        model.openSession(Fixture.row("a", project: "/p/a"))
        model.openSession(Fixture.row("b", project: "/p/b"))
        let aSurface = model.openTab(forSessionID: "a")?.surface as? FakeTerminalSurface

        aSurface?.simulateNotification(title: "Done", body: "Task complete")

        XCTAssertEqual(fired?.title, "Done")
        XCTAssertEqual(fired?.body, "Task complete")
        XCTAssertEqual(model.openTab(forSessionID: "a")?.activity, .needsAttention)
    }

    func testBellOnActiveTabSettlesToIdle() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired = false
        model.attentionHandler = { _, _, _ in fired = true }

        model.openSession(Fixture.row("a", project: "/p/a"))  // a is active
        let aSurface = model.activeTab?.surface as? FakeTerminalSurface

        aSurface?.simulateBell()  // agent finished while you're watching

        XCTAssertFalse(fired)                                 // not attention
        XCTAssertEqual(model.activeTab?.activity, .idle)      // at rest, not running
    }

    func testActivatingClearsAttentionToIdle() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        model.openSession(Fixture.row("b", project: "/p/b"))
        let aTab = model.openTab(forSessionID: "a")!
        (aTab.surface as? FakeTerminalSurface)?.simulateBell()
        XCTAssertEqual(aTab.activity, .needsAttention)

        model.activate(aTab)
        XCTAssertEqual(aTab.activity, .idle)   // agent already stopped; now resting
    }

    func testTitleUpdateFromDelegate() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a", title: "Old"))
        let s = model.activeTab?.surface as? FakeTerminalSurface
        s?.simulateTitle("New Title")
        XCTAssertEqual(model.activeTab?.title, "New Title")
    }

    // MARK: - Item E: busy-vs-idle state machine

    func testSpawnStartsRunning() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        XCTAssertEqual(model.activeTab?.activity, .running)
    }

    func testSubmitInputMarksRunning() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        let surface = tab.surface as? FakeTerminalSurface
        // Settle it to idle first, then a Return re-arms it to running.
        surface?.simulateBell()
        XCTAssertEqual(tab.activity, .idle)

        surface?.simulateSubmitInput()
        XCTAssertEqual(tab.activity, .running)
    }

    func testBellOnBackgroundTabIsAttentionNotIdle() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        model.openSession(Fixture.row("b", project: "/p/b"))  // b active
        let a = model.openTab(forSessionID: "a")?.surface as? FakeTerminalSurface
        a?.simulateBell()
        XCTAssertEqual(model.openTab(forSessionID: "a")?.activity, .needsAttention)
    }

    func testSettleDecaysRunningToIdleWhenQuiet() async {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.settleDelaySeconds = 0.05
        model.titleQuietWindow = 0.01
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        XCTAssertEqual(tab.activity, .running)

        try? await Task.sleep(nanoseconds: 150_000_000)  // > settleDelay
        XCTAssertEqual(tab.activity, .idle)              // decayed on its own
    }

    /// A tab on this Mac closes exactly as in v0.5.2: a running agent asks
    /// until the settle timer idles it, however quiet its title and whether
    /// or not anything was sent (the early rest rule is for tabs on a host).
    func testALocalCloseKeepsTheTimersReadingAsBeforeRemote() async {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.titleQuietWindow = 0.05
        model.settleDelaySeconds = 60
        model.openSession(Fixture.row("a", project: "/p/a"))
        let booted = model.activeTab!
        XCTAssertEqual(booted.activity, .running)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.isAtRestNow(booted), "never early on this Mac")
        model.requestClose(tabID: booted.id)
        XCTAssertEqual(model.pendingCloseTabID, booted.id, "booted, quiet, nothing sent: still asks, as before")
        XCTAssertEqual(booted.activity, .running, "asking changed nothing")
        model.cancelPendingClose()
        for (id, input) in [("b", "key"), ("c", "click"), ("d", "return")] {
            model.openSession(Fixture.row(id, project: "/p/\(id)"))
            let tab = model.activeTab!
            let surface = tab.surface as? FakeTerminalSurface
            switch input {
            case "key": surface?.simulateInput()
            case "click": surface?.simulateClick(captured: true)
            default: surface?.simulateSubmitInput()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            model.requestClose(tabID: tab.id)
            XCTAssertEqual(model.pendingCloseTabID, tab.id, "\(id): asks while running")
            model.cancelPendingClose()
        }

        // Once the timer settles it, it closes without asking.
        let timed = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        timed.settleDelaySeconds = 0.05
        timed.titleQuietWindow = 0.01
        timed.openSession(Fixture.row("e", project: "/p/e"))
        let settled = timed.activeTab!
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(settled.activity, .idle)
        timed.requestClose(tabID: settled.id)
        XCTAssertNil(timed.pendingCloseTabID)
    }

    /// On this Mac a pwd stand-in title is a title, as in v0.5.2: shown on
    /// the tab, handed up for the row, and a wake from idle. (On a host it
    /// is this Mac's home and is never shown; RemoteLifecycleTests.)
    func testALocalStandInTitleIsShownAndKeptAsBeforeRemote() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.ringGraceSeconds = -1
        var recorded: [String: String] = [:]
        model.titleHandler = { recorded[$0] = $2 }
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        let surface = tab.surface as? FakeTerminalSurface
        surface?.simulateTitle("Agent title")
        surface?.simulateBell()
        XCTAssertEqual(tab.activity, .idle)
        surface?.simulateStandInTitle("/p/a")
        XCTAssertEqual(tab.activity, .running, "a wake, as any title change")
        XCTAssertEqual(tab.title, "/p/a", "shown, as libghostty titled it")
        XCTAssertEqual(recorded, ["a": "/p/a"], "kept, as before")
    }

    func testTitleMovementPromotesIdleBackToRunning() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.ringGraceSeconds = -1  // out of grace immediately
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        let surface = tab.surface as? FakeTerminalSurface
        surface?.simulateBell()
        XCTAssertEqual(tab.activity, .idle)

        // The agent resumed with no Return through this surface (single-key
        // permission answer, mouse click, self-wakeup) — its moving title is
        // the only signal.
        surface?.simulateTitle("✳ Thinking…")
        XCTAssertEqual(tab.activity, .running)
    }

    func testFinishingRetitleInsideRingGraceStaysIdle() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        let surface = tab.surface as? FakeTerminalSurface
        surface?.simulateBell()
        XCTAssertEqual(tab.activity, .idle)

        // work → bell → the agent resets its own title: not new work.
        surface?.simulateTitle("~/p/a")
        XCTAssertEqual(tab.activity, .idle)
    }

    func testTitleMovementDoesNotClearAttention() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.ringGraceSeconds = -1
        model.openSession(Fixture.row("a", project: "/p/a"))
        model.openSession(Fixture.row("b", project: "/p/b"))  // b active
        let a = model.openTab(forSessionID: "a")!
        (a.surface as? FakeTerminalSurface)?.simulateBell()
        XCTAssertEqual(a.activity, .needsAttention)

        // Attention is sticky: a title twitch must not silently clear a
        // prompt the user hasn't seen.
        (a.surface as? FakeTerminalSurface)?.simulateTitle("✳ Thinking…")
        XCTAssertEqual(a.activity, .needsAttention)
    }

    func testCloseGatePromptsOnlyWhenRunning() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.row("a", project: "/p/a"))
        let tab = model.activeTab!
        // Idle after a bell → closes immediately, no prompt.
        (tab.surface as? FakeTerminalSurface)?.simulateBell()
        XCTAssertEqual(tab.activity, .idle)
        model.requestClose(tabID: tab.id)
        XCTAssertNil(model.pendingCloseTabID)
        XCTAssertTrue(model.tabs.isEmpty)
    }
}
