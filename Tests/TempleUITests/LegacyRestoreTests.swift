import XCTest
import GRDB
import TempleCore
@testable import TempleUI

/// The first launch after upgrading to v10: every row was written by v9, so
/// none has a directory or title yet, and some transcripts are long pruned.
/// Restore runs before the engine has filled anything.
@MainActor
final class LegacyRestoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-legacy-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The v9 schema as v9 left it, applied by hand so no v10 code runs first.
    private func writeV9Database(at path: URL, project: String) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1'), ('v2-open-tab-metadata'),
                    ('v3-generated-title'), ('v4-session-color'), ('v5-open-tab-active'),
                    ('v6-ui-state'), ('v7-project-state'), ('v8-session-join'),
                    ('v9-session-transcript');
                CREATE TABLE session_state (id TEXT PRIMARY KEY, pinned BOOLEAN NOT NULL DEFAULT 0,
                    archived BOOLEAN NOT NULL DEFAULT 0, custom_name TEXT, last_opened_at DATETIME,
                    generated_title TEXT, color TEXT, joined_via TEXT, joined_at DATETIME,
                    agent TEXT, transcript_path TEXT);
                CREATE TABLE open_tabs (project_path TEXT NOT NULL, session_id TEXT NOT NULL,
                    position INTEGER NOT NULL, agent TEXT NOT NULL DEFAULT 'claude',
                    title TEXT NOT NULL DEFAULT '', active BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY (project_path, position), UNIQUE (project_path, session_id));
                CREATE TABLE process_registry (pid INTEGER PRIMARY KEY, session_id TEXT NOT NULL,
                    started_at DATETIME NOT NULL);
                CREATE TABLE ui_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE project_state (path TEXT PRIMARY KEY, archived BOOLEAN NOT NULL DEFAULT 0,
                    position INTEGER);
                """)
            // A Claude session whose transcript was pruned, and a Codex one
            // that never recorded its agent on the row.
            try db.execute(sql: """
                INSERT INTO session_state (id, joined_via, agent, transcript_path)
                    VALUES ('pruned-claude', 'opened', 'claude', '/gone/pruned-claude.jsonl');
                INSERT INTO session_state (id, joined_via) VALUES ('legacy-codex', 'created');
                INSERT INTO open_tabs (project_path, session_id, position, agent, title, active)
                    VALUES (?, 'pruned-claude', 0, 'claude', 'Fix the parser', 1),
                           (?, 'legacy-codex', 1, 'codex', 'Port the tests', 0);
                """, arguments: [project, project])
        }
        try queue.close()
    }

    func testRestoreOverAV9DatabaseResumesTheActiveTabAndCopiesChipsWithoutWriting() throws {
        let project = directory.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        try writeV9Database(at: path, project: project)
        let db = try TempleDB(path: path)
        XCTAssertNil(try db.sessionState("pruned-claude")?.directory, "v10 adds the column empty")

        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory,
                           indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                           database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           stateDirectory: directory)
        app.start()

        let tabs = app.openSessions.tabs
        XCTAssertEqual(tabs.map(\.sessionID), ["pruned-claude", "legacy-codex"])
        let active = try XCTUnwrap(app.openSessions.activeTab)
        XCTAssertEqual(active.sessionID, "pruned-claude", "the tab the user left comes back")
        XCTAssertNil(active.launchPreparationError)
        let surface = try XCTUnwrap(factory.created.first)
        XCTAssertEqual(factory.created.count, 1, "lazy restore: one agent, not the set")
        XCTAssertEqual(surface.startedCommand?.cwd, project)
        XCTAssertTrue(surface.startedCommand?.argv.contains("pruned-claude") == true)

        // The spawn is a real launch in an existing folder: it records it.
        let resumed = try XCTUnwrap(db.sessionState("pruned-claude"))
        XCTAssertEqual(resumed.directory, project)
        XCTAssertEqual(resumed.directorySource, .tab)
        XCTAssertNotNil(resumed.lastOpenedAt, "opened at spawn")

        // The inert chip was copied, not written.
        let inert = try XCTUnwrap(tabs.last)
        let untouched = try XCTUnwrap(db.sessionState("legacy-codex"))
        XCTAssertNil(untouched.lastOpenedAt, "copying a row into a chip writes nothing")
        XCTAssertNil(untouched.directory)
        XCTAssertNil(inert.surface)
        XCTAssertEqual(app.tabDisplayTitle(inert), "Port the tests", "not the row's placeholder")
        XCTAssertEqual(app.tabDisplayTitle(active), "Fix the parser")

        // And it opens when clicked, from its own persisted facts.
        app.openSessions.activate(inert)
        let codex = try XCTUnwrap(factory.created.last)
        XCTAssertEqual(factory.created.count, 2)
        XCTAssertEqual(codex.startedCommand?.cwd, project)
        XCTAssertEqual(codex.startedCommand?.argv.first.map { URL(fileURLWithPath: $0).lastPathComponent }, "codex")
        XCTAssertEqual(try db.sessionState("legacy-codex")?.directory, project)
    }

    /// A restored active tab whose row and saved tab both lack a folder says
    /// so, and opens by itself once the row learns one — unless the user has
    /// moved on.
    func testAnUnplaceableActiveTabShowsWhyAndOpensOnceTheRowKnows() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "unplaced", via: .opened, agent: .codex)
        try db.join(sessionID: "other", via: .opened, agent: .claude,
                    core: SessionCore(directory: directory.path, title: "Other"))
        let persistence = DBTabPersistence(db: db)
        persistence.save([PersistedTab(sessionID: "unplaced", agent: .codex, projectPath: "", title: "T", isActive: true),
                          PersistedTab(sessionID: "other", agent: .claude, projectPath: directory.path, title: "Other")])
        let factory = FakeTerminalSurfaceFactory()
        let app = AppModel(surfaceFactory: factory,
                           indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                           database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           stateDirectory: directory)
        app.start()
        let tab = try XCTUnwrap(app.openSessions.activeTab)
        XCTAssertEqual(tab.sessionID, "unplaced")
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertEqual(tab.launchPreparationError, OpenSessionsModel.unknownDirectoryMessage)
        XCTAssertEqual(tab.activity, .exited(status: -1), "the failure header shows instead of nothing")

        try db.fillCoreFields(sessionID: "unplaced", directory: directory.path)
        XCTAssertEqual(factory.created.count, 1, "opens once the row knows where")
        XCTAssertEqual(factory.created.first?.startedCommand?.cwd, directory.path)
        XCTAssertNil(tab.launchPreparationError)

        // Second case: the user navigated away first.
        let db2 = try TempleDB.inMemory()
        try db2.join(sessionID: "unplaced", via: .opened, agent: .codex)
        try db2.join(sessionID: "other", via: .opened, agent: .claude,
                     core: SessionCore(directory: directory.path, title: "Other"))
        DBTabPersistence(db: db2).save([
            PersistedTab(sessionID: "unplaced", agent: .codex, projectPath: "", title: "T", isActive: true),
            PersistedTab(sessionID: "other", agent: .claude, projectPath: directory.path, title: "Other")])
        let factory2 = FakeTerminalSurfaceFactory()
        let app2 = AppModel(surfaceFactory: factory2,
                            indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                            database: db2, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                            stateDirectory: directory)
        app2.start()
        app2.openSessions.activate(try XCTUnwrap(app2.openSessions.tabs.last))
        XCTAssertEqual(factory2.created.count, 1)
        try db2.fillCoreFields(sessionID: "unplaced", directory: directory.path)
        XCTAssertEqual(factory2.created.count, 1, "no surprise spawn after the user moved on")
        XCTAssertEqual(app2.openSessions.activeTab?.sessionID, "other")
    }
}
