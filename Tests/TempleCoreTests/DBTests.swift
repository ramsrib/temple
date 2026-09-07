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
        // Archive first: archiving clears the pin (see the test below).
        try db.setArchived(true, sessionID: "s")
        try db.setPinned(true, sessionID: "s")
        try db.setCustomName("My session", sessionID: "s")
        try db.recordOpened(sessionID: "s", at: Date(timeIntervalSince1970: 123))
        let state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertTrue(state.pinned)
        XCTAssertTrue(state.archived)
        XCTAssertEqual(state.customName, "My session")
        try db.setPinned(false, sessionID: "s")
        XCTAssertFalse(try XCTUnwrap(db.sessionState("s")).pinned)
    }

    /// One statement, not two: a pin dropped by a separate write could survive
    /// a failure of the archive write (or vice versa) and come back as a
    /// session that is both pinned and put away.
    func testArchivingClearsThePinInTheSameWriteAndUnarchivingLeavesIt() throws {
        let (db, _) = try database()
        try db.setPinned(true, sessionID: "s")

        try db.setArchived(true, sessionID: "s")
        var state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertTrue(state.archived)
        XCTAssertFalse(state.pinned)

        try db.setPinned(true, sessionID: "s")
        try db.setArchived(false, sessionID: "s")
        state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertFalse(state.archived)
        XCTAssertTrue(state.pinned, "unarchiving must not touch the pin column")
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

    /// The v6 and v7 tables have to appear on a database written before they
    /// existed — every real user's file is one of those.
    ///
    /// The older schemas are rebuilt here by hand rather than by opening a
    /// `TempleDB`: the production initializer runs the CURRENT migrator, so a
    /// database made that way already has every table and reopening it migrates
    /// nothing. This is the same trick as pinning a decoder with a fixture of
    /// the OLD JSON — the test has to start from data that predates the change
    /// or it proves nothing about it.
    func testNewTablesAreAddedFromEveryEarlierSchemaVersion() throws {
        // Not just the newest-but-one: a user who skipped a few releases
        // upgrades from whichever version they stopped at.
        for (index, start) in Self.legacyVersions.enumerated() {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("temple-db-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("temple.sqlite")
            paths.append(path)

            try Self.writeLegacyDatabase(at: path, upTo: start)
            // Sanity: the fixture really is missing the table, so the assertions
            // below are about the migration rather than a table already there.
            let legacy = try DatabaseQueue(path: path.path)
            let hadTable = try legacy.read { try $0.tableExists("project_state") }
            XCTAssertFalse(hadTable, "fixture at \(start) already had project_state")
            try legacy.close()

            let migrated = try TempleDB(path: path)
            if index >= 5 {
                XCTAssertEqual(try migrated.uiState("sidebarVisibility"), "all", "from \(start)")
            }
            try migrated.setUIState("detailOnly", for: "sidebarVisibility")
            XCTAssertEqual(try migrated.uiState("sidebarVisibility"), "detailOnly", "from \(start)")

            try migrated.setProjectArchived(true, path: "/p")
            try migrated.setProjectOrder(["/p"])
            let projectState = try XCTUnwrap(migrated.projectStates().first, "from \(start)")
            XCTAssertEqual(projectState.path, "/p", "from \(start)")
            XCTAssertTrue(projectState.archived, "from \(start)")
            XCTAssertEqual(projectState.position, 0, "from \(start)")

            // Everything the old schema could hold has to come through
            // untouched — every column that existed at THIS starting version,
            // each seeded with a non-default value. A fixture of defaults would
            // let a migration that drops populated rows pass.
            let state = try XCTUnwrap(migrated.sessionState("s"), "from \(start)")
            XCTAssertEqual(state.customName, "Existing state", "from \(start)")
            XCTAssertEqual(state.lastOpenedAt, Self.seededDate, "from \(start)")
            XCTAssertTrue(state.pinned, "from \(start)")
            XCTAssertTrue(state.archived, "from \(start)")
            if index >= 2 { XCTAssertEqual(state.generatedTitle, "Agent title", "from \(start)") }
            if index >= 3 { XCTAssertEqual(state.color, "blue", "from \(start)") }

            let tab = try XCTUnwrap(migrated.openTabRecords().first, "from \(start)")
            XCTAssertEqual(tab.sessionID, "s", "from \(start)")
            XCTAssertEqual(tab.projectPath, "/p", "from \(start)")
            XCTAssertEqual(tab.position, 3, "from \(start)")
            if index >= 1 {
                XCTAssertEqual(tab.agent, "codex", "from \(start)")
                XCTAssertEqual(tab.title, "Existing tab", "from \(start)")
            }
            if index >= 4 { XCTAssertTrue(tab.isActive, "from \(start)") }

            let process = try XCTUnwrap(migrated.liveProcesses().first, "from \(start)")
            XCTAssertEqual(process.pid, 4242, "from \(start)")
            XCTAssertEqual(process.sessionID, "s", "from \(start)")
            XCTAssertEqual(process.startedAt, Self.seededDate, "from \(start)")
        }
    }

    /// 2024-01-02 03:04:05 UTC, in both the form GRDB stores and the form it
    /// hands back, so the datetime columns are pinned to a real value rather
    /// than left null where a dropped write would look identical.
    private static let seededDate = Date(timeIntervalSince1970: 1_704_164_645)
    private static let seededDateLiteral = "2024-01-02 03:04:05.000"

    /// Every migration identifier that predates the newest one, oldest first.
    private static let legacyVersions = [
        "v1", "v2-open-tab-metadata", "v3-generated-title",
        "v4-session-color", "v5-open-tab-active", "v6-ui-state",
    ]

    /// A database stopped at `target`: the v1–v6 migrations registered as
    /// production spells them, applied only up to that identifier, with GRDB's own
    /// bookkeeping and a row in each table so the migration has something to
    /// preserve.
    private static func writeLegacyDatabase(at path: URL, upTo target: String) throws {
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
        migrator.registerMigration("v6-ui-state") { database in
            try database.create(table: "ui_state") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }

        let queue = try DatabaseQueue(path: path.path)
        try migrator.migrate(queue, upTo: target)
        // Seed every column that exists at this starting version, each with a
        // value distinguishable from its default — otherwise a v6 that dropped
        // populated rows would slip past a fixture full of zeroes and "".
        let reached = legacyVersions.prefix(through: legacyVersions.firstIndex(of: target)!)
        var sessionColumns = ["id": "'s'", "pinned": "1", "archived": "1",
                              "custom_name": "'Existing state'",
                              "last_opened_at": "'\(seededDateLiteral)'"]
        if reached.contains("v3-generated-title") { sessionColumns["generated_title"] = "'Agent title'" }
        if reached.contains("v4-session-color") { sessionColumns["color"] = "'blue'" }

        var tabColumns = ["project_path": "'/p'", "session_id": "'s'", "position": "3"]
        if reached.contains("v2-open-tab-metadata") {
            tabColumns["agent"] = "'codex'"
            tabColumns["title"] = "'Existing tab'"
        }
        if reached.contains("v5-open-tab-active") { tabColumns["active"] = "1" }

        // process_registry has existed since v1 and nothing since has touched
        // it, which is exactly why it is easy to forget in a fixture.
        let processColumns = ["pid": "4242", "session_id": "'s'",
                              "started_at": "'\(seededDateLiteral)'"]

        var tables = [("session_state", sessionColumns),
                      ("open_tabs", tabColumns),
                      ("process_registry", processColumns)]
        if reached.contains("v6-ui-state") {
            tables.append(("ui_state", ["key": "'sidebarVisibility'", "value": "'all'"]))
        }

        try queue.write { database in
            for (table, columns) in tables {
                let names = columns.keys.sorted()
                try database.execute(sql: """
                    INSERT INTO \(table) (\(names.joined(separator: ", ")))
                    VALUES (\(names.map { columns[$0]! }.joined(separator: ", ")))
                    """)
            }
        }
        try queue.close()
    }

    func testProjectStateRoundTripsArchivedAndOrder() throws {
        let (db, path) = try database()
        try db.setProjectArchived(true, path: "/p/a")
        try db.setProjectOrder(["/p/b", "/p/a", "/p/c"])

        let reopened = try TempleDB(path: path)
        let states = try reopened.projectStates()
        XCTAssertEqual(states.first { $0.path == "/p/a" }?.archived, true)
        XCTAssertEqual(states.first { $0.path == "/p/b" }?.archived, false)
        XCTAssertEqual(
            states.compactMap { state in state.position.map { ($0, state.path) } }
                .sorted { $0.0 < $1.0 }.map(\.1),
            ["/p/b", "/p/a", "/p/c"])
    }

    /// A path dropped from the order goes back to UNPLACED, not to the end:
    /// keeping a stale position would leave two projects claiming one slot the
    /// next time anything is written.
    func testSetProjectOrderClearsPositionsOfPathsNoLongerListed() throws {
        let (db, _) = try database()
        try db.setProjectArchived(true, path: "/p/a")
        try db.setProjectOrder(["/p/a", "/p/b"])
        try db.setProjectOrder(["/p/b"])

        let states = try db.projectStates()
        let a = try XCTUnwrap(states.first { $0.path == "/p/a" })
        XCTAssertNil(a.position)
        // Order is a separate axis from archived — clearing one must not
        // disturb the other.
        XCTAssertTrue(a.archived)
        XCTAssertEqual(states.first { $0.path == "/p/b" }?.position, 0)
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
