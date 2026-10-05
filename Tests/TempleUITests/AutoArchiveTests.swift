import XCTest
import AppKit
import GRDB
import TempleCore
@testable import TempleUI
@testable import TempleLocalHost

/// A one-shot scheduler the test fires by hand.
@MainActor
final class ManualSweepScheduler {
    private var next = 0
    private var pending: [Int: @MainActor () -> Void] = [:]
    /// How many times the sweep was armed.
    private(set) var armed = 0
    var isArmed: Bool { !pending.isEmpty }

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        XCTAssertEqual(delay, AppModel.archiveSweepDelay)
        next += 1; armed += 1
        let id = next
        pending[id] = action
        return { [weak self] in MainActor.assumeIsolated { _ = self?.pending.removeValue(forKey: id) } }
    }

    func fire() {
        let actions = pending.sorted { $0.key < $1.key }.map(\.value)
        pending.removeAll()
        actions.forEach { $0() }
    }
}

/// ADR-030: Temple archives a row nobody can resume any more, its
/// transcript or its folder gone: only on proof, only when nobody is using
/// it, labelled, undoable from a notice it shows once.
@MainActor
final class AutoArchiveTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// The sweep's "now": Fixture rows dated near 1970 are long idle.
    private let clock = Date(timeIntervalSince1970: 1_900_000_000)

    /// Folder answers a test hands the sweep, and the questions it asked.
    /// While `held`, every answer waits until `release()`: the sweep is
    /// suspended between gathering and planning.
    @MainActor final class Folders {
        var evidence: [String: DirectoryEvidence] = [:]
        var asked: [String] = []
        var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var waiting: Bool { !waiters.isEmpty }

        func answer(_ path: String) async -> DirectoryEvidence {
            asked.append(path)
            if held { await withCheckedContinuation { waiters.append($0) } }
            return evidence[path] ?? .unknown
        }

        func release() {
            held = false
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// The hosts' proofs a test hands the sweep, and the calls it made.
    @MainActor final class Proofs {
        /// Per agent, what the proof says; absent agents prove every id.
        var answers: [Agent: (exhaustive: Bool, quiescent: Bool, present: Set<String>)] = [:]
        var calls: [(HostID, Agent, Set<String>)] = []

        func prove(_ host: HostID, _ agent: Agent, _ ids: Set<String>) -> AbsenceProof {
            calls.append((host, agent, ids))
            let answer = answers[agent] ?? (true, true, [])
            return AbsenceProof(exhaustive: answer.exhaustive, quiescent: answer.quiescent, missing: ids.subtracting(answer.present))
        }
    }

    /// Timers the sweep armed (the hourly sweep, proof retries), fired by hand.
    @MainActor final class Timers {
        var armed: [TimeInterval] = []
        private var pending: [Int: @MainActor () -> Void] = [:]
        private var next = 0
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
            next += 1; armed.append(delay)
            let id = next
            pending[id] = action
            return { [weak self] in MainActor.assumeIsolated { _ = self?.pending.removeValue(forKey: id) } }
        }
        /// Fires whatever is armed (the test knows which delay that is).
        func fire(_ delay: TimeInterval) {
            let actions = pending.sorted { $0.key < $1.key }.map(\.value)
            pending.removeAll()
            actions.forEach { $0() }
        }
    }

    @MainActor private struct Harness {
        let model: AppModel
        let overlay: SessionOverlayStore
        let database: TempleDB
        let scheduler: ManualSweepScheduler
        let folders: Folders
        let proofs: Proofs
        let timers: Timers
        var generation: UInt64 = 0

        /// A snapshot as the engine publishes it: each verdict names the
        /// membership it is about (the row's current one unless given).
        mutating func publish(_ resolutions: [String: MemberResolution], memberships: [String: MembershipRef] = [:]) {
            generation += 1
            var refs = memberships
            for id in resolutions.keys where refs[id] == nil { refs[id] = ref(id) }
            model.receiveEngineSnapshot(EngineSnapshot(generation: generation, resolutions: resolutions, memberships: refs))
        }

        func ref(_ id: String) -> MembershipRef? {
            guard let state = state(id), let incarnation = state.incarnation else { return nil }
            return MembershipRef(id: id, host: state.host, incarnation: incarnation)
        }

        /// Fire, let the sweep finish, until it stops re-arming itself (its
        /// own writes arm it once).
        func settle() async {
            for _ in 0..<5 where scheduler.isArmed {
                scheduler.fire()
                await model.archiveSweep?.value
            }
            XCTAssertFalse(scheduler.isArmed, "the sweep keeps re-arming")
        }

        func state(_ id: String) -> SessionState? { try! database.sessionState(id) }
        func archived(_ ids: [String]) -> [String] { ids.filter { state($0)?.archived == true } }
        func reason(_ id: String) -> ArchiveReason? { state(id)?.archiveReason }
    }

    private func harness(_ rows: [Session], saved: [PersistedTab] = []) -> Harness {
        let database = try! TempleDB.inMemory()
        Fixture.join(rows, to: database)
        let overlay = SessionOverlayStore(db: database)
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save(saved)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                             persistence: persistence, database: database,
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                             overlay: overlay, hostRegistry: Fixture.hostsWithoutFolderEvidence())
        let scheduler = ManualSweepScheduler()
        model.archiveSweepScheduler = scheduler.schedule
        let folders = Folders()
        model.folderEvidence = { key in await folders.answer(key.path) }
        let proofs = Proofs()
        model.proveAbsence = { host, agent, ids in await proofs.prove(host, agent, ids) }
        let timers = Timers()
        model.sweepTimer = timers.schedule
        let clock = clock
        model.now = { clock }
        model.history.catalog = { AsyncStream { $0.finish() } }
        return Harness(model: model, overlay: overlay, database: database, scheduler: scheduler, folders: folders,
                       proofs: proofs, timers: timers)
    }

    private func row(_ id: String, project: String? = "/p", updated: TimeInterval = 0) -> Session {
        Fixture.row(id, project: project, title: id, updated: updated)
    }

    private let loaded = MemberResolution.loaded(URL(fileURLWithPath: "/tmp/there.jsonl"))

    // MARK: Transcript gone

    func testOnlyAProvenAbsenceOfAnIdleUnusedRowIsArchived() async throws {
        let ids = ["gone", "week", "loaded", "unreadable", "mismatch", "incomplete", "awaiting", "resolving",
                   "no-entry", "pinned", "open", "chip", "recent", "kept"]
        var rows = ids.map { row($0) }
        rows[ids.firstIndex(of: "week")!] = row("week", updated: clock.timeIntervalSince1970 - 7 * day)
        rows[ids.firstIndex(of: "recent")!] = row("recent", updated: clock.timeIntervalSince1970 - 6 * day)
        var h = harness(rows, saved: [PersistedTab(sessionID: "chip", agent: .claude, projectPath: "/p", title: "chip")])
        h.model.openSessions.restore()
        XCTAssertNotNil(h.model.openSessions.openTab(forSessionID: "chip"), "a restored inert chip")
        h.model.openSessions.openSession(try XCTUnwrap(h.model.sessions.first { $0.id == "open" }))
        h.overlay.togglePin("pinned")
        h.overlay.setArchived(true, sessionID: "kept"); h.overlay.setArchived(false, sessionID: "kept")
        let undo = UndoManager()

        var resolutions: [String: MemberResolution] = [
            "loaded": loaded, "unreadable": .unreadable, "mismatch": .mismatch, "incomplete": .incomplete,
            "awaiting": .awaitingCreation, "resolving": .resolving]
        for id in ["gone", "week", "pinned", "open", "chip", "recent", "kept"] { resolutions[id] = .confirmedAbsent }
        h.publish(resolutions)
        XCTAssertTrue(h.scheduler.isArmed)
        await h.settle()

        XCTAssertEqual(h.archived(ids), ["gone", "week"])
        XCTAssertEqual(h.reason("gone"), .transcriptMissing)
        XCTAssertTrue(try XCTUnwrap(h.state("pinned")).pinned)
        XCTAssertEqual(h.model.autoArchiveNotice?.count, 2)
        XCTAssertEqual(h.model.autoArchiveNotice?.message, "Archived 2 sessions whose transcripts are gone")
        XCTAssertEqual(Set(h.model.autoArchiveNotice?.memberships.map(\.id) ?? []), ["gone", "week"])
        XCTAssertFalse(undo.canUndo, "the sweep is not the user's action")
        XCTAssertFalse(h.model.visibleRows.contains { $0.id == "gone" }, "it leaves the rail and ⌘K")
        XCTAssertTrue(h.model.archivedSessionResults("").contains { $0.id == "gone" && $0.archivedByTemple })
        XCTAssertEqual(Set(h.folders.asked), ["/p"], "the candidates' folder")
        XCTAssertEqual(h.proofs.calls.count, 1, "one proof per host and agent, for every hinted row")
        XCTAssertEqual(h.proofs.calls.first?.2, ["gone", "week"])
        XCTAssertLessThanOrEqual(h.folders.asked.count, 2, "one question per folder per sweep")
    }

    /// The engine's verdict is a hint; the proof taken at the sweep decides.
    /// A file there, a listing that cannot see everything, a listing that
    /// was not quiet: nothing archived for the transcript. Proven: archived.
    func testATranscriptIsArchivedOnlyOnAProofTakenAtTheSweep() async throws {
        var h = harness([row("a"), row("b", project: nil)])
        h.proofs.answers[.claude] = (true, true, ["a", "b"])
        h.publish(["a": .confirmedAbsent, "b": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), [], "a file is there after all")
        h.proofs.answers[.claude] = (false, true, [])
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), [], "not exhaustive")
        h.proofs.answers[.claude] = (true, false, [])
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), [], "not quiescent")
        h.folders.evidence["/p"] = .missing
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), ["a"], "an unproven hint leaves the folder to decide")
        XCTAssertEqual(h.reason("a"), .folderMissing)
        h.proofs.answers[.claude] = nil
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["b"]), ["b"])
        XCTAssertEqual(h.reason("b"), .transcriptMissing)
    }

    /// A row that never recorded its agent needs every agent's proof.
    func testARowWithNoAgentNeedsEveryAgentsProof() async throws {
        var h = harness([Fixture.row("x", agent: nil, project: nil, title: "x")])
        h.proofs.answers[.codex] = (true, false, [])
        h.publish(["x": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.archived(["x"]), [])
        XCTAssertEqual(Set(h.proofs.calls.map(\.1)), [.claude, .codex])
        h.proofs.answers[.codex] = nil
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["x"]), ["x"])
    }

    /// A proof that was not quiet is tried again a bounded number of times,
    /// spaced, then left to the hourly sweep — never a tight loop. A quiet
    /// one resets the count.
    func testANoisyProofIsRetriedABoundedNumberOfTimes() async throws {
        var h = harness([row("a", project: nil)])
        h.proofs.answers[.claude] = (true, false, [])
        h.publish(["a": .confirmedAbsent])
        await h.settle()
        for delay in AppModel.proofRetryDelays {
            XCTAssertEqual(h.timers.armed.last, delay)
            h.timers.fire(delay)
            await h.settle()
        }
        let armed = h.timers.armed.count
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.timers.armed.count, armed, "retries spent: no more until the hourly sweep")
        XCTAssertEqual(h.archived(["a"]), [])
        h.proofs.answers[.claude] = nil
        h.model.armArchiveSweep(); await h.settle()
        XCTAssertEqual(h.archived(["a"]), ["a"])
    }

    /// The app's sweep runs hourly as well as on verdicts.
    func testTheAppSweepsHourly() async {
        let h = harness([row("a", project: nil)])
        h.model.armPeriodicSweep()
        XCTAssertEqual(h.timers.armed, [AppModel.periodicSweepInterval])
        h.timers.fire(AppModel.periodicSweepInterval)
        XCTAssertTrue(h.scheduler.isArmed, "an hourly tick arms a sweep")
        XCTAssertEqual(h.timers.armed, [AppModel.periodicSweepInterval, AppModel.periodicSweepInterval], "and the next tick")
    }

    func testThePlanIsPureAndStable() {
        let state = { (id: String, directory: String?, reason: ArchiveReason?, kept: Date?) in
            SessionState(id: id, pinned: false, archived: false, customName: nil, color: nil, generatedTitle: nil,
                         lastOpenedAt: nil, joinedVia: .imported, joinedAt: nil, directory: directory,
                         incarnation: "i-\(id)", archiveReason: reason, keptAt: kept)
        }
        let rows: [String: SessionState] = [
            "b": state("b", "/gone", nil, nil), "a": state("a", nil, nil, nil),
            "both": state("both", "/gone", nil, nil), "here": state("here", "/here", nil, nil),
            "unknown": state("unknown", "/unknown", nil, nil), "no-folder": state("no-folder", nil, nil, nil),
            "kept": state("kept", "/gone", nil, Date()), "stale": state("stale", "/gone", .transcriptMissing, nil),
            "rejoined": state("rejoined", nil, nil, nil),
            "no-incarnation": SessionState(id: "no-incarnation", pinned: false, archived: false, customName: nil, color: nil,
                                           generatedTitle: nil, lastOpenedAt: nil, joinedVia: nil, joinedAt: nil),
        ]
        let ref = { (id: String) in MembershipRef(id: id, host: .local, incarnation: "i-\(id)") }
        let snapshot = EngineSnapshot(
            generation: 1,
            resolutions: ["a": .confirmedAbsent, "both": .confirmedAbsent, "rejoined": .confirmedAbsent,
                          "no-incarnation": .confirmedAbsent],
            memberships: ["a": ref("a"), "both": ref("both"),
                          // The verdict is about an earlier membership of the id.
                          "rejoined": MembershipRef(id: "rejoined", host: .local, incarnation: "earlier")])
        XCTAssertEqual(AutoArchivePolicy.foldersToCheck(rows: rows.values, snapshot: snapshot, openSessionIDs: [], now: clock),
                       [Fixture.key("/gone"), Fixture.key("/here"), Fixture.key("/unknown")])
        let requests = AutoArchivePolicy.proofRequests(rows: rows.values, snapshot: snapshot, openSessionIDs: [], now: clock)
        XCTAssertEqual(requests, [.init(host: .local, agent: .claude): ["a", "both"], .init(host: .local, agent: .codex): ["a", "both"]],
                       "no agent recorded: every agent's proof")
        let proven = AbsenceProof(exhaustive: true, quiescent: true, missing: ["a", "both"])
        let plan = AutoArchivePolicy.plan(
            rows: rows.values, snapshot: snapshot,
            proofs: [.init(host: .local, agent: .claude): proven, .init(host: .local, agent: .codex): proven],
            folders: [Fixture.key("/gone"): .missing, Fixture.key("/here"): .exists, Fixture.key("/unknown"): .unknown],
            openSessionIDs: [], now: clock)
        XCTAssertEqual(plan.map(\.ref.id), ["a", "b", "both"], "not the rejoined row: the absence was another membership's")
        XCTAssertEqual(plan.map(\.reason), [.transcriptMissing, .folderMissing, .transcriptMissing], "the transcript wins")
        XCTAssertEqual(plan.map(\.directory), [nil, "/gone", nil], "a folder archive names the folder")
        XCTAssertEqual(plan.first?.ref.incarnation, "i-a")
    }

    /// A verdict is about a membership. Leave and rejoin the same id (with an
    /// old activity date, so it is idle) while the sweep waits on a folder:
    /// the absence the snapshot still carries was the old membership's.
    func testAnOldMembershipsAbsenceIsNotTheRejoinsWhileTheSweepIsSuspended() async throws {
        var h = harness([row("a", project: nil), row("b", project: "/slow")])
        h.publish(["a": .confirmedAbsent])
        let old = try XCTUnwrap(h.ref("a"))
        h.folders.held = true
        h.scheduler.fire()
        try await waitFor { h.folders.waiting }

        XCTAssertTrue(try h.database.leave(sessionID: "a", host: .local))
        try h.database.join(sessionID: "a", via: .imported, agent: .claude,
                            core: SessionCore(lastActiveAt: Date(timeIntervalSince1970: 0)))
        XCTAssertNotEqual(h.ref("a"), old)
        h.folders.release()
        await h.model.archiveSweep?.value
        await h.settle()
        XCTAssertEqual(h.archived(["a"]), [], "the rejoin is not proven gone")
        XCTAssertNil(h.model.autoArchiveNotice)

        // The engine's verdict about the new membership does.
        h.publish(["a": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.archived(["a"]), ["a"])
    }

    /// While the sweep waits on folder evidence, the user acts: each act is
    /// seen when it plans, because it plans after the wait.
    func testWhatHappensDuringASuspendedSweepIsRespected() async throws {
        let ids = ["control", "opened", "pinned", "restored", "left"]
        var h = harness(ids.map { row($0, project: "/gone") })
        h.folders.evidence = ["/gone": .missing]
        h.overlay.setArchived(true, sessionID: "restored")
        h.publish([:])
        h.folders.held = true
        h.scheduler.fire()
        try await waitFor { h.folders.waiting }

        h.model.openSessions.openSession(try XCTUnwrap(h.model.sessions.first { $0.id == "opened" }))
        h.overlay.togglePin("pinned")
        h.model.restoreSession("restored", undoManager: nil)
        XCTAssertEqual(h.model.overlay.leave([SessionKey(id: "left", host: .local)]), ["left"])
        h.folders.release()
        await h.model.archiveSweep?.value
        await h.settle()

        XCTAssertEqual(h.archived(ids), ["control"])
        XCTAssertNil(h.state("left"))
        XCTAssertEqual(h.model.autoArchiveNotice?.memberships.map(\.id), ["control"])
    }

    /// A model nobody turned the sweep on for (every test fixture, every
    /// tool) never archives anything.
    func testTheSweepIsOffUnlessTheAppTurnsItOn() async throws {
        let database = try TempleDB.inMemory()
        Fixture.join([row("gone")], to: database)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: database,
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        let incarnation = try XCTUnwrap(database.sessionState("gone")?.incarnation)
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["gone": .confirmedAbsent],
            memberships: ["gone": MembershipRef(id: "gone", host: .local, incarnation: incarnation)]))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(try database.sessionState("gone")?.archived, false)
        XCTAssertNil(model.autoArchiveNotice)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    // MARK: Folder gone

    func testAFolderProvenGoneArchivesAndUnknownOrPresentNeverDoes() async {
        var h = harness([row("gone", project: "/gone"), row("gone-too", project: "/gone"),
                         row("here", project: "/here"), row("unknown", project: "/unknown"),
                         row("recent", project: "/gone", updated: clock.timeIntervalSince1970 - day),
                         row("no-folder", project: nil)])
        h.folders.evidence = ["/gone": .missing, "/here": .exists]
        h.publish(["here": loaded])
        await h.settle()
        XCTAssertEqual(h.archived(["gone", "gone-too", "here", "unknown", "recent", "no-folder"]), ["gone", "gone-too"])
        XCTAssertEqual(h.reason("gone"), .folderMissing)
        XCTAssertEqual(h.folders.asked.filter { $0 == "/gone" }.count, 1, "one stat per folder")
        XCTAssertEqual(h.model.autoArchiveNotice?.message, "Archived 2 sessions whose folders are gone")
        XCTAssertEqual(AppModel.AutoArchiveNotice(entries: Array(h.model.autoArchiveNotice!.entries.prefix(1))).message,
                       "Archived 1 session whose folder is gone")
        XCTAssertEqual(ArchiveView.templeArchiveTag(.folderMissing)?.text, "No folder")
        XCTAssertEqual(ArchiveView.templeArchiveTag(.transcriptMissing)?.text, "No transcript")
        XCTAssertNil(ArchiveView.templeArchiveTag(ArchiveReason(rawValue: "from_the_future")))
    }

    func testAMixedSweepIsOneNoticeNamingBoth() async {
        var h = harness([row("transcript", project: "/here"), row("folder", project: "/gone")])
        h.folders.evidence = ["/gone": .missing, "/here": .exists]
        h.publish(["transcript": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.model.autoArchiveNotice?.message, "Archived 2 sessions whose transcripts or folders are gone")
        XCTAssertEqual(h.model.autoArchiveNotice?.help,
                       "Without a transcript on disk or its folder a session can't resume. They're in Archived items (⌘⇧Y); Restore brings one back.")
        XCTAssertEqual(AppModel.AutoArchiveNotice(entries: [AutoArchiveEntry(ref: MembershipRef(id: "x", host: .local, incarnation: "i"), reason: .transcriptMissing)]).help,
                       "Without a transcript on disk a session can't resume. They're in Archived items (⌘⇧Y); Restore brings one back.")
    }

    func testTheSweepRunsAtLaunchAndWhenTheAppComesForward() async {
        var h = harness([row("gone", project: "/gone")])
        h.folders.evidence = ["/gone": .missing]
        XCTAssertFalse(h.scheduler.isArmed)
        h.model.start()
        XCTAssertTrue(h.scheduler.isArmed, "at launch")
        await h.settle()
        XCTAssertEqual(h.archived(["gone"]), ["gone"])
        h.model.undoAutoArchive()
        await h.settle()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(h.scheduler.isArmed, "when the app comes forward")
        h.model.engineSet.stop()
    }

    // MARK: Coalescing and the notice

    func testABurstIsOneSweepAndALaterBatchJoinsTheShowingNotice() async {
        var h = harness([row("a"), row("b"), row("c")])
        h.publish(["a": .resolving, "b": .resolving, "c": .resolving])
        h.publish(["a": .confirmedAbsent, "b": .resolving, "c": .resolving])
        h.publish(["a": .confirmedAbsent, "b": .confirmedAbsent, "c": .resolving])
        XCTAssertEqual(h.scheduler.armed, 1, "one timer for the burst")
        await h.settle()
        XCTAssertEqual(h.model.autoArchiveNotice?.count, 2)
        XCTAssertEqual(h.scheduler.armed, 2, "its own writes re-arm it once, and that run plans nothing")

        h.publish(["c": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.model.autoArchiveNotice?.count, 3, "merged, not replaced")
        XCTAssertEqual(h.model.autoArchiveNotice?.memberships.map(\.id), ["a", "b", "c"])

        h.model.dismissAutoArchiveNotice()
        XCTAssertNil(h.model.autoArchiveNotice)
        XCTAssertEqual(h.archived(["a", "b", "c"]), ["a", "b", "c"], "× only dismisses")
    }

    func testUndoRestoresExactlyTheNoticesRowsKeptUntilTheirNextActivity() async {
        var h = harness([row("a"), row("b"), row("c")])
        h.publish(["a": .confirmedAbsent, "b": .confirmedAbsent])
        await h.settle()
        // Restored by hand since, and another archived by the user.
        h.model.restoreSession("b", undoManager: nil)
        h.overlay.setArchived(true, sessionID: "c")

        h.model.undoAutoArchive()
        XCTAssertNil(h.model.autoArchiveNotice)
        XCTAssertEqual(h.archived(["a", "b", "c"]), ["c"])
        XCTAssertNotNil(h.state("a")?.keptAt)
        XCTAssertEqual(h.reason("a"), .transcriptMissing, "the reason stays as the record")
        h.publish(["a": .confirmedAbsent, "b": .confirmedAbsent, "c": .resolving])
        await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), [], "a kept row is not swept again")
        XCTAssertNil(h.model.autoArchiveNotice, "no second notice")

        // Activity spends the keep; a week idle after it, it goes again.
        let used = clock.addingTimeInterval(-8 * day)
        h.overlay.touch("a", host: .local, at: used)
        h.overlay.flushPendingTouches()
        XCTAssertNil(h.state("a")?.keptAt)
        XCTAssertNil(h.reason("a"))
        h.publish(["a": .confirmedAbsent, "b": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.archived(["a", "b"]), ["a"])
        XCTAssertEqual(h.model.autoArchiveNotice?.memberships.map(\.id), ["a"])
    }

    /// Activity from before a Restore, still waiting to be written when the
    /// Restore lands, does not spend the keep, even with a stored activity
    /// date in the future: the write carries when the activity happened.
    func testActivityFromBeforeARestoreFlushedAfterItKeepsTheKeep() throws {
        let h = harness([row("a")])
        let future = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400 * 365).rounded())
        try h.database.touch(sessionID: "a", host: .local, at: future)
        XCTAssertEqual(try h.database.autoArchive([AutoArchiveEntry(ref: XCTUnwrap(h.ref("a")), reason: .transcriptMissing)],
                                                  idleBefore: .distantFuture), ["a"])
        h.overlay.touch("a", host: .local, at: Date().addingTimeInterval(-60))   // typed before the Restore
        h.model.restoreSession("a", undoManager: nil)
        h.overlay.flushPendingTouches()
        XCTAssertNotNil(h.state("a")?.keptAt, "activity from before the restore")
        XCTAssertEqual(h.state("a")?.lastActiveAt, future, "never backwards")

        h.overlay.touch("a", host: .local, at: Date().addingTimeInterval(1))
        h.overlay.flushPendingTouches()
        XCTAssertNil(h.state("a")?.keptAt, "activity after it")
    }

    /// Nothing watches an archived row's transcript, and a file that turns
    /// up again is not a decision: only a person brings the row back.
    func testATranscriptThatTurnsUpAgainChangesNothing() async {
        var h = harness([row("temple")])
        h.publish(["temple": .confirmedAbsent])
        await h.settle()
        h.publish(["temple": loaded])
        await h.settle()
        XCTAssertEqual(h.archived(["temple"]), ["temple"])
        XCTAssertEqual(h.reason("temple"), .transcriptMissing)
    }

    func testRowsInAnArchivedProjectAreSweptAndTaggedInsideTheGroup() async {
        var h = harness([row("in-project", project: "/p/b"), row("loose", project: "/p/a")])
        h.overlay.setProjectArchived(true, key: Fixture.key("/p/b"))
        h.publish(["in-project": .confirmedAbsent, "loose": .confirmedAbsent])
        await h.settle()
        XCTAssertEqual(h.model.autoArchiveNotice?.count, 2)
        let group = h.model.archiveGroups("").first { $0.project.key == Fixture.key("/p/b") }
        XCTAssertEqual(group?.wholeProject, true)
        XCTAssertEqual(group?.project.sessions.map(\.archivedByTemple), [true])
        XCTAssertEqual(h.model.archivedSessionResults("").map(\.id), ["loose"])
        XCTAssertTrue(h.model.archivedSessionResults("").allSatisfy(\.archivedByTemple))

        h.model.restoreProject(Fixture.key("/p/b"), undoManager: nil)
        XCTAssertEqual(h.archived(["in-project"]), ["in-project"], "restoring the project does not bring it back")
    }

    /// The engine no longer resolves an archived row, so History reads the
    /// row's own record.
    func testHistoryListsAnAutoArchivedRowUnderInTempleAsNoTranscript() async throws {
        var h = harness([row("gone")])
        h.publish(["gone": .confirmedAbsent])
        await h.settle()
        h.publish([:])
        h.model.history.activate()
        let end = Date().addingTimeInterval(3)
        while h.model.history.readState != .done, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        h.model.history.scope = .inTemple
        try await Task.sleep(for: .milliseconds(50))
        let historyRow = try XCTUnwrap(h.model.history.visibleRows.first { $0.sessionID == "gone" })
        XCTAssertTrue(historyRow.transcriptMissing)
        XCTAssertTrue(historyRow.member?.archivedByTemple == true)
        XCTAssertFalse(h.model.history.canArchive(historyRow))
    }

    func testOnlyARowChangeTheSweepCouldReadArmsIt() async {
        let h = harness([row("a")])
        h.overlay.touch("a", host: .local, at: clock)
        XCTAssertFalse(h.scheduler.isArmed, "activity is not a reason to sweep")
        h.overlay.rename("a", to: "Named")
        XCTAssertTrue(h.scheduler.isArmed)
        await h.settle()
        XCTAssertNil(h.model.autoArchiveNotice, "no verdicts, no folder evidence, nothing")
    }

    func testQuittingDropsAPendingSweep() async {
        var h = harness([row("a")])
        h.publish(["a": .confirmedAbsent])
        XCTAssertTrue(h.scheduler.isArmed)
        h.model.openSessions.prepareForQuit()
        await h.settle()
        XCTAssertEqual(h.archived(["a"]), [])
        XCTAssertNil(h.model.autoArchiveNotice)
    }

    // MARK: End to end

    private var root: URL!

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func claudeTranscript(_ id: String, in store: URL) throws {
        let project = store.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/p\",\"message\":{\"content\":\"Hi\"}}\n"
            .write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// A file as a v11 build left it: no provenance columns, the v12
    /// migration not applied, and rows written by that build's own SQL.
    /// `present` ran in a folder that exists; `moved` in one deleted since;
    /// `unplugged` on a volume that is not mounted.
    private func v11Database(at path: URL, existingFolder: String) throws {
        do { _ = try TempleDB(path: path) }
        let queue = try DatabaseQueue(path: path.path)
        let yesterday = Date().addingTimeInterval(-day)
        let old = Date().addingTimeInterval(-60 * day)
        try queue.write { raw in
            try raw.execute(sql: "ALTER TABLE session_state DROP COLUMN kept_at")
            try raw.execute(sql: "ALTER TABLE session_state DROP COLUMN archive_reason")
            try raw.execute(sql: "ALTER TABLE session_state DROP COLUMN archived_at")
            try raw.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v12-archive-provenance'")
            // A legacy row: no agent, no join, no activity, no transcript, no folder.
            try raw.execute(sql: "INSERT INTO session_state (id) VALUES ('legacy')")
            try raw.execute(sql: "INSERT INTO session_state (id, agent, directory, last_active_at) VALUES ('present', 'claude', ?, ?)",
                            arguments: [existingFolder, old])
            try raw.execute(sql: "INSERT INTO session_state (id, agent, pinned) VALUES ('pinned', 'claude', 1)")
            try raw.execute(sql: "INSERT INTO session_state (id, agent, last_active_at) VALUES ('recent', 'claude', ?)", arguments: [yesterday])
            try raw.execute(sql: "INSERT INTO session_state (id, agent, directory, last_active_at) VALUES ('moved', 'claude', ?, ?)",
                            arguments: [existingFolder + "-deleted", old])
            try raw.execute(sql: "INSERT INTO session_state (id, agent, directory, last_active_at) VALUES ('unplugged', 'claude', ?, ?)",
                            arguments: ["/Volumes/temple-unmounted-\(UUID().uuidString)/project", old])
        }
        try queue.close()
    }

    private func liveModel(storeRoot: URL) throws -> (AppModel, TempleDB, SessionEngine) {
        root = URL(fileURLWithPath: "/private/tmp/temple-autoarchive-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("state/temple.sqlite")
        try v11Database(at: path, existingFolder: folder.path)
        let db = try TempleDB(path: path)
        XCTAssertNil(try db.sessionState("legacy")?.archiveReason)
        // Observing: an absence is proven only by a host watching its store.
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: storeRoot)], debounceInterval: 0.01)
        let engine = SessionEngine(source: source, database: db)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [engine], database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.archiveSweepScheduler = { _, action in SessionOverlayStore.schedule(0.05, action) }
        // This Mac's real folder evidence, as the local host answers it.
        app.folderEvidence = { await source.directoryEvidence($0.path) }
        app.proveAbsence = { _, agent, ids in await source.proveAbsent(ids: ids, agent: agent) }
        app.start()
        return (app, db, engine)
    }

    private func settle(_ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(5)
        while try !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testAnUpgradedFileArchivesOnlyWhatIsProvenGoneAndARestoreWatchesItAgain() async throws {
        let store = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store) }
        try claudeTranscript("present", in: store)
        try claudeTranscript("moved", in: store)
        try claudeTranscript("unplugged", in: store)
        let (app, db, engine) = try liveModel(storeRoot: store)

        await settle { (app.autoArchiveNotice?.count ?? 0) >= 2 }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.autoArchiveNotice?.entries.map(\.ref.id).sorted(), ["legacy", "moved"])
        XCTAssertEqual(try db.sessionState("legacy")?.archiveReason, .transcriptMissing)
        XCTAssertEqual(try db.sessionState("moved")?.archiveReason, .folderMissing)
        XCTAssertEqual(app.autoArchiveNotice?.message, "Archived 2 sessions whose transcripts or folders are gone")
        for id in ["present", "pinned", "recent", "unplugged"] {
            XCTAssertEqual(try db.sessionState(id)?.archived, false, id)
        }

        // Archived rows leave the engine: nothing is resolved for them, and
        // a transcript that turns up again does not bring one back.
        await settle { app.engineSet.latest?.resolutions["legacy"] == nil }
        XCTAssertNil(app.engineSet.latest?.resolutions["legacy"])
        XCTAssertNil(app.engineSet.latest?.resolutions["moved"])
        try claudeTranscript("legacy", in: store)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try db.sessionState("legacy")?.archived, true)

        // A person's Restore brings it back into the engine, freshly resolved.
        app.restoreSession("legacy", undoManager: nil)
        // (No FSEvents in this test: an explicit request lists the store again.)
        await engine.requestResolution("legacy")
        await settle {
            if case .loaded? = app.engineSet.latest?.resolutions["legacy"] { return true }
            return false
        }
        guard case .loaded? = app.engineSet.latest?.resolutions["legacy"] else {
            return XCTFail("restored row not resolved: \(String(describing: app.engineSet.latest?.resolutions["legacy"]))")
        }
        XCTAssertNotNil(try db.sessionState("legacy")?.keptAt)
        app.engineSet.stop()
    }

    func testAFailedListingArchivesNoTranscript() async throws {
        let notADirectory = URL(fileURLWithPath: "/private/tmp/temple-autoarchive-file-\(UUID().uuidString)")
        try Data().write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }
        try await assertNoTranscriptArchived(storeRoot: notADirectory)
    }

    /// §1's required check: a store root that is not there is a failed
    /// listing, never a completed empty scan.
    func testAMissingStoreRootArchivesNoTranscript() async throws {
        let missing = URL(fileURLWithPath: "/private/tmp/temple-autoarchive-missing-\(UUID().uuidString)")
        try await assertNoTranscriptArchived(storeRoot: missing)
    }

    private func assertNoTranscriptArchived(storeRoot: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (app, db, _) = try liveModel(storeRoot: storeRoot)
        // Every member settles to a verdict; none of them may be a proven absence.
        await settle { ["legacy", "pinned", "recent", "present"].allSatisfy { app.engineSet.latest?.resolutions[$0] != nil
            && app.engineSet.latest?.resolutions[$0] != .resolving } }
        await settle { app.autoArchiveNotice != nil }   // the folder that is gone still goes
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(app.engineSet.latest?.resolutions["legacy"], .confirmedAbsent, file: file, line: line)
        XCTAssertEqual(app.autoArchiveNotice?.entries.map(\.reason), [.folderMissing], file: file, line: line)
        XCTAssertEqual(try db.sessionState("legacy")?.archived, false, file: file, line: line)
        app.engineSet.stop()
    }
}
