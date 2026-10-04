import XCTest
import Darwin
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

    /// Undo of an import deletes a row only while it says nothing but how the
    /// session joined; any later decision about the session keeps it.
    func testLeaveDeletesOnlyAnUntouchedImportedRow() throws {
        let (db, _) = try database()
        try db.join(sessionID: "fresh", via: .imported, agent: .claude,
                    transcriptPath: URL(fileURLWithPath: "/tmp/fresh.jsonl"))
        XCTAssertTrue(try db.leave(sessionID: "fresh"))
        XCTAssertNil(try db.sessionState("fresh"))
        XCTAssertFalse(try db.leave(sessionID: "fresh"), "nothing left to remove")

        let touches: [(String, (TempleDB, String) throws -> Void)] = [
            ("pinned", { try $0.setPinned(true, sessionID: $1) }),
            ("archived", { try $0.setArchived(true, sessionID: $1) }),
            ("named", { try $0.setCustomName("Mine", sessionID: $1) }),
            ("colored", { try $0.setColor("red", sessionID: $1) }),
            ("retitled", { try $0.setGeneratedTitle("Agent title", sessionID: $1) }),
            ("opened", { try $0.recordOpened(sessionID: $1) }),
            ("in a tab", { try $0.setOpenTabs(projectPath: "/p", sessionIDs: [$1]) }),
        ]
        for (name, touch) in touches {
            let id = "touched-\(name)"
            try db.join(sessionID: id, via: .imported)
            try touch(db, id)
            XCTAssertFalse(try db.leave(sessionID: id), name)
            XCTAssertNotNil(try db.sessionState(id), "\(name): the row must stay")
        }

        // Only an import is undone: a session Temple started or resumed keeps its row.
        try db.join(sessionID: "opened", via: .opened)
        XCTAssertFalse(try db.leave(sessionID: "opened"))
        XCTAssertNotNil(try db.sessionState("opened"))
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
            // Sanity: the fixture really is missing what later migrations add,
            // so the assertions below are about the migration rather than a
            // table or column already there.
            let legacy = try DatabaseQueue(path: path.path)
            let hadTable = try legacy.read { try $0.tableExists("project_state") }
            if index < 6 { XCTAssertFalse(hadTable, "fixture at \(start) already had project_state") }
            let hadJoinedVia = try legacy.read { database in
                try database.columns(in: "session_state").contains { $0.name == "joined_via" }
            }
            if index < 7 { XCTAssertFalse(hadJoinedVia, "fixture at \(start) already had session_state.joined_via") }
            try legacy.close()

            let migrated = try TempleDB(path: path)
            if index >= 5 {
                XCTAssertEqual(try migrated.uiState("sidebarVisibility"), "all", "from \(start)")
            }
            try migrated.setUIState("detailOnly", for: "sidebarVisibility")
            XCTAssertEqual(try migrated.uiState("sidebarVisibility"), "detailOnly", "from \(start)")

            if index >= 6 {
                let seeded = try XCTUnwrap(migrated.projectStates().first, "from \(start)")
                XCTAssertEqual(seeded.path, "/p", "from \(start)")
                XCTAssertEqual(seeded.position, 7, "from \(start)")
            }
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
            XCTAssertEqual(state.title, index >= 2 ? "Agent title" : nil, "from \(start)")
            XCTAssertEqual(state.host, .local, "from \(start)")
            XCTAssertNil(state.directory, "from \(start)")
            XCTAssertNil(state.directorySource, "from \(start)")
            XCTAssertNil(state.lastActiveAt, "from \(start)")
            // Unknown, not guessed: nothing older says who started a session.
            XCTAssertEqual(state.joinedVia, index >= 7 ? .imported : nil, "from \(start)")
            XCTAssertEqual(state.joinedAt, index >= 7 ? Self.seededDate : nil, "from \(start)")
            XCTAssertEqual(state.agent, index >= 8 ? .codex : nil, "from \(start)")
            XCTAssertEqual(state.transcriptPath, index >= 8 ? "/transcript.jsonl" : nil, "from \(start)")
            // ...and a later join does not rewrite that history.
            try migrated.join(sessionID: "s", via: .opened)
            XCTAssertEqual(try migrated.sessionState("s")?.joinedVia, index >= 7 ? .imported : nil, "from \(start)")

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
        "v7-project-state", "v8-session-join", "v9-session-transcript",
    ]

    /// A database stopped at `target`: the v1–v9 migrations registered as
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

        migrator.registerMigration("v7-project-state") { database in
            try database.create(table: "project_state") { table in
                table.column("path", .text).primaryKey()
                table.column("archived", .boolean).notNull().defaults(to: false)
                table.column("position", .integer)
            }
        }

        migrator.registerMigration("v8-session-join") { database in
            try database.alter(table: "session_state") { table in
                table.add(column: "joined_via", .text)
                table.add(column: "joined_at", .datetime)
            }
        }
        migrator.registerMigration("v9-session-transcript") { database in
            try database.alter(table: "session_state") { table in
                table.add(column: "agent", .text)
                table.add(column: "transcript_path", .text)
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

        if reached.contains("v8-session-join") {
            sessionColumns["joined_via"] = "'imported'"
            sessionColumns["joined_at"] = "'\(seededDateLiteral)'"
        }
        if reached.contains("v9-session-transcript") {
            sessionColumns["agent"] = "'codex'"
            sessionColumns["transcript_path"] = "'/transcript.jsonl'"
        }

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
        if reached.contains("v7-project-state") {
            tables.append(("project_state", ["path": "'/p'", "archived": "0", "position": "7"]))
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

    /// The first join is the one recorded: how, and when.
    func testJoinRecordsTheFirstJoinOnlyAndSurvivesReopen() throws {
        let (db, path) = try database()
        try db.join(sessionID: "s", via: .created, at: Self.seededDate)
        try db.join(sessionID: "s", via: .opened, at: Self.seededDate.addingTimeInterval(60))
        try db.setCustomName("Named", sessionID: "s")

        let reopened = try TempleDB(path: path)
        let state = try XCTUnwrap(reopened.sessionState("s"))
        XCTAssertEqual(state.joinedVia, .created)
        XCTAssertEqual(state.joinedAt, Self.seededDate)
        XCTAssertEqual(state.customName, "Named")
    }

    /// A row written by a setter alone says nothing about how it joined, and a
    /// later join does not fill that in.
    func testJoinLeavesARowWrittenWithoutOneAlone() throws {
        let (db, _) = try database()
        try db.setPinned(true, sessionID: "s")
        try db.join(sessionID: "s", via: .imported)
        XCTAssertNil(try db.sessionState("s")?.joinedVia)
        XCTAssertEqual(try db.sessionState("s")?.pinned, true)
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
        // Checking the shipped spelling must not create the real state directory.
        XCTAssertTrue(TempleState.defaultDirectory.appendingPathComponent("temple.sqlite").path
            .hasSuffix("Library/Application Support/Temple/temple.sqlite"))
        let key = "TEMPLE_STATE_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("temple-default-path-\(UUID().uuidString)")
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
        }
        setenv(key, root.path, 1)
        XCTAssertEqual(TempleDB.defaultPath(), root.appendingPathComponent("temple.sqlite"))
    }
}

extension DBTests {
    func testReadOnlyV9RowsRemainReadableWithoutMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-read-v9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)
        try Self.writeLegacyDatabase(at: path, upTo: "v9-session-transcript")
        let before = try Data(contentsOf: path)
        let reader = try TempleDB(readOnlyPath: path)
        XCTAssertEqual(try reader.sessionState("s")?.host, .local)
        XCTAssertEqual(try reader.sessionStates().map(\.id), ["s"])
        XCTAssertEqual(try reader.sessionStates(host: .local).map(\.id), ["s"])
        XCTAssertTrue(try reader.sessionStates(host: HostID(rawValue: "remote")).isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testOldWriterSQLStillRunsOnV10() throws {
        let (_, path) = try database()
        let old = try DatabaseQueue(path: path.path)
        defer { try? old.close() }
        // Literal statements from v9, including the ensureState used by its
        // setter. No production API calls here: those would test the new writer.
        try old.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO session_state (id) VALUES (?)", arguments: ["old-title"])
            try db.execute(sql: "UPDATE session_state SET generated_title = ? WHERE id = ?", arguments: ["Old writer title", "old-title"])
            try db.execute(sql: "INSERT INTO session_state (id, joined_via, joined_at) VALUES (?, ?, ?) ON CONFLICT(id) DO NOTHING",
                           arguments: ["old-import", "imported", Self.seededDate])
            try db.execute(sql: "UPDATE session_state SET agent = COALESCE(?, agent), transcript_path = COALESCE(?, transcript_path) WHERE id = ?",
                           arguments: ["codex", "/old/path", "old-import"])
            try db.execute(sql: """
                DELETE FROM session_state
                WHERE id = ? AND joined_via = ?
                  AND pinned = 0 AND archived = 0
                  AND custom_name IS NULL AND color IS NULL
                  AND generated_title IS NULL AND last_opened_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM open_tabs WHERE session_id = ?)
                """, arguments: ["old-import", "imported", "old-import"])
            XCTAssertEqual(db.changesCount, 1)
        }
        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.sessionState("old-title")?.title, "Old writer title")
        XCTAssertEqual(try reopened.sessionState("old-title")?.generatedTitle, "Old writer title")
        XCTAssertNil(try reopened.sessionState("old-import"))
        try old.write { db in
            try db.execute(sql: "INSERT INTO session_state (id, joined_via, joined_at) VALUES (?, ?, ?) ON CONFLICT(id) DO NOTHING",
                           arguments: ["old-join", "opened", Self.seededDate])
        }
        XCTAssertEqual(try reopened.sessionState("old-join")?.host, .local)
    }

    func testTwoConnectionsOldThenNewReconcileTitle() throws {
        let (new, path) = try database()
        try new.setTitle("Initial", sessionID: "s")
        let old = try DatabaseQueue(path: path.path)
        defer { try? old.close() }
        try old.write { db in
            try db.execute(sql: "UPDATE session_state SET generated_title = ? WHERE id = ?", arguments: ["Old process retitle", "s"])
        }
        // A7: no live reconcile on reads of an already-open connection.
        XCTAssertEqual(try new.sessionState("s")?.title, "Initial")
        let reopened = try TempleDB(path: path)
        XCTAssertEqual(try reopened.sessionState("s")?.title, "Old process retitle")
        XCTAssertEqual(try TempleDB(path: path).sessionState("s")?.title, "Old process retitle")
        try reopened.join(sessionID: "prompt", via: .imported)
        try reopened.fillCoreFields(sessionID: "prompt", title: "First prompt")
        XCTAssertEqual(try TempleDB(path: path).sessionState("prompt")?.title, "First prompt")
        XCTAssertNil(try reopened.sessionState("prompt")?.generatedTitle)
    }

    func testASupersededDatabaseThrowsNewerSchemaAndIsNotWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-future-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)
        // Start before v10 to prove the guard precedes both migration and reconcile.
        try Self.writeLegacyDatabase(at: path, upTo: "v9-session-transcript")
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future-unknown')")
        }
        try queue.close()
        let before = try Data(contentsOf: path)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for open in [{ try TempleDB(path: path) }, { try TempleDB(readOnlyPath: path) }] {
            XCTAssertThrowsError(try open()) { XCTAssertEqual($0 as? TempleDBError, .newerSchema) }
            XCTAssertEqual(try Data(contentsOf: path), before)
            let expectedFiles = Set(filesBefore).union(["temple.sqlite.migrate-lock"])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), expectedFiles)
        }
    }

    /// A writer that crashed mid-transaction leaves a hot rollback journal.
    /// Only a connection with write access can roll it back; a read-only
    /// probe fails with SQLITE_READONLY_ROLLBACK, and when the open path ran
    /// one first, every later launch failed the same way — forever, because
    /// nothing else would ever roll the journal back.
    func testALeftoverHotJournalIsRolledBackAndTheDatabaseOpens() throws {
        let (seed, path) = try database()
        try seed.join(sessionID: "committed", via: .imported, core: SessionCore(title: "Kept"))
        let crashed = path.deletingLastPathComponent().appendingPathComponent("crashed.sqlite")
        let raw = try DatabaseQueue(path: path.path)
        try raw.inDatabase { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: "UPDATE session_state SET title = 'Uncommitted' WHERE id = 'committed'")
            try db.execute(sql: "INSERT INTO session_state (id) VALUES ('uncommitted')")
            // The files as a crash at this instant would leave them.
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path + "-journal"))
            try FileManager.default.copyItem(atPath: path.path, toPath: crashed.path)
            try FileManager.default.copyItem(atPath: path.path + "-journal", toPath: crashed.path + "-journal")
            try db.execute(sql: "ROLLBACK")
        }
        try raw.close()
        try Self.markJournalSynced(URL(fileURLWithPath: crashed.path + "-journal"))
        XCTAssertThrowsError(try TempleDB(readOnlyPath: crashed), "the hazard: read-only cannot roll back")

        let reopened = try TempleDB(path: crashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path + "-journal"))
        XCTAssertEqual(try reopened.sessionStates().map(\.id), ["committed"])
        XCTAssertEqual(try reopened.sessionState("committed")?.title, "Kept")
        try reopened.join(sessionID: "after", via: .imported)
        XCTAssertEqual(try TempleDB(path: crashed).sessionStates().map(\.id), ["after", "committed"])
    }

    /// SQLite writes a journal header with its magic zeroed and fills it in
    /// when it syncs the journal at commit — the moment from which a crash
    /// leaves a hot journal. Copying mid-transaction catches the earlier
    /// state, so finish the header the way that sync would.
    private static func markJournalSynced(_ journal: URL) throws {
        var bytes = try Data(contentsOf: journal)
        func field(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        let sector = field(20), page = field(24)
        let records = UInt32((bytes.count - sector) / (page + 8))
        XCTAssertGreaterThan(records, 0)
        bytes.replaceSubrange(0..<8, with: [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7])
        bytes.replaceSubrange(8..<12, with: withUnsafeBytes(of: records.bigEndian, Array.init))
        try bytes.write(to: journal)
    }

    /// An open that has nothing to migrate or reconcile takes no write lock,
    /// so another connection mid-write cannot fail this launch.
    func testAnUpToDateOpenSucceedsWhileAnotherConnectionHoldsAWriteLock() throws {
        let (seed, path) = try database()
        try seed.join(sessionID: "s", via: .imported)
        try seed.setTitle("Same", sessionID: "s")
        let raw = try DatabaseQueue(path: path.path)
        try raw.inDatabase { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            defer { try? db.execute(sql: "ROLLBACK") }
            let started = Date()
            XCTAssertEqual(try TempleDB(path: path).sessionState("s")?.title, "Same")
            XCTAssertLessThan(Date().timeIntervalSince(started), TempleDB.busyTimeout)
        }
        try raw.close()
    }

    func testTheMigrationLockWaitIsBounded() throws {
        let (_, path) = try database()
        let fd = Darwin.open(path.path + ".migrate-lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        var contended = 0
        XCTAssertThrowsError(try TempleDB(path: path, onMigrationLockContention: { contended += 1 }, lockTimeout: 0.1)) {
            XCTAssertEqual($0 as? TempleDBError, .migrationLockTimeout)
        }
        XCTAssertEqual(contended, 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertNoThrow(try TempleDB(path: path, onMigrationLockContention: nil, lockTimeout: 0.1))
    }

    func testCoreFillsNeverOverwriteAndLaunchDirectoryAlwaysWins() throws {
        let (db, _) = try database()
        try db.join(sessionID: "s", via: .imported)
        XCTAssertEqual(try db.fillCoreFields(sessionID: "s", agent: .claude, directory: "/transcript", title: "Prompt", lastActiveAt: Self.seededDate),
                       [.agent, .directory, .title, .lastActiveAt])
        XCTAssertEqual(try db.sessionState("s")?.directorySource, .transcript)
        XCTAssertTrue(try db.fillCoreFields(sessionID: "s", agent: .codex, directory: "/ignored", title: "Ignored", lastActiveAt: Date()).isEmpty)
        try db.observeLaunchDirectory(sessionID: "s", "/launch-A")
        try db.observeLaunchDirectory(sessionID: "s", "/launch-B")
        try db.fillCoreFields(sessionID: "s", directory: "/transcript-C")
        let state = try XCTUnwrap(db.sessionState("s"))
        XCTAssertEqual(state.directory, "/launch-B")
        XCTAssertEqual(state.directorySource, .tab)
        XCTAssertEqual(state.agent, .claude)
        XCTAssertEqual(state.title, "Prompt")
        XCTAssertEqual(state.lastActiveAt, Self.seededDate)
        XCTAssertNil(state.generatedTitle)
        XCTAssertTrue(try db.fillCoreFields(sessionID: "absent", title: "No row").isEmpty)
        try db.observeLaunchDirectory(sessionID: "absent", "/no-row")
        try db.touch(sessionID: "absent")
        XCTAssertNil(try db.sessionState("absent"))
    }

    func testJoinCoreIsNullOnlyAndHostQueriesAreScoped() throws {
        let (db, _) = try database()
        let remote = HostID(rawValue: "remote-alias")
        try db.join(sessionID: "remote", via: .imported, core: SessionCore(host: remote, directory: "/A", directorySource: .transcript, title: "A", lastActiveAt: Self.seededDate))
        try db.join(sessionID: "remote", via: .opened, core: SessionCore(directory: "/B", directorySource: .tab, title: "B", lastActiveAt: Date()))
        let state = try XCTUnwrap(db.sessionState("remote"))
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertEqual(state.host, remote)
        XCTAssertEqual(state.directory, "/A")
        XCTAssertEqual(state.directorySource, .transcript)
        XCTAssertEqual(state.title, "A")
        XCTAssertEqual(state.lastActiveAt, Self.seededDate)
        XCTAssertEqual(state.joinedVia, .imported)
        try db.join(sessionID: "local", via: .created)
        try db.join(sessionID: "local", via: .opened, core: SessionCore(directory: "/local", directorySource: .tab, title: "Local"))
        XCTAssertEqual(try db.sessionState("local")?.directory, "/local")
        XCTAssertEqual(try db.sessionStates(host: .local).map(\.id), ["local"])
        XCTAssertEqual(try db.sessionStates(host: remote).map(\.id), ["remote"])
        XCTAssertEqual(try db.sessionStates().count, 2)
    }

    func testTouchIsMonotonic() throws {
        let (db, path) = try database()
        try db.join(sessionID: "s", via: .created)
        // Dates remain GRDB datetime values, including the NULL case.
        let early = Date(timeIntervalSince1970: -100)
        let late = Self.seededDate
        try db.touch(sessionID: "s", at: early)
        XCTAssertEqual(try db.sessionState("s")?.lastActiveAt, early)
        try db.touch(sessionID: "s", at: late)
        try db.touch(sessionID: "s", at: early)
        try db.touch(sessionID: "s", at: late)
        XCTAssertEqual(try TempleDB(path: path).sessionState("s")?.lastActiveAt, late)
    }

    func testLeaveAllowsUndoOfATitledImportButNotARetitledOrOpenedOne() throws {
        let (db, _) = try database()
        try db.join(sessionID: "filled", via: .imported, core: SessionCore(directory: "/p", directorySource: .transcript, title: "Prompt"))
        try db.fillCoreFields(sessionID: "filled", lastActiveAt: Self.seededDate)
        XCTAssertTrue(try db.leave(sessionID: "filled"))
        try db.join(sessionID: "retitled", via: .imported)
        try db.setTitle("Agent title", sessionID: "retitled")
        XCTAssertFalse(try db.leave(sessionID: "retitled"))
        try db.join(sessionID: "opened", via: .imported)
        try db.recordOpened(sessionID: "opened")
        XCTAssertFalse(try db.leave(sessionID: "opened"))
    }

    func testSessionStateDecodesV9Fixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/session-state-v9.json")
        let state = try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: fixture))
        XCTAssertEqual(state.id, "legacy-v9")
        XCTAssertTrue(state.pinned)
        XCTAssertFalse(state.archived)
        XCTAssertEqual(state.customName, "Kept name")
        XCTAssertEqual(state.color, "blue")
        XCTAssertEqual(state.generatedTitle, "Agent title")
        XCTAssertEqual(state.lastOpenedAt, Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(state.joinedVia, .imported)
        XCTAssertEqual(state.joinedAt, Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(state.agent, .codex)
        XCTAssertEqual(state.transcriptPath, "/old/transcript.jsonl")
        XCTAssertEqual(state.host, .local)
        XCTAssertNil(state.directory)
        XCTAssertNil(state.directorySource)
        XCTAssertNil(state.title)
        XCTAssertNil(state.lastActiveAt)
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state)), state)
    }

    func testMigrationLockWaitsForConcurrentUnknownMigrationBeforeOpening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("temple-migration-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("temple.sqlite")
        paths.append(path)
        try Self.writeLegacyDatabase(at: path, upTo: "v9-session-transcript")
        let before = try Data(contentsOf: path)

        // A separate descriptor/connection plays the future migrator. BSD flock
        // ownership follows the open descriptor, so it also excludes this process's
        // second opener, exactly as it would an opener in another process.
        let fd = Darwin.open(path.path + ".migrate-lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let contended = DispatchSemaphore(value: 0)
        let completed = expectation(description: "waiting opener rejects newer schema")
        DispatchQueue.global().async {
            defer { completed.fulfill() }
            do {
                _ = try TempleDB(path: path, onMigrationLockContention: { contended.signal() })
                XCTFail("opener accepted an unknown migration")
            } catch {
                XCTAssertEqual(error as? TempleDBError, .newerSchema)
            }
        }
        // The signal comes from an actual EWOULDBLOCK, not a sleep or a guess
        // that the other thread has been scheduled far enough into the opener.
        guard contended.wait(timeout: .now() + 3) == .success else {
            XCTFail("opener did not contend on the migration lock")
            return
        }
        XCTAssertEqual(try Data(contentsOf: path), before, "no migration or reconcile before acquiring the lock")
        let future = try DatabaseQueue(path: path.path)
        try future.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future-unknown')")
        }
        try future.close()
        let afterFutureCommit = try Data(contentsOf: path)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: path), afterFutureCommit, "rejected opener must write nothing")
        // A failed open must release its lock as well.
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    }

    func testRowObserversReadOriginatingConnectionForEveryMutationAndIgnoreNoOps() throws {
        let (db, _) = try database()
        let recorder = RowChangeRecorder()
        let token = recorder.observe(db)
        defer { db.removeRowChangeObserver(token) }
        let transcript = URL(fileURLWithPath: "/transcript")
        let mutations: [(String, () throws -> Void)] = [
            ("join", { try db.join(sessionID: "s", via: .imported) }),
            ("join core", { try db.join(sessionID: "s", via: .imported, core: SessionCore(directory: "/core", directorySource: .transcript)) }),
            ("join hint", { try db.join(sessionID: "s", via: .imported, agent: .claude, transcriptPath: transcript) }),
            ("pin", { try db.setPinned(true, sessionID: "s") }),
            ("archive clears pin", { try db.setArchived(true, sessionID: "s") }),
            ("pin archived row", { try db.setPinned(true, sessionID: "s") }),
            ("same archive clears new pin", { try db.setArchived(true, sessionID: "s") }),
            ("unarchive", { try db.setArchived(false, sessionID: "s") }),
            ("custom name", { try db.setCustomName("Name", sessionID: "s") }),
            ("clear custom name", { try db.setCustomName(nil, sessionID: "s") }),
            ("color", { try db.setColor("blue", sessionID: "s") }),
            ("clear color", { try db.setColor(nil, sessionID: "s") }),
            ("opened", { try db.recordOpened(sessionID: "s", at: Self.seededDate) }),
            ("hint", { try db.updateTranscriptHint(sessionID: "s", agent: .codex, path: transcript) }),
            ("fill", { try db.fillCoreFields(sessionID: "s", title: "Prompt", lastActiveAt: Self.seededDate) }),
            ("title dual write", { try db.setTitle("Prompt", sessionID: "s") }),
            ("clear title", { try db.setTitle(nil, sessionID: "s") }),
            ("legacy title setter", { try db.setGeneratedTitle("Agent", sessionID: "s") }),
            ("launch directory", { try db.observeLaunchDirectory(sessionID: "s", "/launch") }),
            ("touch", { try db.touch(sessionID: "s", at: Self.seededDate.addingTimeInterval(1)) }),
        ]
        for (name, mutate) in mutations {
            let count = recorder.events.count
            try mutate()
            XCTAssertEqual(recorder.events.count, count + 1, name)
            XCTAssertEqual(recorder.events.last?.id, "s", name)
            XCTAssertEqual(recorder.events.last?.state, try db.sessionState("s"), name)
            try mutate()
            XCTAssertEqual(recorder.events.count, count + 1, "no-op \(name)")
        }
        var count = recorder.events.count
        try db.touch(sessionID: "s", at: Self.seededDate) // older timestamp
        XCTAssertFalse(try db.leave(sessionID: "s")) // opened/retitled row
        try db.updateTranscriptHint(sessionID: "absent", agent: .claude, path: transcript)
        try db.observeLaunchDirectory(sessionID: "absent", "/launch")
        try db.touch(sessionID: "absent")
        try db.fillCoreFields(sessionID: "absent", title: "Unknown")
        XCTAssertEqual(recorder.events.count, count)

        try db.join(sessionID: "removable", via: .imported)
        count += 1
        XCTAssertEqual(recorder.events.count, count)
        XCTAssertTrue(try db.leave(sessionID: "removable"))
        XCTAssertEqual(recorder.events.count, count + 1)
        XCTAssertEqual(recorder.events.last?.id, "removable")
        XCTAssertNil(recorder.events.last?.state)
        XCTAssertFalse(try db.leave(sessionID: "removable"))
        XCTAssertEqual(recorder.events.count, count + 1)

        db.removeRowChangeObserver(token)
        try db.setTitle("After removal", sessionID: "s")
        XCTAssertEqual(recorder.events.count, count + 1)
    }

    func testCreatingRowsThroughSettersNotifiesOnceWithTheFinalState() throws {
        let db = try TempleDB.inMemory()
        let recorder = RowChangeRecorder()
        let token = recorder.observe(db)
        defer { db.removeRowChangeObserver(token) }
        let setters: [(String, () throws -> Void)] = [
            ("pin", { try db.setPinned(true, sessionID: "pin") }),
            ("archive", { try db.setArchived(true, sessionID: "archive") }),
            ("name", { try db.setCustomName("Name", sessionID: "name") }),
            ("color", { try db.setColor("blue", sessionID: "color") }),
            ("opened", { try db.recordOpened(sessionID: "opened", at: Self.seededDate) }),
            ("title", { try db.setTitle("Title", sessionID: "title") }),
            // Inserting a row with default values is still a membership change.
            ("default", { try db.setPinned(false, sessionID: "default") }),
        ]
        for (id, set) in setters {
            let count = recorder.events.count
            try set()
            XCTAssertEqual(recorder.events.count, count + 1, id)
            XCTAssertEqual(recorder.events.last?.state, try db.sessionState(id), id)
            try set()
            XCTAssertEqual(recorder.events.count, count + 1, "no-op \(id)")
        }
    }

    func testFailedSessionRowMutationsNeverNotify() throws {
        let queue = try DatabaseQueue()
        let db = try TempleDB(database: queue)
        try db.join(sessionID: "s", via: .imported)
        let before = try db.sessionStates()
        // Abort actual writes, including after a setter's provisional INSERT.
        // This tests rollback, not just a readonly failure before work begins.
        try queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_update BEFORE UPDATE ON session_state
                BEGIN SELECT RAISE(ABORT, 'test rejects update'); END;
                CREATE TRIGGER reject_delete BEFORE DELETE ON session_state
                BEGIN SELECT RAISE(ABORT, 'test rejects delete'); END;
                """)
        }
        let recorder = RowChangeRecorder()
        let token = recorder.observe(db)
        defer { db.removeRowChangeObserver(token) }
        let joins = RowChangeRecorder()
        let joinToken = db.observeJoins { id, _ in joins.append(id: id, state: try! db.sessionState(id)) }
        defer { db.removeJoinObserver(joinToken) }
        let failures: [(String, () throws -> Void)] = [
            ("pin insertion rolls back", { try db.setPinned(true, sessionID: "new-pin") }),
            ("archive insertion rolls back", { try db.setArchived(true, sessionID: "new-archive") }),
            ("name insertion rolls back", { try db.setCustomName("Name", sessionID: "new-name") }),
            ("color insertion rolls back", { try db.setColor("blue", sessionID: "new-color") }),
            ("opened insertion rolls back", { try db.recordOpened(sessionID: "new-opened") }),
            ("title insertion rolls back", { try db.setTitle("Title", sessionID: "new-title") }),
            ("pin existing", { try db.setPinned(true, sessionID: "s") }),
            ("archive existing", { try db.setArchived(true, sessionID: "s") }),
            ("name existing", { try db.setCustomName("Name", sessionID: "s") }),
            ("color existing", { try db.setColor("blue", sessionID: "s") }),
            ("opened existing", { try db.recordOpened(sessionID: "s") }),
            ("title existing", { try db.setTitle("Title", sessionID: "s") }),
            ("legacy title", { try db.setGeneratedTitle("Title", sessionID: "s") }),
            ("hint", { try db.updateTranscriptHint(sessionID: "s", agent: .claude, path: URL(fileURLWithPath: "/hint")) }),
            ("leave", { _ = try db.leave(sessionID: "s") }),
            ("launch directory", { try db.observeLaunchDirectory(sessionID: "s", "/launch") }),
            ("touch", { try db.touch(sessionID: "s") }),
            ("fill", { try db.fillCoreFields(sessionID: "s", title: "Prompt") }),
            ("join core", { try db.join(sessionID: "s", via: .imported, core: SessionCore(title: "Prompt")) }),
            ("join insertion rolls back", { try db.join(sessionID: "new-join", via: .created, core: SessionCore(title: "Prompt")) }),
        ]
        for (name, mutate) in failures {
            XCTAssertThrowsError(try mutate(), name)
            XCTAssertTrue(recorder.events.isEmpty, name)
            XCTAssertTrue(joins.events.isEmpty, name)
            XCTAssertEqual(try db.sessionStates(), before, name)
        }
        try queue.write { database in
            try database.execute(sql: "CREATE TRIGGER reject_insert BEFORE INSERT ON session_state BEGIN SELECT RAISE(ABORT, 'test rejects insert'); END")
        }
        XCTAssertThrowsError(try db.join(sessionID: "new-plain-join", via: .created))
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(joins.events.isEmpty)
    }
}

private final class RowChangeRecorder: @unchecked Sendable {
    struct Event {
        let id: String
        let state: SessionState?
    }
    private let lock = NSLock()
    private var storedEvents: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return storedEvents }

    func append(id: String, state: SessionState?) {
        lock.lock(); defer { lock.unlock() }
        storedEvents.append(Event(id: id, state: state))
    }

    func observe(_ db: TempleDB) -> UUID {
        db.observeRowChanges { id in
            // Reading the ORIGINATING connection fails if this callback still
            // runs on its writer queue. Register/remove also re-enters the
            // observer mutex, proving that lock is not held during delivery.
            let state = try! db.sessionState(id)
            let temporary = db.observeRowChanges { _ in }
            db.removeRowChangeObserver(temporary)
            self.append(id: id, state: state)
        }
    }
}
