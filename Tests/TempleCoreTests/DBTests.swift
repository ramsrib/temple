import XCTest
@testable import TempleCore
import GRDB

final class DBTests: XCTestCase {
    private var paths: [URL] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        paths.removeAll()
        super.tearDown()
    }

    private func database() throws -> (TempleDB, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-db-\(UUID().uuidString)", isDirectory: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)
        return (try TempleDB(path: path), path)
    }

    func testSessionStateRoundTrip() throws {
        let (db, _) = try database()
        try db.setPinned(true, sessionID: "s")
        try db.setArchived(true, sessionID: "s")
        try db.setCustomName("My session", sessionID: "s")
        try db.recordOpened(sessionID: "s", at: Date(timeIntervalSince1970: 123))
        let state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertTrue(state.pinned)
        XCTAssertTrue(state.archived)
        XCTAssertEqual(state.customName, "My session")
        try db.setPinned(false, sessionID: "s")
        XCTAssertFalse(try XCTUnwrap(db.sessionState("s")).pinned)
    }

    func testSessionColorRoundTripClearAndAutoCreate() throws {
        let (db, _) = try database()

        try db.setColor("blue", sessionID: "unseen")
        XCTAssertEqual(try db.sessionState("unseen")?.color, "blue")

        try db.setColor(nil, sessionID: "unseen")
        XCTAssertNil(try db.sessionState("unseen")?.color)
    }

    func testSessionColorMigrationIsIdempotentAcrossReopen() throws {
        let (db, path) = try database()
        try db.setCustomName("Existing state", sessionID: "s")
        XCTAssertNil(try db.sessionState("s")?.color)

        let reopened = try TempleDB(path: path)
        XCTAssertNil(try reopened.sessionState("s")?.color)
    }

    /// The agent's self-assigned title lives nowhere on disk — losing it on close
    /// would send a long session's row back to the prompt it opened with.
    func testGeneratedTitleSurvivesReopen() throws {
        let (db, path) = try database()
        try db.setGeneratedTitle("Fixing the shift+enter encoding", sessionID: "s")
        XCTAssertEqual(try db.sessionState("s")?.generatedTitle, "Fixing the shift+enter encoding")

        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.sessionState("s")?.generatedTitle, "Fixing the shift+enter encoding")
        // A rename is independent of it (the rename wins at display time).
        try reopened.setCustomName("Keyboard work", sessionID: "s")
        let state = try XCTUnwrap(reopened.sessionState("s"))
        XCTAssertEqual(state.customName, "Keyboard work")
        XCTAssertEqual(state.generatedTitle, "Fixing the shift+enter encoding")
    }

    func testUIStateRoundTripsAndSurvivesReopen() throws {
        let (db, path) = try database()
        try db.setUIState("detailOnly", for: "sidebarVisibility")
        XCTAssertEqual(try db.uiState("sidebarVisibility"), "detailOnly")
        XCTAssertEqual(try db.uiState(), ["sidebarVisibility": "detailOnly"])

        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.uiState("sidebarVisibility"), "detailOnly")
    }

    /// Clearing must DELETE the key, not store a stand-in: absence is how a
    /// value goes back to deferring to the shipped default.
    func testUIStateClearRemovesTheKey() throws {
        let (db, _) = try database()
        try db.setUIState("detailOnly", for: "sidebarVisibility")
        try db.setUIState(nil, for: "sidebarVisibility")
        XCTAssertNil(try db.uiState("sidebarVisibility"))
        XCTAssertTrue(try db.uiState().isEmpty)
    }

    /// The v6 table has to appear on a database written before it existed —
    /// every real user's file is one of those.
    ///
    /// The pre-v6 schema is rebuilt here by hand rather than by opening a
    /// `TempleDB`: the production initializer runs the CURRENT migrator, so a
    /// database made that way already has `ui_state` and reopening it migrates
    /// nothing. This is the same trick as pinning a decoder with a fixture of
    /// the OLD JSON — the test has to start from data that predates the change
    /// or it proves nothing about it.
    func testUIStateTableIsAddedToAPreV6Database() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)

        try Self.writePreV6Database(at: path)
        // Sanity: the fixture really is missing the table, so the assertions
        // below are about the migration rather than about a table already there.
        let legacy = try DatabaseQueue(path: path.path)
        let hadTable = try legacy.read { try $0.tableExists("ui_state") }
        XCTAssertFalse(hadTable)
        try legacy.close()

        let migrated = try TempleDB(path: path)
        try migrated.setUIState("detailOnly", for: "sidebarVisibility")
        XCTAssertEqual(try migrated.uiState("sidebarVisibility"), "detailOnly")
        // v1–v5 data has to come through untouched.
        XCTAssertEqual(try migrated.sessionState("s")?.customName, "Existing state")
        XCTAssertTrue(try XCTUnwrap(migrated.sessionState("s")).pinned)
        XCTAssertEqual(try migrated.openTabRecords().map(\.sessionID), ["s"])
    }

    /// A database at v5: the v1–v5 schema, GRDB's own migration bookkeeping for
    /// those five, and a row in each table so the migration has something to
    /// preserve.
    private static func writePreV6Database(at path: URL) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { database in
            try database.create(table: "session_state") { table in
                table.column("id", .text).primaryKey()
                table.column("pinned", .boolean).notNull().defaults(to: false)
                table.column("archived", .boolean).notNull().defaults(to: false)
                table.column("custom_name", .text)
                table.column("last_opened_at", .datetime)
            }
            try database.create(table: "open_tabs") { table in
                table.column("project_path", .text).notNull()
                table.column("session_id", .text).notNull()
                table.column("position", .integer).notNull()
                table.primaryKey(["project_path", "position"])
                table.uniqueKey(["project_path", "session_id"])
            }
            try database.create(table: "process_registry") { table in
                table.column("pid", .integer).primaryKey()
                table.column("session_id", .text).notNull()
                table.column("started_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-open-tab-metadata") { database in
            try database.alter(table: "open_tabs") { table in
                table.add(column: "agent", .text).notNull().defaults(to: "claude")
                table.add(column: "title", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v3-generated-title") { database in
            try database.alter(table: "session_state") { table in
                table.add(column: "generated_title", .text)
            }
        }
        migrator.registerMigration("v4-session-color") { database in
            try database.alter(table: "session_state") { table in
                table.add(column: "color", .text)
            }
        }
        migrator.registerMigration("v5-open-tab-active") { database in
            try database.alter(table: "open_tabs") { table in
                table.add(column: "active", .boolean).notNull().defaults(to: false)
            }
        }

        let queue = try DatabaseQueue(path: path.path)
        try migrator.migrate(queue)
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO session_state (id, pinned, custom_name) VALUES ('s', 1, 'Existing state')")
            try database.execute(
                sql: """
                    INSERT INTO open_tabs (project_path, session_id, position, agent, title, active)
                    VALUES ('/p', 's', 0, 'claude', 'Existing tab', 1)
                    """)
        }
        try queue.close()
    }

    func testOpenTabsPreserveOrder() throws {
        let (db, _) = try database()
        try db.setOpenTabs(projectPath: "/project", sessionIDs: ["a", "b", "c"])
        XCTAssertEqual(try db.openTabs(projectPath: "/project"), ["a", "b", "c"])
    }

    func testOpenTabRecordsPreserveAgentTitleAndPerProjectOrder() throws {
        let (db, _) = try database()
        try db.replaceOpenTabs([
            OpenTabRecord(projectPath: "/a", sessionID: "a1", position: 0,
                          agent: "claude", title: "First"),
            OpenTabRecord(projectPath: "/a", sessionID: "a2", position: 1,
                          agent: "codex", title: "Second"),
            OpenTabRecord(projectPath: "/b", sessionID: "b1", position: 0,
                          agent: "codex", title: "Other"),
        ])
        let records = try db.openTabRecords()
        XCTAssertEqual(records.map(\.sessionID), ["a1", "a2", "b1"])
        XCTAssertEqual(records.map(\.agent), ["claude", "codex", "codex"])
        XCTAssertEqual(records.map(\.title), ["First", "Second", "Other"])
    }

    func testProcessRegistrationAndRemoval() throws {
        let (db, _) = try database()
        try db.registerProcess(pid: 42, sessionID: "s", startedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(try db.liveProcesses().map(\.pid), [42])
        try db.unregisterProcess(pid: 42)
        XCTAssertTrue(try db.liveProcesses().isEmpty)
    }

    func testProcessRemovalBySessionID() throws {
        let (db, _) = try database()
        try db.registerProcess(pid: 42, sessionID: "remove")
        try db.registerProcess(pid: 43, sessionID: "keep")
        try db.unregisterProcess(sessionID: "remove")
        XCTAssertEqual(try db.liveProcesses().map(\.sessionID), ["keep"])
    }

    func testAllSessionStatesSupportOverlayCacheLoad() throws {
        let (db, _) = try database()
        try db.setPinned(true, sessionID: "pinned")
        try db.setCustomName("Renamed", sessionID: "named")
        let states = try db.sessionStates()
        XCTAssertEqual(Set(states.map(\.id)), ["pinned", "named"])
    }

    func testReopeningDatabasePreservesState() throws {
        let (db, path) = try database()
        try db.setCustomName("persisted", sessionID: "s")
        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.sessionState("s")?.customName, "persisted")
    }

    func testDefaultPathShape() {
        XCTAssertTrue(TempleDB.defaultPath().path.hasSuffix("Library/Application Support/Temple/temple.sqlite"))
    }
}
