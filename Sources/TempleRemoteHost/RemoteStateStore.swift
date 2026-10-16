import Foundation
import GRDB
import TempleCore

/// One agent process on one host under one tmux session name, however many
/// times Temple attaches to it (docs/designs/remote-ssh.md section 3). The
/// row is durable from before the spawn; the session it serves may have
/// several runs over time (one ends, the user resumes it in another), so
/// nothing here is unique per session id (implementation note 1).
public struct RemoteRun: Equatable, Sendable {
    public enum Mode: String, Sendable { case new, resume }

    /// What the creation step proved. Nil while the first Open is still
    /// creating and nothing has come back.
    public enum Creation: String, Sendable {
        /// The pane's own `ok` record arrived: the agent ran in the folder.
        case proven
        /// The tmux client failed, or no record ever came: the session may
        /// exist. Every Open is attach-only from here.
        case unproven
        /// The pane reported it could not enter the folder, or nothing was
        /// ever spawned: no session exists.
        case failed
    }

    /// How an end was proven.
    public enum EndEvidence: String, Sendable {
        /// The pinned server answered `can't find session`.
        case absent
        /// Temple's own targeted kill was acknowledged.
        case killed
    }

    /// Why a stop Temple could not carry out and confirm left the session
    /// running (section 5).
    public enum LeftRunningReason: String, Sendable, CaseIterable {
        case hostDidNotAnswer = "host did not answer"
        case stopNotAcknowledged = "stop not acknowledged"
        case anotherClientAttached = "another client attached"
        case quitDeadline = "quit deadline"
    }

    public var handle: String
    public var host: HostID
    public var agent: Agent
    public var mode: Mode
    /// `temple-<handle>` on the host's private server.
    public var sessionName: String
    /// The folder as the user named it (may start with `~`).
    public var directoryIntent: String
    /// The pane's `pwd -P`, once its `ok` record arrived.
    public var directory: String?
    public var sessionID: String?
    /// Incremented on every Open; asynchronous results are bound to it.
    public var attachment: Int
    /// The launch record's name on the host, under
    /// `${TMPDIR:-/tmp}/temple-launch-<uid>/`, so an `ok` written there but
    /// never collected is fetched on the next Open.
    public var recordPath: String
    public var startedAt: Date
    /// The remote clock when the pane wrote `ok` (seconds since 1970).
    public var okAt: Int?
    public var panePID: Int?
    public var paneStart: String?
    /// The server the run was created on, from the pane's `$TMUX`: every
    /// later attach, check and stop goes to this socket (`-S`).
    public var socketPath: String?
    public var serverPID: Int?
    public var serverStart: String?
    public var creation: Creation?
    public var endedAt: Date?
    public var endEvidence: EndEvidence?
    public var leftRunningAt: Date?
    public var leftRunningReason: LeftRunningReason?
    /// The sidebar's "left running" line was dismissed or acted on for this
    /// flag: it does not come back (fable must-fix 6).
    public var leftRunningNoticedAt: Date?
    public var dismissedAt: Date?
    /// A launch failure's words (`failed cd`, `failed tmux`).
    public var failure: String?

    public init(handle: String, host: HostID, agent: Agent, mode: Mode, directoryIntent: String,
                sessionID: String?, recordPath: String, startedAt: Date) {
        self.handle = handle; self.host = host; self.agent = agent; self.mode = mode
        sessionName = "temple-\(handle)"
        self.directoryIntent = directoryIntent; self.sessionID = sessionID
        attachment = 1
        self.recordPath = recordPath; self.startedAt = startedAt
    }

    /// Ended: absent proven, or Temple's kill acknowledged, or never created.
    public var isEnded: Bool { endedAt != nil }
    public var isLeftRunning: Bool { leftRunningAt != nil && endedAt == nil }
}

/// `remote-state.sqlite` in the state directory, owned by this module with
/// its own migrator (`r1-runs`). Deleting the file loses Temple's map from
/// rows to handles and nothing in core ("Removing remote", section 9).
///
/// Every change is a per-row read-modify-write inside one transaction: two
/// Temple processes on one state directory never erase each other's runs.
public final class RemoteStateStore: @unchecked Sendable {
    public static let fileName = "remote-state.sqlite"

    private let queue: DatabaseQueue
    public let url: URL?

    public init(directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        queue = try DatabaseQueue(path: url.path, configuration: configuration)
        self.url = url
        try Self.migrator.migrate(queue)
    }

    /// For tests.
    public init() throws {
        queue = try DatabaseQueue()
        url = nil
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("r1-runs") { database in
            try database.execute(sql: """
                CREATE TABLE runs (
                    handle TEXT PRIMARY KEY NOT NULL,
                    host TEXT NOT NULL,
                    agent TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    session_name TEXT NOT NULL,
                    directory_intent TEXT NOT NULL,
                    directory TEXT,
                    session_id TEXT,
                    attachment INTEGER NOT NULL DEFAULT 1,
                    record_path TEXT NOT NULL,
                    started_at DOUBLE NOT NULL,
                    ok_at INTEGER,
                    pane_pid INTEGER,
                    pane_start TEXT,
                    socket_path TEXT,
                    server_pid INTEGER,
                    server_start TEXT,
                    creation TEXT,
                    ended_at DOUBLE,
                    end_evidence TEXT,
                    left_running_at DOUBLE,
                    left_running_reason TEXT,
                    left_running_noticed_at DOUBLE,
                    dismissed_at DOUBLE,
                    failure TEXT
                );
                CREATE INDEX runs_by_session ON runs (host, session_id, started_at);
                CREATE TABLE remote_project_state (
                    host TEXT NOT NULL,
                    path TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    position INTEGER,
                    PRIMARY KEY (host, path)
                );
                """)
        }
        return migrator
    }

    /// The migrations this build knows, in order.
    public static var migrationIdentifiers: [String] { migrator.migrations }

    // MARK: Runs

    /// Written before the spawn: a failure refuses the open.
    public func insert(_ run: RemoteRun) throws {
        try queue.write { database in
            try database.execute(sql: """
                INSERT INTO runs (handle, host, agent, mode, session_name, directory_intent, directory, session_id,
                    attachment, record_path, started_at, ok_at, pane_pid, pane_start, socket_path, server_pid,
                    server_start, creation, ended_at, end_evidence, left_running_at, left_running_reason,
                    left_running_noticed_at, dismissed_at, failure)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: StatementArguments(Self.values(run)))
        }
    }

    public func run(_ handle: String) throws -> RemoteRun? {
        try queue.read { database in
            try Row.fetchOne(database, sql: "SELECT * FROM runs WHERE handle = ?", arguments: [handle]).map(Self.run)
        }
    }

    /// Every run on a host, oldest first.
    public func runs(host: HostID) throws -> [RemoteRun] {
        try queue.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM runs WHERE host = ? ORDER BY started_at, rowid",
                             arguments: [host.rawValue]).map(Self.run)
        }
    }

    /// Every run of a session on a host, oldest first.
    public func runs(host: HostID, sessionID: String) throws -> [RemoteRun] {
        try queue.read { database in
            try Row.fetchAll(database, sql: """
                SELECT * FROM runs WHERE host = ? AND session_id = ? ORDER BY started_at, rowid
                """, arguments: [host.rawValue, sessionID]).map(Self.run)
        }
    }

    /// The latest run of a session that is not Ended: what Open attaches to.
    public func liveRun(host: HostID, sessionID: String) throws -> RemoteRun? {
        try runs(host: host, sessionID: sessionID).last { !$0.isEnded && $0.dismissedAt == nil }
    }

    /// Runs flagged left running and not ended.
    public func leftRunning(host: HostID) throws -> [RemoteRun] {
        try runs(host: host).filter(\.isLeftRunning)
    }

    /// Read-modify-write of one row in one transaction. Nil when the row
    /// is not there (nothing written).
    @discardableResult
    public func update(_ handle: String, _ change: (inout RemoteRun) -> Void) throws -> RemoteRun? {
        try queue.write { database in
            guard var run = try Row.fetchOne(database, sql: "SELECT * FROM runs WHERE handle = ?",
                                             arguments: [handle]).map(Self.run) else { return nil }
            change(&run)
            run.handle = handle
            try database.execute(sql: """
                UPDATE runs SET host = ?, agent = ?, mode = ?, session_name = ?, directory_intent = ?, directory = ?,
                    session_id = ?, attachment = ?, record_path = ?, started_at = ?, ok_at = ?, pane_pid = ?,
                    pane_start = ?, socket_path = ?, server_pid = ?, server_start = ?, creation = ?, ended_at = ?,
                    end_evidence = ?, left_running_at = ?, left_running_reason = ?, left_running_noticed_at = ?,
                    dismissed_at = ?, failure = ?
                WHERE handle = ?
                """, arguments: StatementArguments(Array(Self.values(run).dropFirst()) + [handle]))
            return run
        }
    }

    /// The next attachment of a run (every Open), in one transaction.
    public func nextAttachment(_ handle: String) throws -> Int? {
        try update(handle) { $0.attachment += 1 }?.attachment
    }

    private static func values(_ run: RemoteRun) -> [(any DatabaseValueConvertible)?] {
        [run.handle, run.host.rawValue, run.agent.rawValue, run.mode.rawValue, run.sessionName, run.directoryIntent,
         run.directory, run.sessionID, run.attachment, run.recordPath, run.startedAt.timeIntervalSince1970,
         run.okAt, run.panePID, run.paneStart, run.socketPath, run.serverPID, run.serverStart,
         run.creation?.rawValue, run.endedAt?.timeIntervalSince1970, run.endEvidence?.rawValue,
         run.leftRunningAt?.timeIntervalSince1970, run.leftRunningReason?.rawValue,
         run.leftRunningNoticedAt?.timeIntervalSince1970, run.dismissedAt?.timeIntervalSince1970, run.failure]
    }

    private static func run(_ row: Row) -> RemoteRun {
        func date(_ column: String) -> Date? { (row[column] as Double?).map(Date.init(timeIntervalSince1970:)) }
        var run = RemoteRun(handle: row["handle"], host: HostID(rawValue: row["host"]),
                            agent: Agent(rawValue: row["agent"]) ?? .claude,
                            mode: RemoteRun.Mode(rawValue: row["mode"]) ?? .new,
                            directoryIntent: row["directory_intent"], sessionID: row["session_id"],
                            recordPath: row["record_path"], startedAt: date("started_at") ?? .distantPast)
        run.sessionName = row["session_name"]
        run.directory = row["directory"]
        run.attachment = row["attachment"]
        run.okAt = row["ok_at"]
        run.panePID = row["pane_pid"]
        run.paneStart = row["pane_start"]
        run.socketPath = row["socket_path"]
        run.serverPID = row["server_pid"]
        run.serverStart = row["server_start"]
        run.creation = (row["creation"] as String?).flatMap(RemoteRun.Creation.init(rawValue:))
        run.endedAt = date("ended_at")
        run.endEvidence = (row["end_evidence"] as String?).flatMap(RemoteRun.EndEvidence.init(rawValue:))
        run.leftRunningAt = date("left_running_at")
        run.leftRunningReason = (row["left_running_reason"] as String?).flatMap(RemoteRun.LeftRunningReason.init(rawValue:))
        run.leftRunningNoticedAt = date("left_running_noticed_at")
        run.dismissedAt = date("dismissed_at")
        run.failure = row["failure"]
        return run
    }

    // MARK: Remote project state

    public struct ProjectState: Equatable, Sendable {
        public var host: HostID
        public var path: String
        public var archived: Bool
        public var position: Int?
    }

    public func projectStates() throws -> [ProjectState] {
        try queue.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM remote_project_state ORDER BY host, path").map { row in
                ProjectState(host: HostID(rawValue: row["host"]), path: row["path"],
                             archived: row["archived"], position: row["position"])
            }
        }
    }

    public func setProjectArchived(_ archived: Bool, host: HostID, path: String) throws {
        try queue.write { database in
            try database.execute(sql: "INSERT OR IGNORE INTO remote_project_state (host, path) VALUES (?, ?)",
                                 arguments: [host.rawValue, path])
            try database.execute(sql: "UPDATE remote_project_state SET archived = ? WHERE host = ? AND path = ?",
                                 arguments: [archived, host.rawValue, path])
        }
    }

    /// The remote part of the manual project order: these keys, in order,
    /// get positions; every other remote project loses its position.
    public func setProjectOrder(_ keys: [(host: HostID, path: String)]) throws {
        try queue.write { database in
            try database.execute(sql: "UPDATE remote_project_state SET position = NULL")
            for (index, key) in keys.enumerated() {
                try database.execute(sql: """
                    INSERT INTO remote_project_state (host, path, position) VALUES (?, ?, ?)
                    ON CONFLICT (host, path) DO UPDATE SET position = excluded.position
                    """, arguments: [key.host.rawValue, key.path, index])
            }
        }
    }
}
