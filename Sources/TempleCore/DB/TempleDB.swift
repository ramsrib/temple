import Foundation
import GRDB

public struct SessionState: Codable, Equatable, Sendable {
    public let id: String
    public let pinned: Bool
    public let archived: Bool
    public let customName: String?
    public let color: String?
    /// The last title the agent gave itself (Claude/Codex retitle their terminal
    /// as the work moves on). The session file never carries this, so if we don't
    /// remember it here it is lost the moment the session closes.
    public let generatedTitle: String?
    public let lastOpenedAt: Date?
}

/// Per-project state: archived, and where the user placed it in the sidebar.
/// A nil `position` is not "position zero" — it means the project has never
/// been placed, and still sorts by the launch-frozen recency order.
public struct ProjectState: Codable, Equatable, Sendable {
    public let path: String
    public let archived: Bool
    public let position: Int?
}

public struct ProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let sessionID: String
    public let startedAt: Date
}

public struct OpenTabRecord: Codable, Equatable, Sendable {
    public let projectPath: String
    public let sessionID: String
    public let position: Int
    public let agent: String
    public let title: String
    /// The tab that had the screen when the app was last quit. At most one
    /// record carries it; a set with none simply restores to the launcher.
    public let isActive: Bool

    public init(projectPath: String, sessionID: String, position: Int, agent: String,
                title: String, isActive: Bool = false) {
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.position = position
        self.agent = agent
        self.title = title
        self.isActive = isActive
    }
}

/// Temple-owned, rebuildable application state. CLI session content remains on disk.
public final class TempleDB: @unchecked Sendable {
    private let db: DatabaseQueue

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        db = try DatabaseQueue(path: path.path)
        try Self.migrator.migrate(db)
    }

    private init(database: DatabaseQueue) throws {
        db = database
        try Self.migrator.migrate(db)
    }

    public static func inMemory() throws -> TempleDB {
        try TempleDB(database: DatabaseQueue())
    }

    public static func defaultPath() -> URL {
        TempleState.directory.appendingPathComponent("temple.sqlite")
    }

    public func setPinned(_ pinned: Bool, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET pinned = ? WHERE id = ?", arguments: [pinned, sessionID])
        }
    }

    /// Archiving also clears the pin, in the same statement: two writes could
    /// land one without the other and leave a session both put away and pinned
    /// after a restart. Unarchiving leaves the pin column alone.
    public func setArchived(_ archived: Bool, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(
                sql: """
                    UPDATE session_state
                    SET archived = ?, pinned = CASE WHEN ? THEN 0 ELSE pinned END
                    WHERE id = ?
                    """,
                arguments: [archived, archived, sessionID]
            )
        }
    }

    public func setCustomName(_ name: String?, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET custom_name = ? WHERE id = ?", arguments: [name, sessionID])
        }
    }

    public func setColor(_ color: String?, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET color = ? WHERE id = ?", arguments: [color, sessionID])
        }
    }

    public func setGeneratedTitle(_ title: String?, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET generated_title = ? WHERE id = ?", arguments: [title, sessionID])
        }
    }

    public func recordOpened(sessionID: String, at: Date = Date()) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET last_opened_at = ? WHERE id = ?", arguments: [at, sessionID])
        }
    }

    public func sessionState(_ sessionID: String) throws -> SessionState? {
        try db.read { database in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM session_state WHERE id = ?", arguments: [sessionID]) else {
                return nil
            }
            return SessionState(
                id: row["id"],
                pinned: row["pinned"],
                archived: row["archived"],
                customName: row["custom_name"],
                color: row["color"],
                generatedTitle: row["generated_title"],
                lastOpenedAt: row["last_opened_at"]
            )
        }
    }

    public func sessionStates() throws -> [SessionState] {
        try db.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM session_state ORDER BY id").map { row in
                SessionState(
                    id: row["id"],
                    pinned: row["pinned"],
                    archived: row["archived"],
                    customName: row["custom_name"],
                    color: row["color"],
                    generatedTitle: row["generated_title"],
                    lastOpenedAt: row["last_opened_at"]
                )
            }
        }
    }

    public func projectStates() throws -> [ProjectState] {
        try db.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM project_state ORDER BY path").map { row in
                ProjectState(path: row["path"], archived: row["archived"], position: row["position"])
            }
        }
    }

    public func setProjectArchived(_ archived: Bool, path: String) throws {
        try ensureProjectState(path)
        try db.write { database in
            try database.execute(sql: "UPDATE project_state SET archived = ? WHERE path = ?",
                                 arguments: [archived, path])
        }
    }

    /// Replaces the manual sidebar order wholesale. One transaction, because a
    /// half-applied order is a sidebar with two projects claiming slot 3: every
    /// existing position is cleared first, then the listed paths are numbered.
    /// A path absent from `paths` goes back to unplaced, not to the end.
    public func setProjectOrder(_ paths: [String]) throws {
        try db.write { database in
            try database.execute(sql: "UPDATE project_state SET position = NULL")
            for (position, path) in paths.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO project_state (path, position) VALUES (?, ?)
                        ON CONFLICT(path) DO UPDATE SET position = excluded.position
                        """,
                    arguments: [path, position]
                )
            }
        }
    }

    public func setOpenTabs(projectPath: String, sessionIDs: [String]) throws {
        try db.write { database in
            try database.execute(sql: "DELETE FROM open_tabs WHERE project_path = ?", arguments: [projectPath])
            for (position, sessionID) in sessionIDs.enumerated() {
                try database.execute(
                    sql: "INSERT INTO open_tabs (project_path, session_id, position) VALUES (?, ?, ?)",
                    arguments: [projectPath, sessionID, position]
                )
            }
        }
    }

    public func openTabs(projectPath: String) throws -> [String] {
        try db.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT session_id FROM open_tabs WHERE project_path = ? ORDER BY position",
                arguments: [projectPath]
            )
        }
    }

    /// Atomically replaces every project's restorable tabs, including the
    /// metadata required to reconstruct lazy inert chips.
    public func replaceOpenTabs(_ records: [OpenTabRecord]) throws {
        try db.write { database in
            try database.execute(sql: "DELETE FROM open_tabs")
            for record in records {
                try database.execute(
                    sql: """
                        INSERT INTO open_tabs
                            (project_path, session_id, position, agent, title, active)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [record.projectPath, record.sessionID, record.position,
                                record.agent, record.title, record.isActive]
                )
            }
        }
    }

    public func openTabRecords() throws -> [OpenTabRecord] {
        try db.read { database in
            try Row.fetchAll(
                database,
                // rowid = insertion order. replaceOpenTabs writes the ACTIVE
                // project's records first so relaunch reopens the last-used
                // project; sorting by project_path here would hand that seat
                // to whichever project sorts first alphabetically.
                sql: "SELECT * FROM open_tabs ORDER BY rowid"
            ).map { row in
                OpenTabRecord(
                    projectPath: row["project_path"],
                    sessionID: row["session_id"],
                    position: row["position"],
                    agent: row["agent"],
                    title: row["title"],
                    isActive: row["active"]
                )
            }
        }
    }

    /// Window chrome the user arranged, keyed by name. Lives here rather than in
    /// `UserDefaults` so `TEMPLE_STATE_DIR` isolates it: a `make demo` run must not
    /// change what the installed app looks like on its next launch.
    ///
    /// A missing key is not missing data — it means "defer to the shipped
    /// default", so `setUIState(nil, for:)` deletes rather than storing an empty
    /// string.
    public func uiState() throws -> [String: String] {
        try db.read { database in
            var values: [String: String] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT key, value FROM ui_state") {
                values[row["key"]] = row["value"]
            }
            return values
        }
    }

    public func uiState(_ key: String) throws -> String? {
        try db.read { database in
            try String.fetchOne(database, sql: "SELECT value FROM ui_state WHERE key = ?", arguments: [key])
        }
    }

    public func setUIState(_ value: String?, for key: String) throws {
        try db.write { database in
            guard let value else {
                try database.execute(sql: "DELETE FROM ui_state WHERE key = ?", arguments: [key])
                return
            }
            try database.execute(
                sql: "INSERT OR REPLACE INTO ui_state (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    public func registerProcess(pid: Int32, sessionID: String, startedAt: Date = Date()) throws {
        try db.write { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO process_registry (pid, session_id, started_at) VALUES (?, ?, ?)",
                arguments: [Int64(pid), sessionID, startedAt]
            )
        }
    }

    public func unregisterProcess(pid: Int32) throws {
        try db.write { database in
            try database.execute(sql: "DELETE FROM process_registry WHERE pid = ?", arguments: [Int64(pid)])
        }
    }

    public func unregisterProcess(sessionID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "DELETE FROM process_registry WHERE session_id = ?",
                arguments: [sessionID]
            )
        }
    }

    public func liveProcesses() throws -> [ProcessRecord] {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM process_registry ORDER BY started_at")
            return rows.compactMap { row in
                let storedPID: Int64 = row["pid"]
                guard let pid = Int32(exactly: storedPID) else { return nil }
                return ProcessRecord(pid: pid, sessionID: row["session_id"], startedAt: row["started_at"])
            }
        }
    }

    private func ensureState(_ sessionID: String) throws {
        try db.write { database in
            try database.execute(
                sql: "INSERT OR IGNORE INTO session_state (id) VALUES (?)",
                arguments: [sessionID]
            )
        }
    }

    private func ensureProjectState(_ path: String) throws {
        try db.write { database in
            try database.execute(
                sql: "INSERT OR IGNORE INTO project_state (path) VALUES (?)",
                arguments: [path]
            )
        }
    }

    private static var migrator: DatabaseMigrator {
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
        return migrator
    }
}
