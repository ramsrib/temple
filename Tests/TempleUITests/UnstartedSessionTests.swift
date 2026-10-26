import XCTest
import TempleCore
@testable import TempleUI
@testable import TempleLocalHost

/// ⌘T joins a Claude session the moment its id is minted. Closed before
/// anything was sent, the CLI never writes a transcript, and the row used to
/// stay as a permanent "New Claude session". It may go only on a fresh,
/// completed absence; anything less keeps it.
@MainActor
final class UnstartedSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-unstarted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// `storeRoot` is the Claude store; pass a regular file to make every
    /// listing fail.
    private func model(_ db: TempleDB, storeRoot: URL, saved: [PersistedTab] = []) -> AppModel {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: storeRoot)], debounceInterval: 0.01,
                                        monitorChanges: false)
        let persistence = UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults())
        persistence.save(saved)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                           engines: [SessionEngine(source: source, database: db)],
                           persistence: persistence,
                           database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        return app
    }

    private func settle(_ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(3)
        while try !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Give a refused discard every chance to (wrongly) happen.
    private func quiesce() async { try? await Task.sleep(for: .milliseconds(300)) }

    func testAnAbandonedNewTabLeavesNoRowButAUsedOneStays() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let abandoned = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let used = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let abandonedID = try XCTUnwrap(abandoned.sessionID), usedID = try XCTUnwrap(used.sessionID)
        (abandoned.surface as? FakeTerminalSurface)?.simulateTitle("Claude Code")
        app.overlay.flushPendingTitles()
        (used.surface as? FakeTerminalSurface)?.simulateSubmitInput()

        app.openSessions.closeTab(abandoned.id)
        app.openSessions.closeTab(used.id)
        try await settle { try db.sessionState(abandonedID) == nil }
        XCTAssertNil(try db.sessionState(abandonedID), "a title alone does not keep it")
        XCTAssertFalse(app.overlay.isTempleSession(abandonedID))
        XCTAssertNotNil(try db.sessionState(usedID), "something was sent: it stays")
        app.openSessions.reopenLastClosedTab()
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, usedID)
        app.openSessions.closeTab(try XCTUnwrap(app.openSessions.activeTab).id)
        app.openSessions.reopenLastClosedTab()
        app.openSessions.reopenLastClosedTab()
        XCTAssertNotEqual(app.openSessions.activeTab?.sessionID, abandonedID, "nothing to reopen for a discarded row")
    }

    /// A relaunch between the ⌘T and the close (an install, a crash): the
    /// tab comes back as a restored chip, and closing it unused drops the
    /// row the same way, on the same fresh proof. A chip of a session with a
    /// transcript stays, closed unused or not.
    func testAChipRestoredFromAnUnusedNewTabIsDroppedWhenClosed() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let unusedID = UUID().uuidString.lowercased(), usedID = UUID().uuidString.lowercased()
        for id in [unusedID, usedID] {
            try db.join(sessionID: id, via: .created, agent: .claude,
                        core: SessionCore(host: .local, directory: "/p", directorySource: .tab))
        }
        let project = store.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"sessionId\":\"\(usedID)\",\"cwd\":\"/p\",\"message\":{\"content\":\"Hi\"}}\n"
            .write(to: project.appendingPathComponent("\(usedID).jsonl"), atomically: true, encoding: .utf8)
        let app = model(db, storeRoot: store, saved: [
            PersistedTab(sessionID: unusedID, agent: .claude, projectPath: "/p", title: "New Claude session"),
            PersistedTab(sessionID: usedID, agent: .claude, projectPath: "/p", title: "New Claude session")])
        app.openSessions.restore()
        let unused = try XCTUnwrap(app.openSessions.openTab(forSessionID: unusedID))
        let used = try XCTUnwrap(app.openSessions.openTab(forSessionID: usedID))
        XCTAssertTrue(unused.isResume && used.isResume, "restored chips")

        app.openSessions.closeTab(unused.id)
        app.openSessions.closeTab(used.id)
        try await settle { try db.sessionState(unusedID) == nil }
        XCTAssertNil(try db.sessionState(unusedID), "never a session: the chip's close drops it as ⌘W would have")
        await quiesce()
        XCTAssertNotNil(try db.sessionState(usedID), "a transcript carries it")
    }

    /// A model over an engine whose absence check a test holds and answers.
    private func model(_ db: TempleDB, engine: FakeEngine) -> AppModel {
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [engine],
                           persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
                           database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        return app
    }

    /// The membership the absence was confirmed for is the one dropped: a
    /// row that left and joined again while the check was out is another
    /// session, and stays.
    func testAMembershipReplacedDuringTheAbsenceCheckIsNotDropped() async throws {
        let db = try TempleDB.inMemory()
        let engine = FakeEngine()
        engine.absent = true
        let gate = Gate()
        engine.absenceGate = { await gate.wait() }
        let app = model(db, engine: engine)
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        let old = try XCTUnwrap(try XCTUnwrap(db.sessionState(id)).incarnation)
        app.openSessions.closeTab(tab.id)
        // While the check is out: the old membership goes (by any means),
        // and the id joins again as a new one.
        XCTAssertEqual(try db.discardNeverStarted([MembershipRef(id: id, host: .local, incarnation: old)], idleBefore: nil), [id])
        try db.join(sessionID: id, via: .created, agent: .claude, core: SessionCore(host: .local, directory: "/p", directorySource: .tab))
        let fresh = try XCTUnwrap(try XCTUnwrap(db.sessionState(id)).incarnation)
        XCTAssertNotEqual(old, fresh)
        await gate.open()
        await quiesce()
        XCTAssertEqual(try db.sessionState(id)?.incarnation, fresh, "the old membership's absence says nothing about the new one")
    }

    /// A row a person restored is kept: the close's own touch clears the
    /// keep when it flushes, which may be while the absence check is still
    /// out, so the keep is read before the check, not only in the statement.
    func testAKeptRowStaysWhenItsCloseTouchFlushesDuringTheAbsenceCheck() async throws {
        let db = try TempleDB.inMemory()
        let engine = FakeEngine()
        engine.absent = true
        let gate = Gate()
        engine.absenceGate = { await gate.wait() }
        let app = model(db, engine: engine)
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        // A restore a minute ago: the close's touch, dated now, outranks it.
        try db.setArchived(true, sessionID: id)
        try db.setArchived(false, sessionID: id, at: Date().addingTimeInterval(-60))
        XCTAssertNotNil(try XCTUnwrap(db.sessionState(id)).keptAt, "restored by a person: kept")
        app.openSessions.closeTab(tab.id)
        app.overlay.flushPendingTouches()
        XCTAssertNil(try XCTUnwrap(db.sessionState(id)).keptAt, "the close's touch spent the keep")
        await gate.open()
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id), "kept when the close decided")
    }

    /// A listing that fails proves nothing, whatever the snapshot said.
    func testAFailedScanKeepsTheRow() async throws {
        let notADirectory = root.appendingPathComponent("claude")
        try Data().write(to: notADirectory)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: notADirectory)
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        app.receiveEngineSnapshot(EngineSnapshot(generation: .max, resolutions: [id: .awaitingCreation]))
        app.openSessions.closeTab(tab.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id))
    }

    /// The published verdict is old: the transcript appeared after it, with
    /// no event to say so. The fresh walk finds it.
    func testAStaleAbsenceKeepsTheRowWhoseTranscriptExistsNow() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        // Let the engine publish its verdict from the empty listing first.
        await quiesce()
        let project = store.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/p\",\"message\":{\"content\":\"Hi\"}}\n"
            .write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        app.openSessions.closeTab(tab.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id))
    }

    func testARowTheUserTouchedOrThatHasATranscriptPathIsKept() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let pinned = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let pinnedID = try XCTUnwrap(pinned.sessionID)
        app.overlay.togglePin(pinnedID)
        app.openSessions.closeTab(pinned.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(pinnedID))
        // Unused, but kept: it still reopens.
        app.openSessions.reopenLastClosedTab()
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, pinnedID)

        try db.join(sessionID: "hinted", via: .created, agent: .claude,
                    locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/gone/hinted.jsonl")))
        let hinted = try XCTUnwrap(db.sessionState("hinted"))
        XCTAssertFalse(try db.discardUnstartedCreation(
            MembershipRef(id: "hinted", host: .local, incarnation: try XCTUnwrap(hinted.incarnation))))
        XCTAssertNotNil(try db.sessionState("hinted"))
    }

    /// A row a person opened from History is theirs, however it came to
    /// be: closing that tab unused (the resume found no conversation) keeps
    /// it, as the sweep would.
    func testARowOpenedFromHistoryIsKeptWhenItsTabClosesUnused() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let id = UUID().uuidString.lowercased()
        try db.join(sessionID: id, via: .created, agent: .claude,
                    core: SessionCore(host: .local, directory: "/p", directorySource: .tab))
        let app = model(db, storeRoot: store)
        let row = try XCTUnwrap(app.sessions.first { $0.id == id })
        app.openSessions.openSession(row)
        let tab = try XCTUnwrap(app.openSessions.openTab(forSessionID: id))
        XCTAssertNotNil(try XCTUnwrap(db.sessionState(id)).lastOpenedAt, "the open is recorded")
        app.openSessions.closeTab(tab.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id), "opened from History: a person's row")
    }
}
