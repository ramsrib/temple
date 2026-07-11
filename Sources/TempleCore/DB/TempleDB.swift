import Foundation
import GRDB

public struct SessionState: Codable, Equatable, Sendable {
    public let id: String
    public let pinned: Bool
    public let archived: Bool
    public let customName: String?
    public let lastOpenedAt: Date?
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

    public init(projectPath: String, sessionID: String, position: Int, agent: String, title: String) {
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.position = position
        self.agent = agent
        self.title = title
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

    public func setArchived(_ archived: Bool, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET archived = ? WHERE id = ?", arguments: [archived, sessionID])
        }
    }

    public func setCustomName(_ name: String?, sessionID: String) throws {
        try ensureState(sessionID)
        try db.write { database in
            try database.execute(sql: "UPDATE session_state SET custom_name = ? WHERE id = ?", arguments: [name, sessionID])
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
                    lastOpenedAt: row["last_opened_at"]
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
                            (project_path, session_id, position, agent, title)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [record.projectPath, record.sessionID, record.position,
                                record.agent, record.title]
                )
            }
        }
    }

    public func openTabRecords() throws -> [OpenTabRecord] {
        try db.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM open_tabs ORDER BY project_path, position"
            ).map { row in
                OpenTabRecord(
                    projectPath: row["project_path"],
                    sessionID: row["session_id"],
                    position: row["position"],
                    agent: row["agent"],
                    title: row["title"]
                )
            }
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
        return migrator
    }
}
