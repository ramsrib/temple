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

    /// Whether the host is in the registry (removed: no launcher for it).
    var hostEnabled = true
    /// The host's launcher after an edit (a new connection context).
    var replacement: FakeRemoteHost?

    func makeModel(persistence override: TabPersistence? = nil) {
        let remote = self.remote!
        let host = hostID
        model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
            runtime: SessionRuntimeController(gracefulTimeout: 0.3), registry: InMemoryProcessRegistry(),
            persistence: override ?? persistence,
            launcherForHost: { [weak self] in
                guard $0 == host, self?.hostEnabled != false else { return nil }
                return self?.replacement ?? remote
            })
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

    /// B1 again: until Codex titles itself, tmux sends an empty title (the
    /// terminal reports it empty, never this Mac's folder): the pending tab
    /// keeps "New Codex session", and the title still counts as tmux
    /// drawing (no "Still connecting").
    func testAPendingTabKeepsItsTitleThroughTmuxsEmptyOne() async throws {
        model.remoteTabs.startupEvidenceDeadline = 0.2
        let tab = await newCodex()
        let surface = try XCTUnwrap(factory.created.last)
        surface.simulateTitle("")
        XCTAssertEqual(tab.title, Agent.codex.newSessionTitle)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tab.remote?.stillConnecting, false, "an empty title from tmux is a sign of life")
        surface.simulateTitle("project")
        XCTAssertEqual(tab.title, "project", "Codex's own title")
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
        XCTAssertEqual(RemoteCopy.suggestionQuestion(suggestion("c8", prompt: nil)).hasPrefix("Is this the session? No prompt yet, started in "), true)
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

    /// Two rollouts whose paths differ only in normalization (a precomposed
    /// and a decomposed folder, which the host keeps apart) are two
    /// suggestions: declining one leaves the other, and only its bytes are
    /// declined.
    func testSpellingsTheHostKeepsApartAreTwoSuggestions() async throws {
        let composed = RemoteSuggestion(rolloutPath: "/home/u/.codex/sessions/caf\u{E9}/rollout-a.jsonl", sessionID: "ca",
                                        firstPrompt: "one", startedAt: Date(), directory: "/home/u/project")
        let decomposed = RemoteSuggestion(rolloutPath: "/home/u/.codex/sessions/cafe\u{301}/rollout-a.jsonl", sessionID: "cb",
                                          firstPrompt: "two", startedAt: Date(), directory: "/home/u/project")
        XCTAssertEqual(composed.rolloutPath, decomposed.rolloutPath, "Swift calls the two spellings equal")
        XCTAssertNotEqual(composed.id, decomposed.id)
        remote.suggestionsResult = .candidates([composed, decomposed])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 2)
        model.remoteTabs.decline(decomposed, in: tab)
        XCTAssertEqual(tab.remote?.suggestions.map(\.sessionID), ["ca"])
        await settle(self.remote.declines.count == 1)
        XCTAssertEqual(remote.declines.map { Array($0.path.utf8) }, [Array(decomposed.rolloutPath.utf8)])
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
        // The host leaves a held id out of its suggestions from then on.
        remote.suggestionsResult = .candidates([])
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.remote?.confirming == nil && tab.remote?.suggestions.isEmpty == true)
        XCTAssertNil(tab.sessionID)
    }

    // MARK: A lone candidate: Temple's own yes (owner, round 2)

    /// Exactly one eligible candidate for a connected run that was typed
    /// into: Temple says yes through the yes's own path (an automatic
    /// claim, the host's recheck, core's join), and the tab says it linked
    /// on its own, with Discard.
    func testALoneCandidateIsLinkedThroughTheYesPath() async throws {
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.sessionID == "c7", "linked on its own")
        XCTAssertEqual(remote.automaticConfirms.map(\.sessionID), ["c7"])
        XCTAssertTrue(remote.confirms.isEmpty, "no yes of the user's")
        XCTAssertEqual(joins.map(\.id), ["c7"])
        XCTAssertFalse(tab.isProvisional)
        XCTAssertEqual(tab.remote?.suggestions, [], "no question")
        XCTAssertEqual(tab.remote?.linkedOnItsOwn, true)
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.linkedOnItsOwn(suggestion()))
        XCTAssertEqual(persistence.load().map(\.sessionID), ["c7"])
    }

    /// Two new Codex tabs in one folder, typed into within seconds (the
    /// computer-use pass on dd60e31): each saw one candidate, which may be
    /// the other's. While another of Temple's new sessions there is still
    /// unidentified, neither says yes on its own: both ask.
    func testTwoNewSessionsInOneFolderBothAsk() async throws {
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let first = await newCodex()
        let second = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(first.surface))
        model.surfaceDidSubmitInput(try XCTUnwrap(second.surface))
        await settle(first.remote?.suggestions.count == 1 && second.remote?.suggestions.count == 1, "both ask")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(remote.automaticConfirms.isEmpty)
        XCTAssertNil(first.sessionID)
        XCTAssertNil(second.sessionID)
        // A new session in another folder is no neighbour.
        let elsewhere = model.newSession(agent: .codex, project: Fixture.key("~/other", host: hostID))
        await settle(elsewhere.hasLiveProcess)
        XCTAssertNil(first.sessionID)
    }

    /// A neighbour whose pane has not reported its folder yet (`~/p` before
    /// it resolves) counts as the same folder: no yes on Temple's own.
    /// (Resolved folders in different places: `testTwoNewSessionsInOneFolderBothAsk`
    /// and the store test.)
    func testANeighbourWithAnUnresolvedFolderBlocksTheAutomaticYes() async throws {
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        await settle(tab.launchObservation?.directory == "/home/u/project")
        remote.collectResult = .nothing   // the neighbour's pane never reports
        let neighbour = model.newSession(agent: .codex, project: Fixture.key("~/p", host: hostID))
        await settle(neighbour.hasLiveProcess)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(neighbour.launchObservation?.directory)
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 1, "asks: the neighbour may be in the same folder")
        XCTAssertTrue(remote.automaticConfirms.isEmpty)
    }

    /// The question lists candidates in start order, earliest first.
    func testTheQuestionListsCandidatesInStartOrder() async throws {
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        let now = Date()
        func at(_ id: String, _ offset: TimeInterval) -> RemoteSuggestion {
            RemoteSuggestion(rolloutPath: "/r/\(id).jsonl", sessionID: id, firstPrompt: "reply with the word ok",
                             startedAt: now.addingTimeInterval(offset), directory: "/home/u/project")
        }
        remote.suggestionsResult = .candidates([at("late", 9), at("early", 2), at("middle", 5)])
        let tab = await newCodex()
        await settle(tab.remote?.suggestions.count == 3)
        XCTAssertEqual(tab.remote?.suggestions.map(\.sessionID), ["early", "middle", "late"])
    }

    /// Two or more candidates: the question; nothing claimed.
    func testTwoCandidatesAsk() async throws {
        remote.suggestionsResult = .candidates([suggestion(), suggestion("c8")])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 2)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(remote.automaticConfirms.isEmpty)
        XCTAssertNil(tab.sessionID)
    }

    /// Never once the question was shown: a run asked about before it was
    /// typed into keeps its question afterwards.
    func testNeverOnItsOwnOnceTheQuestionWasShown() async throws {
        remote.identityResult = .inconclusive("this host has no /proc", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        await settle(tab.remote?.suggestions.count == 1, "asked before anything was typed")
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        let lookups = remote.suggestionLookups.count
        await settle(self.remote.suggestionLookups.count > lookups + 1)
        XCTAssertTrue(remote.automaticConfirms.isEmpty)
        XCTAssertNil(tab.sessionID)
        XCTAssertEqual(tab.remote?.suggestions.count, 1)
    }

    /// Never for a run with a declined candidate, across a relaunch: the
    /// decline is kept with the run (declined_candidates), and the claim's
    /// own transaction refuses Temple's yes; the question takes over.
    func testNeverOnItsOwnAfterADeclineEvenAcrossARelaunch() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", typed: true)]
        remote.declines = [("p7", suggestion("c6").rolloutPath)]
        remote.suggestionsResult = .candidates([suggestion()])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let chip = try XCTUnwrap(model.tabs.first)
        model.activate(chip)
        await settle(chip.remote?.suggestions.count == 1, "the question")
        XCTAssertNil(chip.sessionID)
        XCTAssertTrue(joins.isEmpty)
        XCTAssertLessThanOrEqual(remote.automaticConfirms.count, 1, "refused once, then asked")
    }

    /// The run ends while Temple's yes is in flight: it concludes as a yes
    /// does (the claim and the join recorded, the tab closed, the row the
    /// way back), with no note.
    func testAnAutomaticYesForARunThatEndedConcludesAsAYesDoes() async throws {
        let hold = Gate()
        remote.confirmGate = { await hold.wait() }
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(self.remote.automaticConfirms.count == 1)
        try await Task.sleep(for: .milliseconds(350))
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .endedPending)
        await hold.open()
        await settle(!self.model.tabs.contains { $0 === tab }, "closed, as a yes for an ended session closes it")
        XCTAssertEqual(joins.map(\.id), ["c7"])
    }

    /// A wrong link is undone with Not this one (Fable's decision): the
    /// write comes first (until the claim is released and the candidate
    /// declined, nothing changes). Once it commits, the row the link made is
    /// archived (reversibly) and the tab is detached as any tab is: its
    /// agent keeps running, its run is kept and not restored as a tab, and
    /// a notice offers Open, which reopens the run by its handle asking
    /// without the declined candidate.
    func testNotThisOneDetachesTheTabAndItsRunReopensAskingWithoutTheCandidate() async throws {
        var archived: [String] = []
        var unlinked: [(HostID, String, String)] = []
        model.remoteTabs.unlinkHandler = { id, _ in archived.append(id) }
        model.remoteTabs.unlinkedHandler = {
            unlinked.append(($0, $1, $2))
            XCTAssertEqual($3, "reply with the word ok")
            XCTAssertFalse($4.isEmpty, "the tab named by its title")
            XCTAssertNil($5)
        }
        remote.excludesDeclined = true
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.linkedOnItsOwn == true)
        let surface = try XCTUnwrap(tab.surface as? FakeTerminalSurface)
        // A second candidate turned up meanwhile.
        remote.suggestionsResult = .candidates([suggestion(), suggestion("c8")])
        let hold = Gate()
        remote.unlinkGate = { await hold.wait() }
        model.remoteTabs.unlink(tab)
        await settle(self.remote.unlinks.count == 1)
        XCTAssertEqual(tab.sessionID, "c7", "nothing changes before the write commits")
        XCTAssertTrue(model.tabs.contains { $0 === tab })
        XCTAssertEqual(tab.remote?.unlinking, true, "Not this one waits for it")
        XCTAssertEqual(archived, [])
        model.remoteTabs.unlink(tab)
        XCTAssertEqual(remote.unlinks.count, 1, "one write at a time")
        await hold.open()
        await settle(!self.model.tabs.contains { $0 === tab }, "detached")
        XCTAssertTrue(surface.didTerminate, "Temple's client goes, as a detach's does")
        XCTAssertEqual(archived, ["c7"], "the row the link made is archived (History restores it)")
        XCTAssertEqual(unlinked.map(\.1), ["p1"], "the notice, with Open")
        XCTAssertEqual(remote.unlinks.first?.path, suggestion().rolloutPath)
        XCTAssertTrue(remote.stops.isEmpty, "the agent keeps running")
        XCTAssertEqual(remote.pending.first?.sessionID, nil, "the run is pending again")
        await settle(self.remote.pending.first?.tabClosed == true, "detached: not restored as a tab")
        XCTAssertFalse(remote.pending.first?.dismissed ?? true, "kept: listed under Running sessions")
        XCTAssertFalse(persistence.load().contains { $0.sessionID == "c7" }, "no saved tab of c7")

        // Open: the run, by its handle, asking without c7.
        model.remoteTabs.openPendingRun(handle: "p1", host: hostID, directory: try XCTUnwrap(unlinked.first?.2), typed: true)
        let reopened = try XCTUnwrap(model.tabs.first { $0.remote?.handle == "p1" })
        await settle(reopened.remote?.suggestions.map(\.sessionID) == ["c8"], "asks without the declined candidate")
        XCTAssertNil(reopened.sessionID)
        XCTAssertEqual(remote.automaticConfirms.count, 1, "never linked on its own again for this run")
    }

    /// Declining the last candidate by hand: the tab says no other session
    /// has started there (it keeps working, unidentified), with Try again.
    func testDecliningTheLastCandidateSaysNoOtherSessionStarted() async throws {
        remote.suggestionsResult = .candidates([suggestion("c8"), suggestion("c9")])
        let second = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(second.surface))
        await settle(second.remote?.suggestions.count == 2)
        for candidate in second.remote?.suggestions ?? [] { model.remoteTabs.decline(candidate, in: second) }
        XCTAssertEqual(second.remote?.identityNote, RemoteCopy.noOtherCandidate)
        XCTAssertEqual(RemoteCopy.noOtherCandidate, "No Codex session has started in this folder since the tab opened, apart from "
                       + "any you said weren't this tab's. Temple checks again every minute while the tab is connected; "
                       + "Try again checks now. The tab keeps working; it gets a sidebar row once Temple finds its session.")
    }

    /// Try again never brings back a candidate declined in this tab, even
    /// where the host's lookup still returns it (its own record of the
    /// decline not written yet): neither one declined by hand nor the one a
    /// link was undone for, when its run is reopened.
    func testTryAgainNeverReoffersADeclinedCandidate() async throws {
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion("c7"), suggestion("c8")])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 2)
        for candidate in tab.remote?.suggestions ?? [] { model.remoteTabs.decline(candidate, in: tab) }
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.noOtherCandidate)
        XCTAssertEqual(RemoteCopy.couldNotTell,
                       "Temple couldn't tell which Codex session this is. The tab keeps working; it gets a sidebar row once Temple can tell.")
        let lookups = remote.suggestionLookups.count
        let hold = Gate()
        remote.suggestionsGate = { await hold.wait() }
        model.remoteTabs.retryIdentity(tab)
        // Try again shows that it runs, then what it found.
        XCTAssertEqual(tab.remote?.retrying, true, "checking")
        XCTAssertNil(tab.remote?.retryResult)
        await settle(self.remote.suggestionLookups.count > lookups)
        await hold.open()
        remote.suggestionsGate = nil
        await settle(tab.remote?.retrying == false)
        XCTAssertEqual(tab.remote?.retryResult, "Checked again: still no new Codex session in this folder.")
        XCTAssertEqual(tab.remote?.suggestions, [], "neither comes back")
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.noOtherCandidate)
        model.remoteTabs.detach(tab.id)

        // After Not this one, the reopened run the same.
        remote.identityResult = .inconclusive("no session file is open right now", lasting: false, ended: false)
        remote.suggestionsResult = .candidates([suggestion("c9")])
        let linked = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(linked.surface))
        await settle(linked.remote?.linkedOnItsOwn == true)
        let handle = try XCTUnwrap(linked.remote?.handle)
        model.remoteTabs.unlink(linked)
        await settle(!self.model.tabs.contains { $0 === linked })
        model.remoteTabs.openPendingRun(handle: handle, host: hostID, directory: "/home/u/project", typed: true)
        let reopened = try XCTUnwrap(model.tabs.first { $0.remote?.handle == handle })
        await settle(reopened.remote?.identityNote == RemoteCopy.noOtherCandidate, "nothing left to ask about")
        XCTAssertEqual(reopened.remote?.suggestions, [], "the unlinked candidate is not offered again")
        XCTAssertNil(reopened.sessionID)
    }

    /// The quit begins while Not this one's write is out. Once it commits,
    /// the frozen saved tab set is left alone (no partial save, no counter
    /// moved); the next launch's restore leaves out the saved tab whose row
    /// on a host is archived, then saves the set once without it.
    func testNotThisOneDuringAQuitLeavesTheFrozenSetAloneAndTheNextLaunchSkipsTheSession() async throws {
        let store = ScriptedTabPersistence { _ in true }
        makeModel(persistence: store)
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.linkedOnItsOwn == true)
        await settle(store.saved.contains { $0.sessionID == "c7" })
        let hold = Gate()
        remote.unlinkGate = { await hold.wait() }
        model.remoteTabs.unlink(tab)
        await settle(self.remote.unlinks.count == 1)
        model.prepareForQuit()
        _ = model.quitDrainPlan()
        let attempts = store.attempted.count, saves = model.acknowledgedSaves
        await hold.open()
        await settle(self.remote.pending.first?.tabClosed == true, "its run detached")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.saved.contains { $0.sessionID == "c7" }, "the frozen set is not edited")
        XCTAssertEqual(store.attempted.count, attempts, "no partial save")
        XCTAssertEqual(model.acknowledgedSaves, saves, "the save counter means a full save, still")
        XCTAssertTrue(notices.isEmpty)

        // Relaunch, the row archived (as the app's unlink handler leaves it).
        remote.unlinkGate = nil
        makeModel(persistence: store)
        let row = Fixture.archived(Fixture.row("c7", agent: .codex, project: "/home/u/project", host: hostID))
        model.sessionRow = { $0 == "c7" ? row : nil }
        model.restore()
        model.remoteTabs.restorePending(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.tabs.contains { $0.sessionID == "c7" || $0.remote?.handle == "p1" })
        XCTAssertFalse(remote.opens.contains { $0.sessionID == "c7" }, "the rejected session never resumes")
        XCTAssertFalse(store.saved.contains { $0.sessionID == "c7" }, "the restore's one save drops it")
    }

    /// Reopening a run whose input record never reached the run store
    /// asks at once (the tab's own flag) but doesn't take the record as
    /// written: the next Return writes it, on the usual retried path.
    func testReopeningDoesNotAssumeTheInputRecordIsWritten() async throws {
        model.remoteTabs.inputWriteRetries = []
        remote.inputFailures = 1
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        let handle = try XCTUnwrap(tab.remote?.handle)
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.linkedOnItsOwn == true)
        await settle(self.remote.inputs == [handle] && self.notices.count == 1, "the input record failed, said once")
        XCTAssertFalse(model.remoteTabs.inputCommitted(handle))
        model.remoteTabs.unlink(tab)
        await settle(!self.model.tabs.contains { $0 === tab })
        model.remoteTabs.openPendingRun(handle: handle, host: hostID, directory: "/home/u/project", typed: true)
        let reopened = try XCTUnwrap(model.tabs.first { $0.remote?.handle == handle })
        XCTAssertTrue(reopened.inputSubmitted, "the tab asks at once")
        XCTAssertFalse(model.remoteTabs.inputCommitted(handle), "nothing assumed written")
        await settle(reopened.hasLiveProcess)
        model.surfaceDidSubmitInput(try XCTUnwrap(reopened.surface))
        await settle(self.model.remoteTabs.inputCommitted(handle), "the next Return writes it")
        XCTAssertEqual(remote.inputs, [handle, handle])
    }

    /// Try again whose lookup can't run says so, with why; never "still
    /// none" for a lookup that didn't come back.
    func testTryAgainWhoseLookupFailsSaysSo() async throws {
        model.remoteTabs.identitySchedule = [60]
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        // Two, so Temple asks rather than linking on its own.
        remote.suggestionsResult = .candidates([suggestion("c6"), suggestion("c7")])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.remote?.suggestions.count == 2)
        for candidate in tab.remote?.suggestions ?? [] { model.remoteTabs.decline(candidate, in: tab) }
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.noOtherCandidate)
        remote.suggestionsResult = .unavailable("ssh: connect to host box port 22: Connection refused")
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.remote?.retrying == false)
        XCTAssertEqual(tab.remote?.retryResult,
                       "Couldn't check again: ssh: connect to host box port 22: Connection refused.")
        remote.suggestionsResult = .candidates([])
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.remote?.retrying == false && tab.remote?.retryResult == RemoteCopy.checkedStillNone,
                     "a lookup that came back empty")
    }

    /// Only the newest lookup reaches the tab: an older one that comes back
    /// later, and empty, never erases a candidate the newer one found, and
    /// a lookup with candidates takes the empty-state line down with it.
    func testAnOlderEmptyLookupNeverErasesANewerCandidate() async throws {
        model.remoteTabs.identitySchedule = [60]
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        // Two, so Temple asks rather than linking on its own.
        remote.suggestionsResult = .candidates([suggestion("c6"), suggestion("c7")])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.remote?.suggestions.count == 2)
        for candidate in tab.remote?.suggestions ?? [] { model.remoteTabs.decline(candidate, in: tab) }
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.noOtherCandidate)
        let hold = Gate()
        let lookups = remote.suggestionLookups.count
        remote.suggestionsQueue = [(gate: { await hold.wait() }, answer: .candidates([])),
                                   (gate: nil, answer: .candidates([suggestion("c8")]))]
        model.remoteTabs.retryIdentity(tab)
        await settle(self.remote.suggestionLookups.count == lookups + 1, "the older lookup is out")
        model.remoteTabs.retryIdentity(tab)
        await settle(tab.remote?.suggestions.map(\.sessionID) == ["c8"], "the newer one's candidate")
        XCTAssertNil(tab.remote?.identityNote, "no empty-state line beside a candidate")
        await hold.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tab.remote?.suggestions.map(\.sessionID), ["c8"], "the older, empty answer changes nothing")
    }

    /// Not this one's write that fails changes nothing: the tab is still
    /// the linked session (its saved tab and row as they were), the failure
    /// is said once, and Not this one can be tried again.
    func testNotThisOneThatCannotBeWrittenChangesNothingAndCanBeRetried() async throws {
        var archived: [String] = []
        model.remoteTabs.unlinkHandler = { id, _ in archived.append(id) }
        remote.suggestionsResult = .candidates([suggestion()])
        remote.unlinkError = CocoaError(.fileWriteUnknown)
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.linkedOnItsOwn == true)
        model.remoteTabs.unlink(tab)
        await settle(self.notices.count == 1)
        XCTAssertTrue(notices.first?.hasPrefix("Temple couldn't save its record of this session on box") == true)
        XCTAssertEqual(tab.sessionID, "c7", "still that session")
        XCTAssertTrue(model.tabs.contains { $0 === tab }, "not detached")
        XCTAssertEqual(tab.remote?.linkedOnItsOwn, true)
        XCTAssertEqual(tab.remote?.unlinking, false, "ready to try again")
        XCTAssertEqual(archived, [])
        XCTAssertTrue(persistence.load().contains { $0.sessionID == "c7" }, "its saved tab is kept")
        remote.unlinkError = nil
        model.remoteTabs.unlink(tab)
        await settle(!self.model.tabs.contains { $0 === tab }, "tried again, it goes through")
        XCTAssertEqual(archived, ["c7"])
    }

    /// An automatic yes that can't be written says why and asks: it is not
    /// tried again on its own, and a yes then works.
    func testAnAutomaticYesThatCannotBeWrittenAsksAndRecovers() async throws {
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        remote.confirmResult = .storage("disk full")
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle(tab.remote?.suggestions.count == 1, "the question")
        XCTAssertEqual(tab.remote?.identityNote, RemoteCopy.unrecorded("box", detail: "disk full"), "the failure is said")
        let lookups = remote.suggestionLookups.count
        await settle(self.remote.suggestionLookups.count > lookups + 1)
        XCTAssertEqual(remote.automaticConfirms.count, 1, "not tried again on its own")
        remote.confirmResult = nil
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.sessionID == "c7", "the user's yes recovers")
        XCTAssertNotEqual(tab.remote?.linkedOnItsOwn, true, "a yes of the user's: no note")
    }

    /// Once asked, the tab is never bare: with the last candidate declined
    /// the host offers none, and the tab says no other session started.
    func testTheLastDeclineSaysNoOtherSessionStarted() async throws {
        remote.excludesDeclined = true
        remote.identityResult = .inconclusive("shared server", lasting: true, ended: false)
        remote.suggestionsResult = .candidates([suggestion()])
        let tab = await newCodex()
        await settle(tab.remote?.suggestions.count == 1)
        model.remoteTabs.decline(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(tab.remote?.identityNote == RemoteCopy.noOtherCandidate, "never a bare tab")
        XCTAssertNil(tab.sessionID)
    }

    // MARK: Ending, closing, quitting

    /// Codex finished before its id was learned: something was typed, so
    /// the tab stays and asks; nothing typed, it closes and Temple stops
    /// tracking it. Never a row from a handle.
    func testACodexThatFinishedUnidentifiedAsksOrGoes() async throws {
        remote.suggestionsResult = .candidates([suggestion(), suggestion("c8")])
        let typed = await newCodex()
        model.surfaceDidSubmitInput(try XCTUnwrap(typed.surface))
        try await Task.sleep(for: .milliseconds(400))
        remote.liveness = .absent
        factory.created.last?.simulateExit(status: 0)
        await settle(typed.remote?.phase == .endedPending)
        await settle(typed.remote?.suggestions.count == 2)
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

    /// A quit stops no pending run either (owner's decision): working,
    /// idle, typed into or not, each client is detached and its run left as
    /// it is, so each comes back as a chip next launch. Nothing is stopped
    /// or dismissed.
    func testAQuitDetachesEveryPendingRunAndStopsNone() async throws {
        let working = await newCodex()
        let typed = await newCodex()
        let untouched = await newCodex()
        working.activity = .running
        model.surfaceDidSubmitInput(try XCTUnwrap(typed.surface))
        typed.activity = .idle
        untouched.activity = .idle
        await settle(self.remote.inputs == ["p2"])
        model.prepareForQuit()
        let plan = model.quitDrainPlan()
        XCTAssertEqual(plan.detach.count, 3, "every client is detached")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(remote.stops.isEmpty, "nothing is stopped")
        XCTAssertTrue(remote.dismissedRuns.isEmpty, "nothing is let go: each comes back next launch")
        XCTAssertTrue(remote.closedPending.isEmpty, "no run is marked closed: its chip is restored")
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
        remote.suggestionsResult = .candidates([suggestion(), suggestion("c8")])
        model.activate(restored)
        await settle(restored.hasLiveProcess)
        await settle(restored.remote?.suggestions.count == 2, "typed before the relaunch: asked")
    }

    /// An ended, unidentified session asks in one sentence, question
    /// first; where its terminal was, one line says its last screen is not
    /// kept, at once: nothing the pane printed is fetched (Fable, simplify
    /// round: the preserved output was a flattened TUI stream nobody could
    /// read).
    func testAnEndedSessionAsksInOneSentenceAndFetchesNoOutput() async throws {
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([suggestion("c7")])
        remote.diagnosticsText = "\u{1b}[1mOpenAI Codex\u{1b}[0m\r\n> reply with the word ok\r\n"
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let tab = try XCTUnwrap(model.tabs.first)
        model.activate(tab)
        await settle(tab.remote?.suggestions.count == 1)
        XCTAssertEqual(tab.remote?.phase, .endedPending)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tab.remote?.diagnostics, [], "nothing fetched for an ended run")
        let question = RemoteCopy.codexEndedQuestion("box", suggestion: try XCTUnwrap(tab.remote?.suggestions.first))
        XCTAssertTrue(question.hasPrefix("Codex ended on box before Temple learned which session this was. "
                                         + "Is it \u{201C}reply with the word ok\u{201D} ("), question)
        XCTAssertTrue(question.hasSuffix(")?"), question)
        XCTAssertEqual(RemoteCopy.endedScreenNotKept("box", agent: .codex), "Codex's last screen on box isn't kept after it ends.")
        let unread = RemoteSuggestion(rolloutPath: "/r", sessionID: "x", firstPrompt: nil, startedAt: Date(),
                                      directory: "/w", promptKnown: false)
        XCTAssertTrue(RemoteCopy.codexEndedQuestion("box", suggestion: unread)
            .contains("Is it the one whose first prompt couldn't be read ("))
    }

    /// Confirming an ended session records who it was and nothing else:
    /// the tab closes, as a local tab does when its agent exits, and its
    /// run is handed over; nothing starts or resumes, and nothing selects
    /// the row (the selection follows the active tab, as after any close).
    /// The ended tab's title is its terminal's last, so it is never pushed
    /// as the session's title; the candidate's first prompt is its row's
    /// title hint instead (display only).
    func testAYesForAnEndedSessionClosesItsTabAndHintsTheRowsTitle() async throws {
        var titles: [(String, String)] = []
        var hints: [(String, String)] = []
        model.titleHandler = { id, _, title in titles.append((id, title)) }
        model.titleHintHandler = { hints.append(($0, $1)) }
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([suggestion("c7", prompt: "  reply with the word ok\n")])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let tab = try XCTUnwrap(model.tabs.first)
        model.activate(tab)
        await settle(tab.remote?.suggestions.count == 1)
        tab.title = "Reply ok | temple\u{2011}ux3"
        let created = factory.created.count
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(!self.model.tabs.contains { $0 === tab }, "the tab closes like a local exit")
        XCTAssertNil(tab.sessionID, "it never became the session's tab")
        XCTAssertEqual(joins.map(\.id), ["c7"])
        XCTAssertEqual(hints.map(\.0), ["c7"])
        XCTAssertEqual(hints.map(\.1), ["reply with the word ok"])
        XCTAssertTrue(titles.isEmpty, "the terminal's title is never the session's: \(titles)")
        await settle(self.remote.closedPending == ["p7"], "its run is handed over, not restored again")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(factory.created.count, created, "nothing started")
        XCTAssertTrue(remote.opens.isEmpty, "nothing resumed")
    }

    /// The candidate's prompt is a hint for the candidate only (sol round
    /// 4): a claim that answers with another id, a concurrent `.known`,
    /// seeds nothing, nor does one equal only under Unicode equivalence;
    /// ids are compared by bytes.
    func testAYesSeedsTheTitleHintOnlyForTheCandidatesOwnID() async throws {
        var hints: [(String, String)] = []
        model.titleHintHandler = { hints.append(($0, $1)) }
        for (answer, candidate) in [("c8", "c7"), ("ce\u{301}", "c\u{e9}"), ("c7", "c7")] {
            let tab = await newCodex()
            remote.confirmResult = .known(answer, directory: "/home/u/project")
            model.remoteTabs.confirm(suggestion(candidate), in: tab)
            await settle(tab.sessionID == answer, "the claim's own id")
        }
        XCTAssertEqual(hints.map(\.0), ["c7"], "only the candidate's own id")
        XCTAssertEqual(hints.map(\.1), ["reply with the word ok"])
    }

    /// The yes for an ended session never puts a tab of it in the saved
    /// tab set (sol round 1): it used to become the session's tab (saved,
    /// active) and then close, so a second save that failed left a tab the
    /// next launch resumed. Every save here after the first fails; nothing
    /// saved names the session, its run's restoration is retired, and a
    /// relaunch brings back no tab of it.
    func testAYesForAnEndedSessionSavesNoTabOfItEvenWhenASaveFails() async throws {
        let store = ScriptedTabPersistence { _ in true }
        makeModel(persistence: store)
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([suggestion("c7")])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let tab = try XCTUnwrap(model.tabs.first)
        model.activate(tab)
        await settle(tab.remote?.suggestions.count == 1)
        // From here, the first save is written and every later one fails.
        let first = store.saves + 1
        store.succeeds = { $0 <= first }
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(!self.model.tabs.contains { $0 === tab })
        await settle(self.remote.closedPending == ["p7"], "its run's restoration is retired")
        XCTAssertGreaterThanOrEqual(store.saves, first, "the close saved")
        XCTAssertFalse(store.attempted.joined().contains { $0.sessionID == "c7" }, "no save ever held a tab of it")
        // Relaunch: nothing of it comes back, nothing resumes.
        makeModel(persistence: store)
        model.restore()
        model.remoteTabs.restorePending(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.tabs.contains { $0.sessionID == "c7" || $0.remote?.handle == "p7" })
        XCTAssertTrue(remote.opens.isEmpty, "nothing resumed")
    }

    /// The same when the run store refuses the retirement every time: the
    /// yes still saves no tab of the session; the run is owed until a later
    /// close, the quit or the next launch writes it.
    func testAYesForAnEndedSessionWhoseRetirementFailsIsOwed() async throws {
        model.remoteTabs.handOverRetries = [0.01]
        remote.ledgerFailures = 2
        remote.pending = [.init(handle: "p7", directory: "/home/u/project", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([suggestion("c7")])
        model.remoteTabs.restorePending(hosts: [hostID])
        await settle(self.model.tabs.count == 1)
        let tab = try XCTUnwrap(model.tabs.first)
        model.activate(tab)
        await settle(tab.remote?.suggestions.count == 1)
        model.remoteTabs.confirm(try XCTUnwrap(tab.remote?.suggestions.first), in: tab)
        await settle(!self.model.tabs.contains { $0 === tab })
        await settle(self.notices.count == 1, "said once")
        XCTAssertTrue(model.remoteTabs.owesHandOver("p7"))
        XCTAssertFalse(persistence.load().contains { $0.sessionID == "c7" })
        _ = model.quitDrainPlan()
        await settle(self.remote.closedPending == ["p7"], "the quit writes it")
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

    /// A hand-over the failed save left outstanding is finished when the tab
    /// closes, so the closed tab never comes back from its run (round 3):
    /// failed save, the store recovers, close, relaunch.
    func testAnOutstandingHandOverIsFinishedWhenTheTabCloses() async throws {
        let store = FailingTabPersistence()
        makeModel(persistence: store)
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(remote.closedPending.isEmpty, "not handed over: the save failed")
        store.failing = false
        tab.activity = .idle
        model.closeTab(tab.id)
        await settle(!self.model.tabs.contains { $0 === tab })
        await settle(self.remote.closedPending == ["p1"], "finished at the close")
        XCTAssertFalse(store.saved.contains { $0.sessionID == "c9" })
        // Relaunch: nothing comes back.
        makeModel(persistence: store)
        model.restore()
        model.remoteTabs.restorePending(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.tabs.contains { $0.sessionID == "c9" || $0.remote?.handle == "p1" })
    }

    /// A hand-over holds the run store itself (round 4): failed save, the
    /// host removed, the tab closed: the fallback is retired all the same;
    /// re-enable the host and relaunch: nothing comes back.
    func testAHandOverIsFinishedEvenAfterItsHostIsRemoved() async throws {
        let store = FailingTabPersistence()
        makeModel(persistence: store)
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        XCTAssertTrue(model.remoteTabs.owesHandOver("p1"), "the save failed: still owed")
        // The host is disabled (as AppModel retires it before its entry goes).
        model.remoteTabs.retireHost(hostID)
        hostEnabled = false
        store.failing = false
        model.closeTab(tab.id)
        await settle(!self.model.tabs.contains { $0 === tab })
        await settle(self.remote.closedPending == ["p1"], "written by run, with no launcher for its host")
        XCTAssertFalse(model.remoteTabs.owesHandOver("p1"))
        // Re-enabled, relaunched: nothing comes back.
        hostEnabled = true
        makeModel(persistence: store)
        model.restore()
        model.remoteTabs.restorePending(hosts: [hostID])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.tabs.contains { $0.sessionID == "c9" || $0.remote?.handle == "p1" })
    }

    /// A hand-over whose write fails is kept, tried a few times, said once,
    /// and finished at a later close (round 4).
    func testAFailedHandOverWriteIsKeptAndFinishedAtALaterClose() async throws {
        model.remoteTabs.handOverRetries = [0.01, 0.01]
        remote.ledgerFailures = 3
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        await settle(self.notices.count == 1, "three tries, then said once")
        XCTAssertEqual(remote.ledgerWrites.count, 3)
        XCTAssertTrue(model.remoteTabs.owesHandOver("p1"), "kept until it commits")
        // Another tab's close tries again, and this time it commits.
        let other = await newCodex()
        other.activity = .idle
        model.closeTab(other.id)
        await settle(self.remote.closedPending.contains("p1"))
        await settle(!self.model.remoteTabs.owesHandOver("p1"))
        XCTAssertEqual(notices.count, 1, "said once")
    }

    /// A hand-over never saves the tab set itself (round 5): it waits on
    /// the saves the model makes anyway, so a close costs the one save it
    /// always did.
    func testAHandOverAddsNoSave() async throws {
        let store = FailingTabPersistence()
        store.failing = false
        makeModel(persistence: store)
        remote.identityResult = .inconclusive("no session file is open right now", lasting: false, ended: false)
        let tab = await newCodex()
        let other = await newCodex()
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        model.remoteTabs.activationRecheck = 0
        model.activate(tab)
        await settle(tab.sessionID == "c9")
        await settle(self.remote.closedPending == ["p1"], "finished by the tab set's own save")
        // An owed hand-over: settling, and a tab's removal, never save.
        store.failing = true
        remote.identityResult = .adopted("c8", directory: "/home/u/project")
        model.activate(other)
        await settle(other.sessionID == "c8")
        XCTAssertTrue(model.remoteTabs.owesHandOver("p2"))
        let owed = store.saves
        model.remoteTabs.settleHandOvers()
        model.remoteTabs.tabRemoved(tab)
        model.remoteTabs.quitBegan()
        XCTAssertEqual(store.saves, owed, "a hand-over waits on saves; it never makes one")
    }

    /// The notice's ticket is taken before the write: a host edited while
    /// the write was held (its launcher replaced) refuses the notice, and
    /// the run store still has its diagnostic in the log (round 5).
    func testAHeldHandOverFailureForAReplacedHostIsNotSaid() async throws {
        model.remoteTabs.handOverRetries = []
        let hold = Gate()
        remote.ledgerFailures = 1
        remote.ledgerGate = { await hold.wait() }
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        await settle(!self.remote.ledgerWrites.isEmpty)
        // The host is edited meanwhile: a new launcher for the same name.
        replacement = FakeRemoteHost("box")
        await hold.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(notices.isEmpty, "a completion begun for the old host never speaks for the new one")
        XCTAssertTrue(model.remoteTabs.owesHandOver("p1"), "still owed, and tried again later")
    }

    /// The quit finishes what the frozen tab set hands over.
    func testTheQuitFinishesAnOwedHandOver() async throws {
        let store = FailingTabPersistence()
        makeModel(persistence: store)
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.sessionID == "c9")
        XCTAssertTrue(model.remoteTabs.owesHandOver("p1"))
        store.failing = false
        tab.activity = .running
        model.prepareForQuit()
        _ = model.quitDrainPlan()
        await settle(self.remote.closedPending == ["p1"])
        XCTAssertTrue(store.saved.contains { $0.sessionID == "c9" })
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

    /// A chip restored at launch and never opened is left alone by the quit
    /// too: no client to detach, nothing stopped.
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

    /// A remembered refusal is said again, with Try again, whenever its run
    /// reopens: a reconnect, and a detach then Open (round 3).
    func testARememberedRefusalIsShownWhenTheRunReopens() async throws {
        joinAnswer = .refused(.host(HostID(rawValue: "jet")))
        remote.identityResult = .adopted("c9", directory: "/home/u/project")
        let tab = await newCodex()
        await settle(tab.remote?.identityRefused == true)
        let note = tab.remote?.identityNote
        XCTAssertNotNil(note)
        // Reconnect.
        remote.liveness = .present
        try await Task.sleep(for: .milliseconds(400))
        factory.created.last?.simulateExit(status: 0)
        await settle(tab.remote?.phase == .disconnected)
        model.remoteTabs.reconnect(tab)
        await settle(tab.hasLiveProcess)
        XCTAssertEqual(tab.remote?.identityNote, note)
        XCTAssertEqual(tab.remote?.identityRefused, true)
        // Detach, then Open from Sessions on the host.
        tab.activity = .running
        model.requestClose(tabID: tab.id)
        model.remoteTabs.confirmDetach()
        await settle(!self.model.tabs.contains { $0 === tab })
        model.remoteTabs.openPendingRun(handle: "p1", host: hostID, directory: "/home/u/project")
        let reopened = try XCTUnwrap(model.activeTab)
        await settle(reopened.hasLiveProcess)
        XCTAssertEqual(reopened.remote?.identityNote, note)
        XCTAssertEqual(reopened.remote?.identityRefused, true)
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
        XCTAssertTrue(notices.first?.hasPrefix("Temple couldn't save its record of") == true)
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

    /// The cold-read round's copy (docs/designs/remote-ssh.md, "Cold-read
    /// round"): every label says what it does, one name per thing, and no
    /// user-facing remote copy carries an em-dash.
    func testTheCopyIsOneSourceAndHasNoEmDash() {
        // A notice names the session; the sheet's line explains.
        XCTAssertEqual(RemoteCopy.leftRunning("box", session: "\u{201C}Fix it\u{201D}", reason: .hostDidNotAnswer, detail: nil),
                       "\u{201C}Fix it\u{201D} wasn't stopped: box didn't answer when you closed its tab. It may still be running.")
        XCTAssertEqual(RemoteCopy.leftRunning("box", session: "the new Codex session in temple", reason: .anotherClientAttached,
                                              detail: nil),
                       "The new Codex session in temple wasn't stopped: another terminal is attached to it. It may still be running.")
        XCTAssertEqual(RemoteCopy.leftRunning("box", session: "\u{201C}Fix it\u{201D}", reason: .stopNotAcknowledged, detail: nil),
                       "Temple couldn't stop \u{201C}Fix it\u{201D} on box: the host didn't confirm the stop. It may still be running.")
        XCTAssertEqual(RemoteCopy.sessionName(title: "New Codex session", agent: .codex, directory: "/home/u/temple"),
                       "the new Codex session in temple")
        XCTAssertEqual(RemoteCopy.sessionName(title: "Fix it", agent: .codex, directory: "/home/u/temple"), "\u{201C}Fix it\u{201D}")
        XCTAssertEqual(RemoteCopy.unrecorded("box", detail: "disk full."),
                       "Temple couldn't save its record of this session on box (disk full), so what it shows for this session may be out of date.")
        XCTAssertEqual(RemoteCopy.leftRunningLine("box", reason: .hostDidNotAnswer), "Left running: box didn't answer when you closed it.")
        XCTAssertEqual(RemoteCopy.notStoppedLine(.hostDidNotAnswer, detail: "no answer"), "Not stopped: no answer. It may still be running.")
        XCTAssertEqual(RemoteCopy.notStoppedLine(.anotherClientAttached, detail: nil), "Not stopped: another terminal is attached to it.")
        XCTAssertEqual(RemoteCopy.noTrackedSessions, "No running sessions started from Temple.")
        XCTAssertEqual(RemoteCopy.stillWorkingMessage("box"), "Detach leaves it running on box; Stop ends it.")
        // Running sessions on <host>: states, never imperatives.
        XCTAssertEqual(RemoteCopy.trackedState(.present(attached: true), openHere: true), "Running in a tab")
        XCTAssertEqual(RemoteCopy.trackedState(.present(attached: true), openHere: false), "Running",
                       "another client attached is not this Temple")
        XCTAssertEqual(RemoteCopy.trackedState(.present(attached: false), openHere: false), "Running")
        XCTAssertEqual(RemoteCopy.trackedState(.unknown("no answer"), openHere: false), "Status unknown")
        XCTAssertEqual(RemoteCopy.trackedHandleHelp("f87e"), "tmux session temple-f87e")
        // One name for the sheet everywhere, never shortened.
        XCTAssertEqual(RemoteCopy.sessionsOn("box"), "Running sessions on box")
        XCTAssertEqual(RemoteCopy.sessionsOnMenuItem("box"), "Running sessions on box\u{2026}")
        XCTAssertEqual(RemoteCopy.folderFieldLabel, "Folder")
        XCTAssertEqual(RemoteCopy.leftRunningCount(1, host: "box"), "A session you closed is still running on box.")
        XCTAssertEqual(RemoteCopy.leftRunningCount(3, host: "box"), "3 sessions you closed are still running on box.")
        XCTAssertEqual(RemoteCopy.quitCount(3, host: "box"), "3 sessions from before you quit are running on box.")
        XCTAssertEqual(RemoteCopy.quitCount(1, host: "box"), "A session from before you quit is running on box.")
        // Discard says which, per row; nothing is stopped.
        XCTAssertEqual(RemoteCopy.discardLabel(archives: false), "Remove from Temple")
        XCTAssertEqual(RemoteCopy.discardLabel(archives: true), "Archive session")
        XCTAssertTrue(RemoteCopy.discardHelp(archives: true).hasSuffix("Nothing is running on the host to stop."))
        XCTAssertTrue(RemoteCopy.discardHelp(archives: false).hasSuffix("Nothing is running on the host to stop."))
        // Detach and close, at the point of action.
        XCTAssertEqual(RemoteCopy.detachMenuItem("box"), "Detach from box (keeps running)")
        XCTAssertEqual(RemoteCopy.closeHostTabMenuItem, "Close tab (stops the agent if it is waiting for input)")
        XCTAssertEqual(RemoteCopy.closeHostTabHelp("box", agent: .claude),
                       "Close tab. Stops Claude Code on box if it is waiting for input; asks first if it is working.")
        XCTAssertEqual(RemoteCopy.stopWorkingTitle("Fix it", host: "box"), "Stop \u{201C}Fix it\u{201D} on box?")
        XCTAssertEqual(RemoteCopy.stopWorkingMessage(agent: .codex, uncertain: false, tabOpen: true, resumable: .kept),
                       "Codex is working on it. Stopping ends it, interrupting anything it is doing, and closes its tab. Its conversation is kept: resume it later from its row in the sidebar.")
        XCTAssertEqual(RemoteCopy.stopWorkingMessage(agent: .claude, uncertain: true, tabOpen: false, resumable: .unknown),
                       "Claude Code may still be working on it; Temple reconnected a moment ago and can't tell yet. Stopping ends it, interrupting anything it is doing. "
                       + "Temple doesn't know yet whether it can be resumed afterwards.")
        XCTAssertEqual(RemoteCopy.stopWorkingMessage(agent: .codex, uncertain: false, tabOpen: false, resumable: .absent),
                       "Codex is working on it. Stopping ends it, interrupting anything it is doing. "
                       + "It can't be resumed afterwards: no transcript of it was found on the host.")
        XCTAssertEqual(RemoteCopy.workingCLIRefusal("box"),
                       "Its agent is working on box. Pass --force to detach it (it keeps running), or stop it in Temple.")
        // Remove, singular and plural.
        XCTAssertEqual(RemoteCopy.removalTitle(1, host: "box"), "A session is still running on box.")
        XCTAssertEqual(RemoteCopy.removalTitle(2, host: "box"), "2 sessions are still running on box.")
        XCTAssertEqual(RemoteCopy.removalLeave(2), "Remove, leave them running")
        XCTAssertEqual(RemoteCopy.removalStop(1), "Stop it and remove")
        XCTAssertTrue(RemoteCopy.removalMessage(2, fromConfig: true).hasSuffix(" ~/.ssh/config is not changed."))
        XCTAssertFalse(RemoteCopy.removalMessage(2, fromConfig: false).contains("ssh/config"))
        let unread = RemoteSuggestion(rolloutPath: "/r", sessionID: "x", firstPrompt: nil, startedAt: Date(),
                                      directory: "/w", promptKnown: false)
        XCTAssertTrue(RemoteCopy.suggestionQuestion(unread).hasPrefix("Is this the session? First prompt unreadable, started "))
        XCTAssertFalse(RemoteCopy.suggestionQuestion(unread).contains("No prompt yet"))
        XCTAssertEqual(RemoteCopy.linkedOnItsOwn(suggestion()),
                       "Linked this tab to \u{201C}reply with the word ok\u{201D}, the only Codex session started in this folder since the tab opened.")
        let noon = Calendar.current.date(bySettingHour: 15, minute: 12, second: 0, of: Date())!
        let timed = RemoteSuggestion(rolloutPath: "/r", sessionID: "x", firstPrompt: nil, startedAt: noon, directory: "/w")
        XCTAssertEqual(RemoteCopy.linkedOnItsOwn(timed, now: noon),
                       "Linked this tab to the Codex session started \(RemoteCopy.startTime(noon, now: noon)), the only one started in this folder since the tab opened.")
        XCTAssertTrue(RemoteCopy.noDaemonHint(enabled: false).hasPrefix("Add --no-daemon to Codex's arguments above"))
        XCTAssertTrue(RemoteCopy.noDaemonHint(enabled: true).hasPrefix("Codex's arguments include --no-daemon"))
        XCTAssertEqual(RemoteCopy.stillWorking("box", agent: .codex), "Codex is working on box.")
        XCTAssertEqual(RemoteCopy.stillWorking("box", agent: .claude), "Claude Code is working on box.")
        // Candidates whose prompts read the same are told apart by when they
        // started after the tab opened; the clock time otherwise. The folder
        // is the candidate's full path.
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        func started(_ seconds: TimeInterval, hostAhead: TimeInterval? = 0) -> RemoteSuggestion {
            RemoteSuggestion(rolloutPath: "/r/\(seconds)", sessionID: "x", firstPrompt: "hi",
                             startedAt: opened.addingTimeInterval(seconds + (hostAhead ?? 0)), directory: "/w/temple-r2",
                             hostClockOffset: hostAhead)
        }
        XCTAssertEqual(RemoteCopy.suggestionQuestion(started(4.2), tabOpenedAt: opened),
                       "Is this the session? \u{201C}hi\u{201D}, started in /w/temple-r2 4 s after this tab opened.")
        XCTAssertEqual(RemoteCopy.suggestionQuestion(started(-2), tabOpenedAt: opened),
                       "Is this the session? \u{201C}hi\u{201D}, started in /w/temple-r2 as this tab opened.",
                       "a clock a little apart is not a start before the open")
        XCTAssertTrue(RemoteCopy.suggestionQuestion(started(70), tabOpenedAt: opened).contains("temple-r2 1 min after this tab opened"))
        XCTAssertTrue(RemoteCopy.suggestionQuestion(started(150), tabOpenedAt: opened).contains("temple-r2 3 min after this tab opened"))
        XCTAssertFalse(RemoteCopy.suggestionQuestion(started(-600), tabOpenedAt: opened).contains("after this tab opened"),
                       "a start well before the open: the clock time")
        XCTAssertFalse(RemoteCopy.suggestionQuestion(started(4), tabOpenedAt: nil).contains("after this tab opened"))
        // The host's clock ahead or behind this Mac's (Sol round 6): the
        // start is moved by the offset the lookup measured.
        XCTAssertTrue(RemoteCopy.suggestionQuestion(started(4, hostAhead: 600), tabOpenedAt: opened)
            .contains("temple-r2 4 s after this tab opened"), "a host 10 min ahead")
        XCTAssertTrue(RemoteCopy.suggestionQuestion(started(4, hostAhead: -600), tabOpenedAt: opened)
            .contains("temple-r2 4 s after this tab opened"), "a host 10 min behind")
        XCTAssertFalse(RemoteCopy.suggestionQuestion(started(4, hostAhead: nil), tabOpenedAt: opened)
            .contains("after this tab opened"), "no offset: the clock time")
        let copy = [RemoteCopy.codexEndedPending("box"), RemoteCopy.couldNotTell, RemoteCopy.noDaemonHint(enabled: true),
                    RemoteCopy.noDaemonHint(enabled: false), RemoteCopy.codexQuestionLeadIn,
                    RemoteCopy.linkedOnItsOwn(suggestion()), RemoteCopy.quitLine(["box", "jet"]),
                    RemoteCopy.quitTitle(workingCount: 1), RemoteCopy.quitMessage(workingCount: 2),
                    RemoteCopy.codexEndedQuestion("box", suggestion: suggestion()),
                    RemoteCopy.endedScreenNotKept("box", agent: .codex), RemoteCopy.sessionsOn("box"),
                    RemoteCopy.stillWorking("box", agent: .codex), RemoteCopy.stillWorkingMessage("box"),
                    RemoteCopy.resumeAnyway("box"), RemoteCopy.scrollingNote, RemoteCopy.notSetUp("box"),
                    RemoteCopy.startNewPending("box"), RemoteCopy.stopHint("box"), RemoteCopy.discardHelp(archives: true),
                    RemoteCopy.discardHelp(archives: false), RemoteCopy.goneFromConfig, RemoteCopy.hostFormNameNote,
                    RemoteCopy.hostFormEditHint, RemoteCopy.cancelConnectingHelp, RemoteCopy.startWithoutCheckingHelp,
                    RemoteCopy.suggestionQuestion(suggestion()), RemoteCopy.noTrackedSessions,
                    RemoteCopy.leftRunning("box", session: "x", reason: .hostDidNotAnswer, detail: nil),
                    RemoteCopy.leftRunningLine("box", reason: .quitDeadline), RemoteCopy.disconnected("box"),
                    RemoteCopy.unknown("box", agent: .codex, reason: "x"), RemoteCopy.stillConnecting("box"),
                    RemoteCopy.removalMessage(1, fromConfig: true), RemoteCopy.closeHostTabHelp("box", agent: .codex)]
        for line in copy { XCTAssertFalse(line.contains("\u{2014}"), line) }
    }
}

/// A tab store whose Nth save (1-based) succeeds only when `succeeds`
/// says so; every attempt is kept.
final class ScriptedTabPersistence: TabPersistence {
    var succeeds: (Int) -> Bool
    private(set) var saved: [PersistedTab] = []
    private(set) var attempted: [[PersistedTab]] = []
    var saves: Int { attempted.count }
    init(succeeds: @escaping (Int) -> Bool) { self.succeeds = succeeds }
    func load() -> [PersistedTab] { saved }
    func save(_ tabs: [PersistedTab]) { _ = saveAcknowledged(tabs) }
    func saveAcknowledged(_ tabs: [PersistedTab]) -> Bool {
        attempted.append(tabs)
        guard succeeds(attempted.count) else { return false }
        saved = tabs
        return true
    }
}

/// A tab store whose writes fail (and say so) until it recovers.
final class FailingTabPersistence: TabPersistence {
    var failing = true
    private(set) var saved: [PersistedTab] = []
    private(set) var saves = 0
    func load() -> [PersistedTab] { saved }
    func save(_ tabs: [PersistedTab]) { _ = saveAcknowledged(tabs) }
    func saveAcknowledged(_ tabs: [PersistedTab]) -> Bool {
        saves += 1
        guard !failing else { return false }
        saved = tabs
        return true
    }
}
