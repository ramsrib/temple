import XCTest
import SQLite3
import GRDB
import CoreServices
@testable import TempleUI
@testable import TempleCore


/// The session scope: by default Temple browses only the sessions it has
/// touched — the ones with a row in its DB — and a session from anywhere else
/// is on no surface at all.
@MainActor
final class SessionScopeTests: XCTestCase {
    private func makeModel(_ index: CatalogFixtureIndex,
                           database: TempleDB? = nil,
                           settings: SettingsStore? = nil) -> (AppModel, SessionOverlayStore) {
        let database = database ?? (try! TempleDB.inMemory())
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(index)],
            database: database,
            settings: settings ?? SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay,
            hostRegistry: Fixture.hostsWithoutFolderEvidence()
        )

        return (model, overlay)
    }

    private func summary(_ id: String = "legacy", cwd: String? = "/transcript",
                         prompt: String? = "First prompt", time: TimeInterval = 100) -> TranscriptSummary {
        TranscriptSummary(id: id, agent: .claude,
            locator: TranscriptLocator(host: .local, path: "/private/tmp/\(id).jsonl"),
            modifiedAt: Date(timeIntervalSince1970: time), cwd: cwd, firstPrompt: prompt,
            directoryHint: "/lossy-hint",
            laterPromptHint: "Later hint", legacyTitleHint: "Legacy hint")
    }

    func testALegacyRowIsFilledFromItsTranscriptOnce() throws {
        let counter = FillSQLCounter()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                if event.expandedDescription.contains("UPDATE session_state SET agent = COALESCE") {
                    counter.increment()
                }
            }
        }
        let db = try TempleDB(database: DatabaseQueue(configuration: config))
        try db.join(sessionID: "legacy", via: .imported)
        let (model, overlay) = makeModel(CatalogFixtureIndex(projects: []), database: db)
        let facts = summary()
        for _ in 0..<20 {
            model.receiveEngineSnapshot(.authorized(generation: 1,
                resolutions: ["legacy": .loaded(facts.locator.localURL!)], summaries: ["legacy": facts], in: db))
        }
        XCTAssertEqual(counter.count, 1)
        let row = try XCTUnwrap(db.sessionState("legacy"))
        XCTAssertEqual(row.agent, .claude)
        XCTAssertEqual(row.directory, "/transcript")
        XCTAssertEqual(row.directorySource, .transcript)
        XCTAssertEqual(row.title, "First prompt")
        XCTAssertNil(row.generatedTitle)
        XCTAssertEqual(row.lastActiveAt, facts.modifiedAt)
        XCTAssertEqual(overlay.rows["legacy"], row)
        model.receiveEngineSnapshot(.authorized(generation: 2, resolutions: [:],
            summaries: ["legacy": summary(cwd: "/changed", prompt: "Changed", time: 200)], in: db, opRevision: 2))
        XCTAssertEqual(try db.sessionState("legacy"), row)
        XCTAssertEqual(counter.count, 1)
    }

    func testClaudeRecordedTitleSurvivesFillAndOverlayReconstruction() throws {
        try assertLegacyTitleSurvivesFill(agent: .claude, title: "Claude recorded title")
    }

    func testCodexSharedTitleSurvivesFillAndOverlayReconstruction() throws {
        try assertLegacyTitleSurvivesFill(agent: .codex, title: "Codex shared title")
    }

    /// Recorded titles are facts: the fill writes the title History shows,
    /// rather than demoting it to the first prompt.

    private func assertLegacyTitleSurvivesFill(agent: Agent, title: String) throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .imported)
        let facts = TranscriptSummary(id: "legacy", agent: agent,
            locator: TranscriptLocator(host: .local, path: "/private/tmp/legacy.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 100), cwd: "/project", firstPrompt: "First prompt",
            recordedTitle: agent == .claude ? title : nil, sharedTitle: agent == .codex ? title : nil)
        let legacy = facts
        let overlay = SessionOverlayStore(db: db)
        overlay.applyFacts(["legacy": try XCTUnwrap(AuthorizedFacts.current(facts, in: db))])
        for store in [overlay, SessionOverlayStore(db: db)] {
            XCTAssertNil(store.generatedTitle(for: "legacy"))
            XCTAssertEqual(store.displayTitle(for: legacy), title)
            XCTAssertEqual(Session(state: try XCTUnwrap(store.rows["legacy"])).displayTitle, title)
        }
        // A genuine agent retitle remains a legacy override after reconstruction.
        overlay.recordGeneratedTitle("OSC retitle", for: "legacy")
        overlay.flushPendingTitles()
        XCTAssertEqual(SessionOverlayStore(db: db).displayTitle(for: legacy), "OSC retitle")
    }

    func testQueuedLocalFillCannotChangeARowRejoinedOnAnotherHost() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .imported)
        let overlay = SessionOverlayStore(db: db)
        // Facts authorized for the local membership, delivered after it left.
        let stale = try XCTUnwrap(AuthorizedFacts.current(summary(), in: db))
        let committed = DispatchSemaphore(value: 0)
        let remote = HostID(rawValue: "remote")
        // Hold the main actor until both commits finish: the row observer's
        // queued refresh cannot update the overlay before the stale summary.
        DispatchQueue.global().async {
            defer { committed.signal() }
            do {
                XCTAssertTrue(try db.leave(sessionID: "legacy", host: .local))
                try db.join(sessionID: "legacy", via: .imported, core: SessionCore(host: remote))
            } catch { XCTFail("leave/rejoin failed: \(error)") }
        }
        XCTAssertEqual(committed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(overlay.rows["legacy"]?.host, .local)
        XCTAssertEqual(try db.sessionState("legacy")?.host, remote)
        var mismatched: [String] = []
        overlay.onOwnershipMismatch = { id, _ in mismatched.append(id) }
        overlay.applyFacts(["legacy": stale])
        XCTAssertEqual(mismatched, ["legacy"])
        let row = try XCTUnwrap(db.sessionState("legacy"))
        XCTAssertEqual(row.host, remote)
        XCTAssertNil(row.agent)
        XCTAssertNil(row.directory)
        XCTAssertNil(row.directorySource)
        XCTAssertNil(row.title)
        XCTAssertNil(row.lastActiveAt)
        XCTAssertEqual(overlay.rows["legacy"], row)
        // A fact from the expected host can still fill the same row.
        XCTAssertEqual(try db.fillCoreFields(sessionID: "legacy", host: remote, title: "Remote prompt"), .changed([.title]))
    }

    func testCompleteRowBurstsDoNotRebuildPresentation() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .imported)
        let (model, overlay) = makeModel(CatalogFixtureIndex(projects: []), database: db)
        let resolution: [String: MemberResolution] = ["legacy": .loaded(summary().locator.localURL!)]
        model.receiveEngineSnapshot(.authorized(generation: 1, resolutions: resolution, summaries: ["legacy": summary()], in: db))
        let filledBuilds = model.sessionPresentationBuildCount
        let filledSessions = model.sessions
        // Each publication has changed transcript facts and generation, but the
        // completed row and its resolution stay identical.
        for tick in 2...30 {
            model.receiveEngineSnapshot(.authorized(generation: UInt64(tick), resolutions: resolution,
                summaries: ["legacy": summary(prompt: "Changed \(tick)", time: Double(tick + 100))], in: db, opRevision: UInt64(tick)))
        }
        XCTAssertEqual(model.sessionPresentationBuildCount, filledBuilds)
        XCTAssertEqual(model.sessions, filledSessions)
        model.receiveEngineSnapshot(EngineSnapshot(generation: 31, resolutions: ["legacy": .confirmedAbsent]))
        XCTAssertEqual(model.sessionPresentationBuildCount, filledBuilds + 1)
        XCTAssertNil(model.sessions.first?.transcript)
        overlay.rename("legacy", to: "Renamed")
        XCTAssertEqual(model.sessionPresentationBuildCount, filledBuilds + 2)
        XCTAssertEqual(model.sessions.first?.displayTitle, "Renamed")
    }

    func testATabDirectoryIsNeverOverwrittenByTheTranscriptCwd() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .opened,
                    core: SessionCore(directory: "/tab", directorySource: .tab))
        let overlay = SessionOverlayStore(db: db)
        overlay.applyFacts(["legacy": try XCTUnwrap(AuthorizedFacts.current(summary(), in: db))])
        XCTAssertEqual(try db.sessionState("legacy")?.directory, "/tab")
        XCTAssertEqual(try db.sessionState("legacy")?.directorySource, .tab)
        XCTAssertEqual(try db.sessionState("legacy")?.title, "First prompt")
    }

    func testFillNeverPersistsHints() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .imported)
        let overlay = SessionOverlayStore(db: db)
        overlay.applyFacts(["legacy": try XCTUnwrap(AuthorizedFacts.current(summary(cwd: nil, prompt: nil), in: db))])
        let row = try XCTUnwrap(db.sessionState("legacy"))
        XCTAssertNil(row.directory)
        XCTAssertNil(row.directorySource)
        XCTAssertNil(row.title)
        XCTAssertNil(row.generatedTitle)
        XCTAssertEqual(row.agent, .claude)
        overlay.applyFacts(["legacy": try XCTUnwrap(AuthorizedFacts.current(summary(), in: db, opRevision: 2))])
        XCTAssertEqual(try db.sessionState("legacy")?.title, "First prompt")
    }

    func testSessionsAreBuiltFromRowsIncludingMembersWithoutATranscript() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "missing", via: .opened, agent: .codex,
                    core: SessionCore(host: HostID(rawValue: "remote"), directory: "/row", directorySource: .tab,
                                      title: "Row title", lastActiveAt: Date(timeIntervalSince1970: 5)))
        try db.join(sessionID: "directoryless", via: .imported)
        let (model, overlay) = makeModel(CatalogFixtureIndex(projects: []), database: db)
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: ["missing": .confirmedAbsent]))
        XCTAssertEqual(Set(model.sessions.map(\.id)), ["missing", "directoryless"])
        let session = try XCTUnwrap(model.sessions.first { $0.id == "missing" })
        XCTAssertEqual(session.displayTitle, "Row title")
        XCTAssertEqual(session.directory, "/row")
        XCTAssertEqual(session.project, ProjectKey(host: HostID(rawValue: "remote"), path: "/row"))
        XCTAssertTrue(session.canResume)
        XCTAssertNil(session.transcript)
        XCTAssertEqual(model.rowProjects.count, 1)
        try db.setTitle("Changed by row observer", sessionID: "missing", host: HostID(rawValue: "remote"))
        XCTAssertEqual(overlay.rows["missing"]?.title, "Changed by row observer")
        overlay.touch("missing", host: HostID(rawValue: "remote"), at: Date(timeIntervalSince1970: 500))
        let end = Date().addingTimeInterval(2)
        while model.sessions.first(where: { $0.id == "missing" })?.sortDate != Date(timeIntervalSince1970: 500), Date() < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sessions.first(where: { $0.id == "missing" })?.displayTitle, "Changed by row observer")
        XCTAssertEqual(model.sessions.first(where: { $0.id == "missing" })?.sortDate, Date(timeIntervalSince1970: 500))
    }

    func testCodexHistoryPromptsFillRowsAtStartupAndOnExplicitEnrichment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessionDirectory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = UUID().uuidString.lowercased()
        let late = UUID().uuidString.lowercased()
        let db = try TempleDB.inMemory()
        for id in [initial, late] {
            let file = sessionDirectory.appendingPathComponent("rollout-2026-10-03T00-00-00-\(id).jsonl")
            try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/recorded\"}}"
                .write(to: file, atomically: true, encoding: .utf8)
            try db.join(sessionID: id, via: .imported, agent: .codex, locator: TranscriptLocator(localURL: file))
        }
        let history = root.appendingPathComponent("history.jsonl")
        let firstLine = "{\"session_id\":\"\(initial)\",\"ts\":10,\"text\":\"First recorded prompt\"}"
        try firstLine.write(to: history, atomically: true, encoding: .utf8)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02), database: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [watcher], database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.start()
        let initialDeadline = Date().addingTimeInterval(3)
        while (model.isLoading || model.sessions.first(where: { $0.id == initial })?.state.title == nil), Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(try db.sessionState(initial)?.title, "First recorded prompt")
        XCTAssertNil(try db.sessionState(late)?.title)
        try (firstLine + "\n{\"session_id\":\"\(late)\",\"ts\":20,\"text\":\"Late recorded prompt\"}")
            .write(to: history, atomically: true, encoding: .utf8)
        await watcher.requestResolution(late)
        let lateDeadline = Date().addingTimeInterval(3)
        while model.sessions.first(where: { $0.id == late })?.state.title == nil, Date() < lateDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(try db.sessionState(late)?.title, "Late recorded prompt")
        XCTAssertNil(try db.sessionState(initial)?.generatedTitle)
        XCTAssertNil(try db.sessionState(late)?.generatedTitle)
        await watcher.stop()
    }

    func testWatcherAdapterPublishesLegacyIndexAndFillsRows() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p3-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("legacy.jsonl")
        try "{\"type\":\"user\",\"sessionId\":\"legacy\",\"cwd\":\"/facts\",\"message\":{\"content\":\"Real prompt\"}}".write(to: file, atomically: true, encoding: .utf8)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .imported)
        try db.join(sessionID: "missing", via: .imported,
                    core: SessionCore(directory: "/missing", title: "Kept row"))
        let engine = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)]), database: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [engine], database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.start()
        let end = Date().addingTimeInterval(3)
        while (model.isLoading || model.sessions.first(where: { $0.id == "legacy" })?.state.title == nil), Date() < end {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(Set(model.sessions.map(\.id)), ["legacy", "missing"])
        XCTAssertEqual(model.sessions.first { $0.id == "legacy" }?.displayTitle, "Real prompt")
        XCTAssertEqual(try db.sessionState("legacy")?.directory, "/facts")
        XCTAssertEqual(model.sessions.first(where: { $0.id == "legacy" })?.displayTitle, "Real prompt")
        XCTAssertEqual(model.sessions.first(where: { $0.id == "missing" })?.displayTitle, "Kept row")
        XCTAssertEqual(model.sessions.first(where: { $0.id == "missing" })?.resolution, .confirmedAbsent)
        let filled = try XCTUnwrap(db.sessionState("legacy"))
        let activity = try XCTUnwrap(filled.lastActiveAt)
        model.overlay.touch("legacy", host: .local, at: activity.addingTimeInterval(-100))
        XCTAssertEqual(model.overlay.rows["legacy"]?.lastActiveAt, filled.lastActiveAt)
        await engine.stop()
    }

    func testDisplayTitleChainAndSortDate() {
        func row(name: String? = nil, title: String? = nil, agent: Agent? = nil,
                 active: Date? = nil, opened: Date? = nil, joined: Date? = nil) -> SessionState {
            SessionState(id: "s", pinned: false, archived: false, customName: name, color: nil,
                         generatedTitle: "Legacy title", lastOpenedAt: opened, joinedVia: nil, joinedAt: joined,
                         agent: agent, directory: "/row", title: title, lastActiveAt: active)
        }
        XCTAssertEqual(Session(state: row()).displayTitle, "Untitled session")
        XCTAssertEqual(Session(state: row(agent: .codex)).displayTitle, "New Codex session")
        XCTAssertEqual(Session(state: row(agent: .claude)).displayTitle, "New Claude session")
        XCTAssertEqual(Session(state: row(title: "Title", agent: .claude)).displayTitle, "Title")
        XCTAssertEqual(Session(state: row(name: "Custom", title: "Title", agent: .claude)).displayTitle, "Custom")
        let a = Date(timeIntervalSince1970: 1), b = Date(timeIntervalSince1970: 2), c = Date(timeIntervalSince1970: 3)
        XCTAssertEqual(Session(state: row(active: a, opened: b, joined: c)).sortDate, a)
        XCTAssertEqual(Session(state: row(opened: b, joined: c)).sortDate, b)
        XCTAssertEqual(Session(state: row(joined: c)).sortDate, c)
        XCTAssertEqual(Session(state: row()).sortDate, .distantPast)
        XCTAssertFalse(Session(state: row()).canResume)
        let url = URL(fileURLWithPath: "/private/tmp/s.jsonl")
        XCTAssertEqual(Session(state: row(agent: .codex), resolution: .loaded(url)).transcript?.localURL, url)
    }

    /// `/p/outside` holds only a session run elsewhere, and is the most recent
    /// project, so recency alone would put it first everywhere.
    private func mixedIndex() -> CatalogFixtureIndex {
        CatalogFixtureIndex(projects: [
            CatalogFixtureProject(path: "/p/outside", sessions: [
                Fixture.session("o1", project: "/p/outside", title: "Outside one", updated: 50),
            ]),
            CatalogFixtureProject(path: "/p/temple", sessions: [
                Fixture.session("t1", project: "/p/temple", title: "Temple one", updated: 40),
                Fixture.session("t2", project: "/p/temple", title: "Temple two", updated: 30),
            ]),
        ])
    }

    private func database(touching ids: [String]) -> TempleDB {
        let database = try! TempleDB.inMemory()
        for id in ids {
            let row = Fixture.row(id, project: "/p/temple", title: "Temple one", updated: 40)
            Fixture.join([row], to: database)
        }
        return database
    }

    func testTheShippedDefaultShowsOnlyTempleSessionsOnEverySurface() {
        let (model, overlay) = makeModel(mixedIndex(), database: database(touching: ["t1"]))
        overlay.togglePin("t1")

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/temple"])
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["t1"])
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["t1"])
        XCTAssertEqual(model.paletteResults("one").map(\.id), ["t1"])
        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/temple"])
        XCTAssertEqual(model.launcherDefaultProjectKey?.path, "/p/temple")
    }

    /// Archiving a project writes a project row, not one per session in it, so
    /// a project Temple never touched a session of stays out of the archive
    /// browser as it does out of the sidebar.
    func testTheArchiveBrowserIsScopedToo() {
        let (model, overlay) = makeModel(mixedIndex(), database: database(touching: ["t1"]))
        overlay.setArchived(true, sessionID: "t1")
        overlay.setProjectArchived(true, key: Fixture.key("/p/outside"))

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
        model.receiveEngineSnapshot(.authorized(generation: 1, resolutions: [:],
            summaries: ["o1": summary("o1", cwd: "/p/outside", prompt: "Outside one", time: 50)], in: database))

        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["o1"])
        // A relaunch reads it back from the DB.
        XCTAssertTrue(SessionOverlayStore(db: database).isTempleSession("o1"))
    }

    func testANewClaudeSessionIsCreatedInTempleAsSoonAsItsIdIsMinted() throws {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(CatalogFixtureIndex(projects: []), database: database)
        let tab = model.openSessions.newSession(agent: .claude, project: Fixture.key("/p/new"))
        let id = try XCTUnwrap(tab.sessionID)
        XCTAssertTrue(overlay.isTempleSession(id))
        XCTAssertEqual(try database.sessionState(id)?.joinedVia, .created)
    }

    func testANewCodexSessionIsCreatedInTempleWhenItsIdIsAdopted() throws {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(CatalogFixtureIndex(projects: []), database: database)
        let tab = model.openSessions.newSession(agent: .codex, project: Fixture.key("/p/new"))
        XCTAssertNil(tab.sessionID)
        XCTAssertTrue(overlay.rows.isEmpty)

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

    /// Browsing a supplied snapshot does not import its outside sessions.
    func testBrowsingDoesNotJoinOutsideSessions() throws {
        let database = database(touching: ["t1"])
        let (model, _) = makeModel(mixedIndex(), database: database)
        _ = model.displayProjects
        XCTAssertEqual(try database.sessionStates().map(\.id), ["t1"])
    }

    /// Pins exercise the committed overlay.join path that History will use to import an outside session.
    func testExplicitImportMakesAnOutsideSessionTemples() {
        let database = database(touching: ["t1"])
        let (model, overlay) = makeModel(mixedIndex(), database: database)
        overlay.join("o1", via: .imported, agent: .claude, core: SessionCore(directory: "/p/outside", directorySource: .transcript, title: "Outside one", lastActiveAt: Date(timeIntervalSince1970: 50)))
        overlay.togglePin("o1")

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

    /// Two connections to one file: a row the other inserted after this
    /// store read is not in `rows`, and this store's join of it writes
    /// nothing and notifies nobody. The join still makes it a member here —
    /// and so do an import of it — so the touches, retitles and opens that
    /// follow are not dropped.
    func testAJoinOrImportOfARowAnotherConnectionInsertedMakesItAMemberHere() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-two-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("temple.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mine = try TempleDB(path: url)
        let overlay = SessionOverlayStore(db: mine)
        overlay.titleFlushDelay = 0
        let other = try TempleDB(path: url)
        try other.join(sessionID: "s", via: .opened, agent: .claude, core: SessionCore(directory: "/p", title: "Elsewhere"))
        let summary = TranscriptSummary(id: "i", agent: .codex, locator: TranscriptLocator(host: .local, path: "/tmp/i.jsonl"),
                                        modifiedAt: Date(timeIntervalSince1970: 10), cwd: "/q", firstPrompt: "Imported")
        try other.join(sessionID: "i", via: .imported, agent: .codex, locator: summary.locator, core: SessionCore(filling: summary))
        XCTAssertNil(overlay.rows["s"])
        XCTAssertNil(overlay.rows["i"])

        XCTAssertTrue(overlay.join("s", via: .opened, agent: .claude).isJoined)
        XCTAssertTrue(overlay.isTempleSession("s"))
        XCTAssertEqual(overlay.rows["s"]?.directory, "/p")
        overlay.touch("s", host: .local, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(overlay.rows["s"]?.lastActiveAt, Date(timeIntervalSince1970: 100), "the touch is not dropped")
        overlay.recordGeneratedTitle("Agent title", for: "s")
        overlay.flushPendingTitles()
        XCTAssertEqual(try other.sessionState("s")?.generatedTitle, "Agent title", "nor the retitle")
        overlay.recordOpened("s", host: .local, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try other.sessionState("s")?.lastOpenedAt, Date(timeIntervalSince1970: 200), "nor the open")

        guard case .joined = overlay.import([summary]).first else { return XCTFail("import") }
        XCTAssertTrue(overlay.isTempleSession("i"), "an import that reports success is a member")
        XCTAssertEqual(overlay.rows["i"]?.directory, "/q")
    }

    /// Nothing becomes a Temple session without its row: a failed join leaves
    /// it out, and the setter that asked for it does nothing rather than
    /// writing a row that forgets how the session joined.
    func testAFailedJoinLeavesTheSessionOutAndStopsTheSetter() throws {
        let overlay = SessionOverlayStore(db: try unwritableDatabase())
        XCTAssertFalse(overlay.join("s", via: .opened).isJoined)
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

    /// A title does not make a session Temple's on its own — with the join
    /// failed, it is not written, and with no row there is nothing to show it
    /// on: membership and the title both follow the row.
    func testATitleForASessionWhoseJoinFailedIsNeitherWrittenNorAMember() throws {
        let overlay = SessionOverlayStore(db: try unwritableDatabase())
        overlay.titleFlushDelay = 0
        XCTAssertFalse(overlay.join("s", via: .created).isJoined)
        overlay.recordGeneratedTitle("Fixing the build", for: "s")
        overlay.flushPendingTitles()

        XCTAssertNil(overlay.generatedTitle(for: "s"))
        XCTAssertNil(overlay.rows["s"])
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
        XCTAssertFalse(overlay.join("s", via: .created).isJoined)
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

    func testRetiredScopeKeyIsIgnoredAndPreserved() {
        let defaults = Fixture.uniqueDefaults()
        defaults.set("all", forKey: "temple.settings.sessionScope")
        let settings = SettingsStore(defaults: defaults)
        let (model, _) = makeModel(mixedIndex(), database: database(touching: ["t1"]), settings: settings)
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["t1"])
        settings.fontSize = 17
        XCTAssertEqual(defaults.string(forKey: "temple.settings.sessionScope"), "all")
    }
}

private final class FillSQLCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
