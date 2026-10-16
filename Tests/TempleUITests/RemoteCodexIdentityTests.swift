import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTerminalAPI

/// New Codex sessions on a host (docs/designs/remote-ssh.md section 3,
/// phase 1b), from the tab's side: a pending run, identified by its process
/// tree or by the user's yes, never guessed; a claim reaches core, or is
/// released with core's reason; a pending tab closes, quits, restores and
/// is discarded without a row ever being made from a handle.
@MainActor
final class RemoteCodexIdentityTests: XCTestCase {
    let hostID = HostID(rawValue: "box")
    var remote: FakeRemoteHost!
    var factory: FakeTerminalSurfaceFactory!
    var model: OpenSessionsModel!
    var persistence: UserDefaultsTabPersistence!
    var joins: [SessionOpen] = []
    var joinAnswer: JoinResult = .joined
    var directories: [(String, HostID, String)] = []
    var notices: [String] = []

    override func setUp() async throws {
        remote = FakeRemoteHost("box")
        factory = FakeTerminalSurfaceFactory()
        persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        makeModel()
    }

    func makeModel(persistence override: TabPersistence? = nil) {
        let remote = self.remote!
        let host = hostID
        model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(gracefulTimeout: 0.3), registry: InMemoryProcessRegistry(),
            persistence: override ?? persistence, launcherForHost: { $0 == host ? remote : nil })
        model.earlyExitGraceSeconds = 0.3
        model.remoteTabs.recordPollDelays = [0.01]
        model.remoteTabs.identitySchedule = [0.02, 0.04]
        model.remoteTabs.identityInterval = 0.05
        model.settleDelaySeconds = 60
        model.openedHandler = { [weak self] open in
            self?.joins.append(open)
            return self?.joinAnswer ?? .joined
        }
        model.launchDirectoryHandler = { [weak self] id, host, directory in self?.directories.append((id, host, directory)) }
        model.remoteTabs.noticeHandler = { [weak self] _, message in self?.notices.append(message) }
    }

    private func settle(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func newCodex() async -> SessionTab {
        let tab = model.newSession(agent: .codex, project: Fixture.key("~/project", host: hostID))
        await settle(tab.hasLiveProcess, "the pending run's tab connects")
        return tab
    }

    private func suggestion(_ id: String = "c7", prompt: String? = "reply with the word ok") -> RemoteSuggestion {
        RemoteSuggestion(rolloutPath: "/home/u/.codex/sessions/2026/10/16/rollout-2026-10-16T10-18-52-\(id).jsonl",
                         sessionID: id, firstPrompt: prompt, startedAt: Date(), directory: "/home/u/project")
    }

    // MARK: Starting and identifying

    /// A new Codex session is a pending run: no id, nothing in core, the
    /// agent's argv without one. Once its `ok` arrives the schedule checks
    /// its process tree; a verified id joins core (created, Codex), records
    /// the pane's folder on the row, and the tab becomes that session.
    func testANewCodexSessionIsPendingThenAdoptedByItsProcessTree() async throws {
        remote.identityAnswers = [.inconclusive("no session file is open right now", lasting: false, ended: false)]
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        XCTAssertNil(tab.sessionID)
        XCTAssertEqual(remote.pendingOpens.first?.handle, nil)
        XCTAssertEqual(remote.pendingOpens.first?.directory, "~/project")
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "create", "p1"])
        XCTAssertEqual(tab.displayArgv, ["codex"])
        XCTAssertTrue(joins.isEmpty, "nothing reaches core before the id is known")
        XCTAssertTrue(persistence.load().isEmpty, "a pending tab has no open_tabs row")
        await settle(tab.sessionID == "c9", "adopted on schedule")
        XCTAssertEqual(remote.identifies.count, 2)
        XCTAssertEqual(joins.map(\.id), ["c9"])
        XCTAssertEqual(joins.first?.via, .created)
        XCTAssertEqual(joins.first?.agent, .codex)
        XCTAssertEqual(directories.last?.0, "c9")
        XCTAssertEqual(directories.last?.2, "/home/u/project")
        XCTAssertFalse(tab.isProvisional)
        XCTAssertEqual(persistence.load().map(\.sessionID), ["c9"])
        await settle(self.remote.joinedMarks == ["p1"])
        // Settled: nothing more is asked.
        let asked = remote.identifies.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(remote.identifies.count, asked)
    }

    /// Inconclusive and nothing typed: nobody is asked anything. Once
    /// something was typed, the suggestions come; a decline removes one for
    /// good; a yes claims and adopts.
    func testTheQuestionComesAfterTheFirstPromptAndAYesAdopts() async throws {
        remote.suggestionsResult = .candidates([suggestion("c7"), suggestion("c8", prompt: nil)])
        let tab = await newCodex()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(remote.suggestionLookups.isEmpty, "no question before anything was typed")
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 2)
        XCTAssertEqual(RemoteCopy.suggestionQuestion(suggestion("c8", prompt: nil)).hasPrefix("Is this the session? (no prompt), started at "), true)
        model.remoteTabs.decline(try XCTUnwrap(tab.remote?.suggestions.last), in: tab)
        XCTAssertEqual(tab.remote?.suggestions.map(\.sessionID), ["c7"])
        await settle(self.remote.declines.map(\.path) == [self.suggestion("c8").rolloutPath])
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.sessionID == "c7")
        XCTAssertEqual(remote.confirms.map(\.sessionID), ["c7"])
        XCTAssertEqual(joins.map(\.id), ["c7"])
        XCTAssertEqual(tab.remote?.suggestions, [])
    }

    /// No /proc (a macOS host) or a shared Codex server: suggest-only from
    /// the first check.
    func testALastingInconclusiveAsksAtOnce() async throws {
        remote.identityResult = .inconclusive("this host has no /proc", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        await settle(tab.remote?.suggestions.count == 1)
    }

    /// Core refuses the id (another host's, or another agent's): the claim
    /// is released, the tab stays pending and says core's reason.
    func testACoreRefusalReleasesTheClaimAndSaysWhy() async throws {
        joinAnswer = .refused(.host(HostID(rawValue: "jet")))
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.remote?.identityNote != nil)
        XCTAssertNil(tab.sessionID)
        XCTAssertEqual(tab.remote?.identityNote, JoinConflict.host(HostID(rawValue: "jet")).message)
        await settle(self.remote.released.map(\.sessionID).contains("c9"))
        XCTAssertTrue(remote.joinedMarks.isEmpty)
    }

    /// An id another run holds is refused: the tab says Temple couldn't
    /// tell, and keeps asking.
    func testAnIDAnotherRunHoldsIsRefused() async throws {
        remote.identityResult = .taken
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        await settle(tab.remote?.identityNote == RemoteCopy.couldNotTell)
        XCTAssertNil(tab.sessionID)
        // A yes that turns out taken says the same, and drops that candidate.
        remote.confirmResult = .taken
        await settle(tab.remote?.suggestions.count == 1)
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.remote?.confirming == nil && tab.remote?.suggestions.isEmpty == true)
        XCTAssertNil(tab.sessionID)
    }

    // MARK: Ending, closing, quitting

    /// Codex finished before its id was learned: something was typed, so
    /// the tab stays and asks; nothing typed, it closes and Temple stops
    /// tracking it. Never a row from a handle.
    func testACodexThatFinishedUnidentifiedAsksOrGoes() async throws {
        remote.suggestionsResult = .candidates([suggestion()])
        let typed = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(typed.surface))
        try await Task.sleep(for: .milliseconds(400))
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 0)
        await settle(typed.remote?.phase == .endedPending)
        await settle(typed.remote?.suggestions.count == 1)
        XCTAssertTrue(joins.isEmpty)

        let untouched = await newCodex()
        try await Task.sleep(for: .milliseconds(400))
        factory.created.last?.simulateExit(status: 0)
        await settle(!self.model.tabs.contains { $0 === untouched })
        await settle(self.remote.dismissedRuns == ["p2"])
    }

    /// An idle close of a pending tab checks its identity once more while
    /// its agent runs, then stops it; identified, the tab closes like any.
    func testClosingAPendingTabChecksOnceMoreThenStops() async throws {
        model.remoteTabs.identitySchedule = [60]
        let tab = await newCodex()
        remote.identityResult = .adopted("c5", directory: "/home/u/project")
        remote.identityGate = { try? await Task.sleep(for: .milliseconds(1)) }
        tab.activity = .idle
        model.closeTab(tab.id)
        await settle(!self.model.tabs.contains { $0 === tab })
        XCTAssertEqual(remote.stops.map(\.handle), ["p1"])
        XCTAssertTrue(joins.map(\.id).contains("c5"), "learned at the close, it joined core")
    }

    /// Closed unidentified after something was typed: the tab stays with
    /// the question; nothing typed: it goes and is no longer tracked.
    func testClosingAnUnidentifiedPendingTab() async throws {
        remote.identityResult = .inconclusive("no session file is open right now", lasting: false, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let typed = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(typed.surface))
        typed.activity = .idle
        model.closeTab(typed.id)
        await settle(typed.remote?.phase == .endedPending)
        XCTAssertTrue(model.tabs.contains { $0 === typed })
        await settle(typed.remote?.suggestions.count == 1)
        XCTAssertTrue(remote.dismissedRuns.isEmpty)
        // Closing that again is being done with it.
        model.closeTab(typed.id)
        await settle(!self.model.tabs.contains { $0 === typed })
        await settle(self.remote.dismissedRuns == ["p1"])

        let untouched = await newCodex()
        untouched.activity = .idle
        model.closeTab(untouched.id)
        await settle(!self.model.tabs.contains { $0 === untouched })
        await settle(self.remote.dismissedRuns.contains("p2"))
    }

    /// Detach keeps it running: its tab closes, its run is listed (not
    /// restored as a chip), and Sessions on <host> opens it again.
    func testDetachingAPendingTabAndOpeningItFromTheSheet() async throws {
        let tab = await newCodex()
        tab.activity = .running
        model.requestClose(tabID: tab.id)
        XCTAssertEqual(model.pendingRemoteCloseTabID, tab.id)
        model.remoteTabs.confirmDetach()
        await settle(!self.model.tabs.contains { $0 === tab })
        await settle(self.remote.closedPending == ["p1"])
        XCTAssertTrue(remote.stops.isEmpty)
        model.remoteTabs.openPendingRun(handle: "p1", host: hostID, directory: "/home/u/project")
        let reopened = try XCTUnwrap(model.activeTab)
        await settle(reopened.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "p1"])
        XCTAssertNil(reopened.sessionID)
    }

    /// A quit treats a pending run as any (round 1): a working agent is
    /// detached, an idle one stopped. Stopped, one that was typed into keeps
    /// its ended run for the next launch's question; one never typed into
    /// is no longer tracked.
    func testAQuitDetachesWorkingAndStopsIdlePendingRuns() async throws {
        let working = await newCodex()
        let typed = await newCodex()
        let untouched = await newCodex()
        working.activity = .running
        model.surfaceDidSubmitInput(try XCTUnwrap(typed.surface))
        typed.activity = .idle
        untouched.activity = .idle
        model.prepareForQuit()
        let plan = model.quitDrainPlan()
        XCTAssertEqual(plan.detach.count, 1, "the working one is detached")
        await settle(Set(self.remote.stops.map(\.handle)) == ["p2", "p3"], "the idle ones are stopped")
        await settle(self.remote.dismissedRuns == ["p3"], "only the one never typed into is let go")
        XCTAssertEqual(remote.inputs, ["p2"])
    }

    /// A stop at the quit that fails leaves it running, as any, and is never
    /// tried again.
    func testAFailedQuitStopIsNotRetried() async throws {
        let tab = await newCodex()
        tab.activity = .idle
        remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: nil)
        model.prepareForQuit()
        _ = model.quitDrainPlan()
        await settle(self.remote.stops.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(remote.stops.count, 1)
        XCTAssertTrue(remote.dismissedRuns.isEmpty)
    }

    // MARK: Round 1 fixes

    /// Input is kept with the run, once; a restored chip of a run typed into
    /// knows it (its question still comes, and a close keeps it).
    func testInputEvidenceSurvivesARelaunch() async throws {
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(self.remote.inputs == ["p1"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(remote.inputs, ["p1"], "kept once")
        // A relaunch: the chip of that run knows it was typed into.
        makeModel()
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let restored = try XCTUnwrap(model.tabs.first)
        XCTAssertTrue(restored.inputSubmitted)
        remote.identityResult = .inconclusive("no session file is open right now", lasting: false, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        model.activate(restored)
        await settle(restored.hasLiveProcess)
        await settle(restored.remote?.suggestions.count == 1, "typed before the relaunch: asked")
    }

    /// Confirming an ended session records who it was and nothing else: an
    /// inert tab of that session; Resume (the user's) resumes it.
    func testAYesForAnEndedSessionNeverResumesByItself() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([suggestion("c7")])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let tab = try XCTUnwrap(model.tabs.first)
        model.activate(tab)
        await settle(tab.remote?.suggestions.count == 1)
        let created = factory.created.count
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.sessionID == "c7")
        XCTAssertEqual(tab.remote?.phase, .endedIdentified)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(factory.created.count, created, "nothing started")
        XCTAssertTrue(remote.opens.isEmpty)
        model.remoteTabs.reconnect(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(remote.opens.last?.sessionID, "c7")
        XCTAssertEqual(remote.opens.last?.resume, true)
    }

    /// A pending run another Temple identified meanwhile opens as that
    /// session (joined, then attached), never stuck opening.
    func testAPendingRunIdentifiedElsewhereOpensAsThatSession() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", sessionID: "c3")]
        model.remoteTabs.openPendingRun(handle: "p7", host: hostID, directory: "/home/u/project")
        let tab = try XCTUnwrap(model.activeTab)
        await settle(tab.hasLiveProcess, "opened as the session")
        XCTAssertEqual(tab.sessionID, "c3")
        XCTAssertEqual(joins.first?.id, "c3")
        XCTAssertEqual(joins.first?.via, .created, "joined as the claim it is, then opened")
        XCTAssertEqual(remote.opens.last?.sessionID, "c3")
    }

    /// A core join that fails is not a join: the claim stays unjoined, the
    /// tab stays pending and says so, and the next check joins it.
    func testAFailedCoreJoinIsNotAJoin() async throws {
        joinAnswer = .failed(CocoaError(.fileWriteUnknown))
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.remote?.identityNote != nil)
        XCTAssertNil(tab.sessionID)
        XCTAssertTrue(remote.joinedMarks.isEmpty)
        XCTAssertTrue(remote.released.isEmpty, "not a refusal: the claim stands")
        joinAnswer = .joined
        remote.identityResult = .known("c9", directory: "/home/u/project")
        await settle(tab.sessionID == "c9")
        await settle(self.remote.joinedMarks == ["p1"])
        // Reconciliation: a failed join leaves the claim for the next launch.
        remote.unjoined = [("p5", "c5", nil)]
        joinAnswer = .failed(CocoaError(.fileWriteUnknown))
        model.remoteTabs.reconcileClaims(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(remote.joinedMarks, ["p1"])
        XCTAssertFalse(remote.released.contains { $0.sessionID == "c5" })
    }

    /// A tab that becomes its session hands its run over to open_tabs, but
    /// only once the tab set is written (round 2).
    func testAHandOverWaitsForTheTabSetToBeWritten() async throws {
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        await settle(self.remote.closedPending == ["p1"], "handed over")

        let failing = FailingTabPersistence()
        makeModel(persistence: failing)
        let second = await newCodex()
        remote.identityResult = .adopted("c10", directory: "/home/u/project")
        await settle(second.sessionID == "c10")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(remote.closedPending.contains("p2"), "the run stays what restores the tab")
    }

    /// At launch, reconciliation decides each claimed run's chip (round 2):
    /// joined, that session's chip, then handed over; refused, released and
    /// restored by its handle as pending; failed, claimed but unjoined,
    /// restored by its handle too (and joined when it is opened).
    func testRestoreFollowsReconciliation() async throws {
        remote.pending = [.init(handle: "p5", directory: "/home/u/late", sessionID: "c5", claimed: true),
                          .init(handle: "p6", directory: "/home/u/refused", sessionID: "c6", claimed: true),
                          .init(handle: "p7", directory: "/home/u/failed", sessionID: "c7", claimed: true),
                          .init(handle: "p8", directory: "/home/u/old", sessionID: "c8", claimed: true, joined: true)]
        remote.unjoined = [("p5", "c5", "/home/u/late"), ("p6", "c6", nil), ("p7", "c7", nil)]
        var answers: [String: JoinResult] = ["c6": .refused(.agent(.claude)), "c7": .failed(CocoaError(.fileWriteUnknown))]
        model.openedHandler = { [weak self] open in
            self?.joins.append(open)
            return answers.removeValue(forKey: open.id) ?? .joined
        }
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 4)
        XCTAssertEqual(model.tabs.first { $0.projectPath == "/home/u/late" }?.sessionID, "c5")
        XCTAssertEqual(model.tabs.first { $0.projectPath == "/home/u/old" }?.sessionID, "c8")
        let refused = try XCTUnwrap(model.tabs.first { $0.projectPath == "/home/u/refused" })
        XCTAssertNil(refused.sessionID)
        XCTAssertEqual(refused.remote?.handle, "p6")
        let failed = try XCTUnwrap(model.tabs.first { $0.projectPath == "/home/u/failed" })
        XCTAssertNil(failed.sessionID)
        XCTAssertEqual(failed.remote?.handle, "p7")
        await settle(Set(self.remote.closedPending) == ["p5", "p8"], "only accepted claims are handed over")
        XCTAssertEqual(remote.released.map(\.sessionID), ["c6"])
        XCTAssertTrue(persistence.load().contains { $0.sessionID == "c5" })
    }

    /// A chip restored at launch and never opened is never stopped by the
    /// quit (round 2): a stop that failed before the relaunch, or a session
    /// detached while working, keeps running.
    func testARestoredChipNeverOpenedIsNotStoppedAtQuit() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project"),
                          .init(handle: "p8", directory: "/home/u/other", typed: true)]
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 2)
        model.prepareForQuit()
        let plan = model.quitDrainPlan()
        XCTAssertTrue(plan.detach.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(remote.stops.isEmpty, "nothing this launch didn't attach to is stopped")
        XCTAssertTrue(remote.dismissedRuns.isEmpty)
    }

    /// Input evidence is committed only once written; a failed write is
    /// tried again (bounded), then said, and the next Return tries afresh.
    func testInputEvidenceIsCommittedOnlyOnceWritten() async throws {
        model.remoteTabs.inputWriteRetries = [0.01, 0.01]
        remote.inputFailures = 5
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(self.notices.count == 1, "three tries, then said")
        XCTAssertEqual(remote.inputs.count, 3)
        XCTAssertFalse(model.remoteTabs.inputCommitted("p1"))
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(self.model.remoteTabs.inputCommitted("p1"), "the next Return tries afresh")
        XCTAssertEqual(remote.inputs.count, 6, "two more failures, then written")
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(remote.inputs.count, 6, "committed: not written again")
    }

    /// A core refusal is remembered (round 2): the schedule doesn't claim
    /// and release the same id every minute; Try again, or the conflicting
    /// row going away, lets it be claimed once more.
    func testACoreRefusalIsRememberedUntilTryAgain() async throws {
        joinAnswer = .refused(.host(HostID(rawValue: "jet")))
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        remote.suggestionsResult = .candidates([suggestion("c9"), suggestion("c8")])
        let tab = await newCodex()
        await settle(tab.remote?.identityRefused == true)
        let asked = remote.identifies.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(remote.identifies.count, asked, "not claimed again on schedule")
        XCTAssertEqual(remote.released.count, 1)
        await settle(tab.remote?.suggestions.map(\.sessionID) == ["c8"], "the refused id is not offered")
        joinAnswer = .joined
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.sessionID == "c9", "Try again claims it anew")
    }

    func testAConflictingRowGoingAwayLiftsTheRefusal() async throws {
        var rows: [String: Session] = ["c9": Fixture.row("c9", agent: .codex, project: "/x", host: HostID(rawValue: "jet"))]
        model.sessionRow = { rows[$0] }
        joinAnswer = .refused(.host(HostID(rawValue: "jet")))
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.remote?.identityRefused == true)
        let asked = remote.identifies.count
        model.rowsChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(remote.identifies.count, asked, "still there: still refused")
        rows = [:]
        joinAnswer = .joined
        model.rowsChanged()
        await settle(tab.sessionID == "c9", "the row went: claimed on the next check")
    }

    /// A pending run's own write that fails is said once, never swallowed.
    func testAFailedPendingWriteIsSaid() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true)]
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        remote.dismissRunError = CocoaError(.fileWriteUnknown)
        model.closeTab(try XCTUnwrap(model.tabs.first).id)
        await settle(self.notices.count == 1)
        XCTAssertTrue(notices.first?.hasPrefix("Temple couldn't save what happened") == true)
    }

    // MARK: Restore, Start a new session, Discard, reconciliation

    /// Pending runs come back as chips from the runs alone (no open_tabs
    /// row): one that runs attaches when activated; one that ended asks.
    func testPendingChipsRestoreFromTheirRuns() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project"),
                          .init(handle: "p8", directory: "/home/u/other", ended: true),
                          .init(handle: "p9", directory: "/home/u/closed", tabClosed: true)]
        remote.suggestionsResult = .candidates([suggestion()])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 2)
        let running = try XCTUnwrap(model.tabs.first { $0.remote?.handle == "p7" })
        let ended = try XCTUnwrap(model.tabs.first { $0.remote?.handle == "p8" })
        XCTAssertEqual(running.title, Agent.codex.newSessionTitle)
        XCTAssertEqual(running.projectKey, Fixture.key("/home/u/project", host: hostID))
        XCTAssertFalse(running.hasSurface, "an inert chip")
        model.activate(running)
        await settle(running.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv, ["ssh", "attach", "p7"])
        await settle(!self.remote.identifies.isEmpty, "a reattached pending run is checked at once")
        model.activate(ended)
        await settle(ended.remote?.phase == .endedPending && ended.remote?.suggestions.count == 1)
        // Restoring twice adds nothing.
        model.remoteTabs.restorePending(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.tabs.count, 2)
    }

    /// Start a new session from an ended pending tab: a new run in the same
    /// tab, the old one dismissed. Discard: the tab goes, the run is
    /// dismissed; a write that fails is said once.
    func testStartANewSessionAndDiscardForAnEndedPendingTab() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true),
                          .init(handle: "p8", directory: "/home/u/project", ended: true)]
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 2)
        let first = try XCTUnwrap(model.tabs.first { $0.remote?.handle == "p7" })
        model.remoteTabs.startNewPending(first)
        await settle(first.hasLiveProcess)
        XCTAssertEqual(factory.created.last?.startedCommand?.argv.prefix(2), ["ssh", "create"])
        XCTAssertNotEqual(first.remote?.handle, "p7")
        await settle(self.remote.dismissedRuns == ["p7"])

        let second = try XCTUnwrap(model.tabs.first { $0.remote?.handle == "p8" })
        remote.dismissRunError = CocoaError(.fileWriteUnknown)
        model.remoteTabs.discardPending(second)
        XCTAssertFalse(model.tabs.contains { $0 === second })
        await settle(self.notices.count == 1)
    }

    /// At launch, a claim whose join never happened joins core (and its
    /// folder is recorded); one core refuses is released.
    func testReconciliationJoinsClaimsThatNeverReachedCore() async throws {
        remote.unjoined = [("p1", "c1", "/home/u/a"), ("p2", "c2", nil)]
        var answers: [String: JoinResult] = ["c2": .refused(.agent(.claude))]
        model.openedHandler = { [weak self] open in
            self?.joins.append(open)
            return answers.removeValue(forKey: open.id) ?? .joined
        }
        model.remoteTabs.reconcileClaims(hosts: [hostID])
        await settle(self.remote.joinedMarks == ["p1"] && self.remote.released.map(\.sessionID) == ["c2"])
        XCTAssertEqual(joins.map(\.id), ["c1", "c2"])
        XCTAssertEqual(directories.map(\.0), ["c1"])
    }

    // MARK: Copy

    /// The "left running" notice and the sheet's line come from one place;
    /// no user-facing remote copy carries an em-dash.
    func testTheCopyIsOneSourceAndHasNoEmDash() {
        for reason in [RemoteLeftRunningReason.hostDidNotAnswer, .anotherClientAttached] {
            XCTAssertTrue(RemoteCopy.leftRunning("box", agent: .codex, reason: reason, detail: nil)
                .hasPrefix(RemoteCopy.leftRunningLine("box", reason: reason)))
        }
        XCTAssertEqual(RemoteCopy.noTrackedSessions, "No sessions started from Temple.")
        let unread = RemoteSuggestion(rolloutPath: "/r", sessionID: "x", firstPrompt: nil, startedAt: Date(),
                                      directory: "/w", promptKnown: false)
        XCTAssertTrue(RemoteCopy.suggestionQuestion(unread).hasPrefix("Is this the session? (its first prompt couldn't be read), started "))
        XCTAssertFalse(RemoteCopy.suggestionQuestion(unread).contains("(no prompt)"))
        let copy = [RemoteCopy.codexEndedPending("box"), RemoteCopy.couldNotTell, RemoteCopy.noDaemonHint,
                    RemoteCopy.endedIdentified("box"), RemoteCopy.resumeAnyway("box"),
                    RemoteCopy.startNewPending("box"), RemoteCopy.stopHint("box"), RemoteCopy.discardHelp(archives: true),
                    RemoteCopy.discardHelp(archives: false), RemoteCopy.discardPendingHelp("box"),
                    RemoteCopy.suggestionQuestion(suggestion()), RemoteCopy.noTrackedSessions,
                    RemoteCopy.leftRunning("box", agent: .codex, reason: .hostDidNotAnswer, detail: nil),
                    RemoteCopy.leftRunningLine("box", reason: .quitDeadline), RemoteCopy.disconnected("box"),
                    RemoteCopy.unknown("box", agent: .codex, reason: "x"), RemoteCopy.stillConnecting("box")]
        for line in copy { XCTAssertFalse(line.contains("\u{2014}"), line) }
    }
}

/// A tab store whose writes fail (and say so).
final class FailingTabPersistence: TabPersistence {
    func load() -> [PersistedTab] { [] }
    func save(_ tabs: [PersistedTab]) {}
    func saveAcknowledged(_ tabs: [PersistedTab]) -> Bool { false }
}
