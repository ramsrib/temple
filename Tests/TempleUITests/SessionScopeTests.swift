import XCTest
import SQLite3
@testable import TempleUI
import TempleCore

private struct ScopeNoNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

/// The session scope: by default Temple browses only the sessions it has
/// touched — the ones with a row in its DB — and a session from anywhere else
/// is on no surface at all.
@MainActor
final class SessionScopeTests: XCTestCase {
    private func makeModel(_ index: SessionIndex,
                           database: TempleDB? = nil,
                           settings: SettingsStore? = nil) -> (AppModel, SessionOverlayStore) {
        let database = database ?? (try! TempleDB.inMemory())
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(index),
            noiseFilter: ScopeNoNoiseFilter(),
            database: database,
            settings: settings ?? SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay
        )
        model.index = index
        return (model, overlay)
    }

    /// `/p/outside` holds only a session run elsewhere, and is the most recent
    /// project, so recency alone would put it first everywhere.
    private func mixedIndex() -> SessionIndex {
        SessionIndex(projects: [
            Project(path: "/p/outside", sessions: [
                Fixture.session("o1", project: "/p/outside", title: "Outside one", updated: 50),
            ]),
            Project(path: "/p/temple", sessions: [
                Fixture.session("t1", project: "/p/temple", title: "Temple one", updated: 40),
                Fixture.session("t2", project: "/p/temple", title: "Temple two", updated: 30),
            ]),
        ])
    }

    private func database(touching ids: [String]) -> TempleDB {
        let database = try! TempleDB.inMemory()
        for id in ids { try! database.join(sessionID: id, via: .opened) }
        return database
    }

    func testTheShippedDefaultShowsOnlyTempleSessionsOnEverySurface() {
        let (model, overlay) = makeModel(mixedIndex(), database: database(touching: ["t1"]))
        overlay.togglePin("t1")

        XCTAssertEqual(model.settings.sessionScope, .temple)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/temple"])
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["t1"])
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["t1"])
        XCTAssertEqual(model.historyResults("").map(\.id), ["t1"])
        XCTAssertEqual(model.historyResults("one").map(\.id), ["t1"])
        XCTAssertEqual(model.paletteResults("one").map(\.id), ["t1"])
        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/temple"])
        XCTAssertEqual(model.launcherDefaultProject, "/p/temple")
    }

    /// Archiving a project writes a project row, not one per session in it, so
    /// a project Temple never touched a session of stays out of the archive
    /// browser as it does out of the sidebar.
    func testTheArchiveBrowserIsScopedToo() {
        let (model, overlay) = makeModel(mixedIndex(), database: database(touching: ["t1"]))
        overlay.setArchived(true, sessionID: "t1")
        overlay.setProjectArchived(true, path: "/p/outside")

        XCTAssertEqual(model.archivedSessionResults("").map(\.id), ["t1"])
        XCTAssertTrue(model.archivedProjects.isEmpty)
        XCTAssertEqual(model.archiveGroups("").map(\.project.path), ["/p/temple"])
        XCTAssertFalse(overlay.isTempleSession("o1"))
    }

    func testOpeningASessionMakesItATempleSessionForGood() throws {
        let database = database(touching: [])
        let (model, _) = makeModel(mixedIndex(), database: database)
        XCTAssertTrue(model.displayProjects.isEmpty)

        let outside = try XCTUnwrap(mixedIndex().allSessions.first { $0.id == "o1" })
        model.openSessions.openSession(outside)

        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["o1"])
        // A relaunch reads it back from the DB.
        XCTAssertTrue(SessionOverlayStore(db: database).isTempleSession("o1"))
    }

    func testANewClaudeSessionIsCreatedInTempleAsSoonAsItsIdIsMinted() throws {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(SessionIndex(projects: []), database: database)
        let tab = model.openSessions.newSession(agent: .claude, projectPath: "/p/new")
        let id = try XCTUnwrap(tab.sessionID)
        XCTAssertTrue(overlay.isTempleSession(id))
        XCTAssertEqual(try database.sessionState(id)?.joinedVia, .created)
    }

    func testANewCodexSessionIsCreatedInTempleWhenItsIdIsAdopted() throws {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(SessionIndex(projects: []), database: database)
        let tab = model.openSessions.newSession(agent: .codex, projectPath: "/p/new")
        XCTAssertNil(tab.sessionID)
        XCTAssertTrue(overlay.templeSessions.isEmpty)

        model.openSessions.adopt(sessionID: "codex-id", for: tab.id)
        XCTAssertTrue(overlay.isTempleSession("codex-id"))
        XCTAssertEqual(try database.sessionState("codex-id")?.joinedVia, .created)
    }

    /// Resuming makes a session Temple's, but Temple did not create it.
    func testResumingASessionIsNotCreatingIt() throws {
        let database = try! TempleDB.inMemory()
        let (model, _) = makeModel(mixedIndex(), database: database)
        let outside = try XCTUnwrap(mixedIndex().allSessions.first { $0.id == "o1" })
        model.openSessions.openSession(outside)

        XCTAssertEqual(try database.sessionState("o1")?.joinedVia, .opened)
    }

    /// Browsing everything is the in-memory index; toggling it on and off
    /// writes no rows, however many sessions are on disk.
    func testTogglingAllOnDiskWritesNothing() throws {
        let database = database(touching: ["t1"])
        let (model, _) = makeModel(mixedIndex(), database: database)
        model.settings.sessionScope = .all
        _ = model.displayProjects
        _ = model.historyResults("")
        model.settings.sessionScope = .temple
        XCTAssertEqual(try database.sessionStates().map(\.id), ["t1"])
    }

    /// Anything done to a session makes it Temple's: pin an outside session
    /// while browsing everything, and it stays when the scope goes back.
    func testTouchingAnOutsideSessionWhileBrowsingAllMakesItTemples() {
        let database = database(touching: ["t1"])
        let (model, overlay) = makeModel(mixedIndex(), database: database)
        model.settings.sessionScope = .all
        overlay.togglePin("o1")
        model.settings.sessionScope = .temple

        XCTAssertEqual(model.pinnedSessions.map(\.id), ["o1"])
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/outside", "/p/temple"])
        XCTAssertTrue(SessionOverlayStore(db: database).isTempleSession("o1"))
        XCTAssertEqual(try? database.sessionState("o1")?.joinedVia, .imported)
    }

    /// A database that refuses every write, for what happens when one fails.
    private func unwritableDatabase() throws -> TempleDB {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ro-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("temple.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try TempleDB(path: url)            // create + migrate
        return try TempleDB(readOnlyPath: url)
    }

    /// Nothing becomes a Temple session without its row: a failed join leaves
    /// it out, and the setter that asked for it does nothing rather than
    /// writing a row that forgets how the session joined.
    func testAFailedJoinLeavesTheSessionOutAndStopsTheSetter() throws {
        let overlay = SessionOverlayStore(db: try unwritableDatabase())
        XCTAssertFalse(overlay.join("s", via: .opened))
        XCTAssertFalse(overlay.isTempleSession("s"))

        overlay.togglePin("s")
        overlay.rename("s", to: "Named")
        overlay.setColor("red", for: "s")
        overlay.setArchived(true, sessionID: "s")
        XCTAssertFalse(overlay.isTempleSession("s"))
        XCTAssertFalse(overlay.isPinned("s"))
        XCTAssertNil(overlay.customName(for: "s"))
        XCTAssertNil(overlay.color(for: "s"))
        XCTAssertFalse(overlay.isArchived("s"))
    }

    /// A title shows at once but does not make a session Temple's on its own —
    /// with the join failed, it is not written and membership stays honest.
    func testATitleForASessionWhoseJoinFailedIsShownButNotAMember() throws {
        let overlay = SessionOverlayStore(db: try unwritableDatabase())
        overlay.titleFlushDelay = 0
        XCTAssertFalse(overlay.join("s", via: .created))
        overlay.recordGeneratedTitle("Fixing the build", for: "s")
        overlay.flushPendingTitles()

        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Fixing the build")
        XCTAssertFalse(overlay.isTempleSession("s"))
    }

    /// Failure, then recovery, on the same store: a second connection holds an
    /// exclusive lock (every write from the store fails busy) and then lets go.
    /// While it is held nothing joins and no setter acts; once it is released
    /// the next touch joins the session, and only then does its state land.
    func testAJoinThatFailsIsJoinedByTheNextTouchOnceWritesWork() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("temple.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try TempleDB(path: url)
        let overlay = SessionOverlayStore(db: database)

        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &lock), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(overlay.join("s", via: .created))
        overlay.togglePin("s")
        XCTAssertFalse(overlay.isTempleSession("s"))
        XCTAssertFalse(overlay.isPinned("s"))
        XCTAssertEqual(sqlite3_exec(lock, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(lock)
        XCTAssertNil(try database.sessionState("s"))

        overlay.togglePin("s")
        XCTAssertTrue(overlay.isTempleSession("s"))
        let state = try XCTUnwrap(database.sessionState("s"))
        XCTAssertEqual(state.joinedVia, .imported)
        XCTAssertTrue(state.pinned)
    }

    /// A title for a Temple session is kept across a relaunch.
    func testATitleForATempleSessionIsPersisted() throws {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        overlay.titleFlushDelay = 0
        overlay.join("s", via: .created)
        overlay.recordGeneratedTitle("Fixing the build", for: "s")
        overlay.flushPendingTitles()

        XCTAssertEqual(try database.sessionState("s")?.generatedTitle, "Fixing the build")
        XCTAssertEqual(try database.sessionState("s")?.joinedVia, .created)
    }

    /// The default lives in code; only the user's choice is persisted.
    func testAllOnDiskShowsEverythingAndOnlyTheChoiceIsWritten() {
        let defaults = Fixture.uniqueDefaults()
        let settings = SettingsStore(defaults: defaults)
        let (model, _) = makeModel(mixedIndex(), database: database(touching: ["t1"]),
                                   settings: settings)
        XCTAssertNil(defaults.object(forKey: "temple.settings.sessionScope"))

        settings.sessionScope = .all
        XCTAssertEqual(Set(model.displayProjects.flatMap(\.sessions).map(\.id)), ["o1", "t1", "t2"])
        XCTAssertEqual(defaults.string(forKey: "temple.settings.sessionScope"), "all")
        XCTAssertEqual(SettingsStore(defaults: defaults).sessionScope, .all)

        settings.sessionScope = .temple
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["t1"])
    }
}
