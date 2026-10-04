import Foundation
import Darwin
import GRDB

/// How a session joined Temple — recorded once, when its row is first written,
/// and never changed. Having a row is what makes a session Temple's; this only
/// says how it got one, and never decides what is shown.
///
/// It answers "how did Temple come to have it", never "where did it come
/// from". Lineage — continued or forked from another session, spawned by one —
/// is a separate fact with its own columns when it lands (ADR-023): Claude's
/// `←` both continues a session under a new id AND creates it in the Temple
/// tab it ran in, and one value cannot say both.
public enum JoinedVia: String, Codable, Sendable {
    /// Temple started it: minted its Claude id, or adopted the Codex id of a
    /// session it launched.
    case created
    /// An existing session, first run in Temple by resuming it.
    case opened
    /// Brought in without being run — pinned, renamed, colored or archived
    /// while browsing every session on disk.
    case imported
}

public enum TempleDBError: Error, Equatable, LocalizedError {
    case newerSchema
    /// Another opener held the migration lock past the wait limit.
    case migrationLockTimeout

    public static let updateRequiredMessage = "This Temple is older than the data it found. Update Temple to continue."
    public var errorDescription: String? {
        switch self {
        case .newerSchema: Self.updateRequiredMessage
        case .migrationLockTimeout: "Another Temple process kept the database locked."
        }
    }
}

/// Core facts supplied at join. Launch directory observations are a separate,
/// authoritative write; joining itself only fills unknown facts.
public struct SessionCore: Sendable {
    public let host: HostID
    public let directory: String?
    public let directorySource: DirectorySource?
    public let title: String?
    public let lastActiveAt: Date?

    public init(host: HostID = .local, directory: String? = nil,
                directorySource: DirectorySource? = nil, title: String? = nil,
                lastActiveAt: Date? = nil) {
        self.host = host; self.directory = directory; self.directorySource = directorySource
        self.title = title; self.lastActiveAt = lastActiveAt
    }
}

public enum SessionCoreField: Hashable, Sendable {
    case agent, directory, title, lastActiveAt
}

public struct SessionState: Codable, Hashable, Sendable {
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
    /// Nil for rows written before Temple recorded this: unknown, not "none".
    public let joinedVia: JoinedVia?
    public let joinedAt: Date?
    public let agent: Agent?
    public let transcriptPath: String?
    public let host: HostID
    public let directory: String?
    public let directorySource: DirectorySource?
    public let title: String?
    public var lastActiveAt: Date?

    public init(id: String, pinned: Bool, archived: Bool, customName: String?, color: String?,
                generatedTitle: String?, lastOpenedAt: Date?, joinedVia: JoinedVia?, joinedAt: Date?,
                agent: Agent? = nil, transcriptPath: String? = nil,
                host: HostID = .local, directory: String? = nil,
                directorySource: DirectorySource? = nil, title: String? = nil,
                lastActiveAt: Date? = nil) {
        self.id = id; self.pinned = pinned; self.archived = archived
        self.customName = customName; self.color = color; self.generatedTitle = generatedTitle
        self.lastOpenedAt = lastOpenedAt; self.joinedVia = joinedVia; self.joinedAt = joinedAt
        self.agent = agent; self.transcriptPath = transcriptPath
        self.host = host; self.directory = directory; self.directorySource = directorySource
        self.title = title; self.lastActiveAt = lastActiveAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        generatedTitle = try c.decodeIfPresent(String.self, forKey: .generatedTitle)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        joinedVia = try c.decodeIfPresent(JoinedVia.self, forKey: .joinedVia)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        host = try c.decodeIfPresent(HostID.self, forKey: .host) ?? .local
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        directorySource = try c.decodeIfPresent(DirectorySource.self, forKey: .directorySource)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    }
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
    public private(set) var isReadOnly = false
    private let observerLock = NSLock()
    private var joinObservers: [UUID: @Sendable (String, Bool) -> Void] = [:]

    /// Delivered after committed membership or hint changes. Unchanged existing
    /// joins do not invalidate loaded members; explicit opens retry unresolved IDs.
    /// Observers register before reading rows so concurrent joins survive.
    public func observeJoins(_ observer: @escaping @Sendable (String, Bool) -> Void) -> UUID {
        observerLock.lock(); defer { observerLock.unlock() }
        let token = UUID(); joinObservers[token] = observer; return token
    }

    public func removeJoinObserver(_ token: UUID) {
        observerLock.lock(); defer { observerLock.unlock() }
        joinObservers.removeValue(forKey: token)
    }

    private var leaveObservers: [UUID: @Sendable (String) -> Void] = [:]

    /// Delivered after a committed `leave`: the session is no longer Temple's.
    public func observeLeaves(_ observer: @escaping @Sendable (String) -> Void) -> UUID {
        observerLock.lock(); defer { observerLock.unlock() }
        let token = UUID(); leaveObservers[token] = observer; return token
    }

    public func removeLeaveObserver(_ token: UUID) {
        observerLock.lock(); defer { observerLock.unlock() }
        leaveObservers.removeValue(forKey: token)
    }

    private func committedLeave(_ id: String) {
        observerLock.lock(); let callbacks = Array(leaveObservers.values); observerLock.unlock()
        callbacks.forEach { $0(id) }
    }

    private func committedJoin(_ id: String, awaitingCreation: Bool = false) {
        observerLock.lock(); let callbacks = Array(joinObservers.values); observerLock.unlock()
        callbacks.forEach { $0(id, awaitingCreation) }
    }


    private var rowObservers: [UUID: @Sendable (String) -> Void] = [:]

    /// Like join observation, callbacks run after commit and outside the lock.
    /// Register before reading rows. This observes this connection's writes only.
    public func observeRowChanges(_ observer: @escaping @Sendable (String) -> Void) -> UUID {
        observerLock.lock(); defer { observerLock.unlock() }
        let token = UUID(); rowObservers[token] = observer; return token
    }

    public func removeRowChangeObserver(_ token: UUID) {
        observerLock.lock(); defer { observerLock.unlock() }
        rowObservers.removeValue(forKey: token)
    }

    private func committedRowChange(_ id: String) {
        observerLock.lock(); let callbacks = Array(rowObservers.values); observerLock.unlock()
        callbacks.forEach { $0(id) }
    }

    private static func checkSchema(_ queue: DatabaseQueue) throws {
        if try queue.read({ try migrator.hasBeenSuperseded($0) }) {
            throw TempleDBError.newerSchema
        }
    }

    private static func migrateAndReconcile(_ queue: DatabaseQueue) throws {
        try checkSchema(queue)
        if try !queue.read({ try migrator.hasCompletedMigrations($0) }) {
            try migrator.migrate(queue)
        }
        // A7: open-time only. Old-process writes after this open are picked up
        // on the next open; there is no live cross-process title synchronization.
        // Read first: an open that changes nothing takes no write lock, so a
        // second process holding one cannot fail this launch.
        let differs = try queue.read { database in
            try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM session_state WHERE generated_title IS NOT NULL AND title IS NOT generated_title)") ?? false
        }
        guard differs else { return }
        try queue.write { database in
            try database.execute(sql: "UPDATE session_state SET title = generated_title WHERE generated_title IS NOT NULL AND title IS NOT generated_title")
        }
    }

    /// How long a writer waits on another connection's lock before failing.
    static let busyTimeout: TimeInterval = 5

    public convenience init(path: URL) throws {
        try self.init(path: path, onMigrationLockContention: nil)
    }

    // The contention callback is an internal test seam, called only after flock
    // proves another opener owns the lock (no timing assumptions in race tests).
    init(path: URL, onMigrationLockContention: (() -> Void)?, lockTimeout: TimeInterval = 15) throws {
        let path = path.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        db = try Self.withMigrationLock(at: path, timeout: lockTimeout, onContention: onMigrationLockContention) {
            // The writer opens first, and nothing it does before checkSchema
            // writes: queue setup only reads sqlite_master. That read is also
            // what rolls back a hot journal a crashed writer left behind —
            // restoring the last committed state, never a schema change. A
            // read-only probe could not: SQLITE_READONLY_ROLLBACK, on every
            // launch, since nothing else would ever roll it back.
            var configuration = Configuration()
            configuration.busyMode = .timeout(Self.busyTimeout)
            let queue = try DatabaseQueue(path: path.path, configuration: configuration)
            do {
                try Self.migrateAndReconcile(queue)
            } catch {
                try? queue.close()
                throw error
            }
            return queue
        }
    }

    private static func withMigrationLock<T>(at path: URL, timeout: TimeInterval,
                                             onContention: (() -> Void)?,
                                             _ body: () throws -> T) throws -> T {
        // SQLite's separate check/migration/reconcile transactions leave a gap.
        // Every P1+ migrator holds this cross-process lock through ALL of them,
        // including the writer's open, so a future incompatible migration
        // cannot commit in that gap. Pre-P1 migrations are all known to this build.
        // Keep the sidecar: unlinking it would let another opener lock a new inode.
        let fd = Darwin.open(path.path + ".migrate-lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        // Bounded: an opener stuck holding the lock must not hang this launch
        // forever behind a window that never appears.
        let deadline = Date().addingTimeInterval(timeout)
        var contended = false
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            if !contended { contended = true; onContention?() }
            guard Date() < deadline else { throw TempleDBError.migrationLockTimeout }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Opens an existing, already-migrated database without write access: for
    /// tools that must only look, and for tests of what happens when a write
    /// fails — every write here throws.
    public init(readOnlyPath path: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        isReadOnly = true
        db = try DatabaseQueue(path: path.path, configuration: configuration)
        try Self.checkSchema(db)
    }

    // In-memory queue injection lets tests trace SQL without a filesystem lock.
    // File-backed callers must use init(path:) so writer open is also locked.
    init(database: DatabaseQueue) throws {
        precondition(database.path == ":memory:", "File-backed databases require init(path:)")
        db = database
        try Self.migrateAndReconcile(db)
    }

    public static func inMemory() throws -> TempleDB {
        try TempleDB(database: DatabaseQueue())
    }

    public static func defaultPath() -> URL {
        TempleState.directory.appendingPathComponent("temple.sqlite")
    }

    public func setPinned(_ pinned: Bool, sessionID: String) throws {
        try updateState(sessionID) { database in
            try database.execute(sql: "UPDATE session_state SET pinned = ? WHERE id = ? AND pinned IS NOT ?",
                                 arguments: [pinned, sessionID, pinned])
        }
    }

    /// Archiving also clears the pin, in the same statement: two writes could
    /// land one without the other and leave a session both put away and pinned
    /// after a restart. Unarchiving leaves the pin column alone.
    public func setArchived(_ archived: Bool, sessionID: String) throws {
        try updateState(sessionID) { database in
            try database.execute(
                sql: """
                    UPDATE session_state
                    SET archived = ?, pinned = CASE WHEN ? THEN 0 ELSE pinned END
                    WHERE id = ? AND (archived IS NOT ? OR (? AND pinned != 0))
                    """,
                arguments: [archived, archived, sessionID, archived, archived]
            )
        }
    }

    public func setCustomName(_ name: String?, sessionID: String) throws {
        try updateState(sessionID) { database in
            try database.execute(sql: "UPDATE session_state SET custom_name = ? WHERE id = ? AND custom_name IS NOT ?",
                                 arguments: [name, sessionID, name])
        }
    }

    public func setColor(_ color: String?, sessionID: String) throws {
        try updateState(sessionID) { database in
            try database.execute(sql: "UPDATE session_state SET color = ? WHERE id = ? AND color IS NOT ?",
                                 arguments: [color, sessionID, color])
        }
    }

    public func setGeneratedTitle(_ title: String?, sessionID: String) throws {
        try setTitle(title, sessionID: sessionID)
    }

    public func setTitle(_ title: String?, sessionID: String) throws {
        try updateState(sessionID) { database in
            try database.execute(sql: "UPDATE session_state SET title = ?, generated_title = ? WHERE id = ? AND (title IS NOT ? OR generated_title IS NOT ?)",
                                 arguments: [title, title, sessionID, title, title])
        }
    }

    /// The session becomes Temple's. Only the first join is recorded: a
    /// session that already has a row keeps the way it came in, and one from
    /// before that was recorded stays unknown rather than being
    /// credited to whatever touched it next.
    public func join(sessionID: String, via: JoinedVia, at: Date = Date(),
                     agent: Agent? = nil, transcriptPath: URL? = nil, core: SessionCore? = nil) throws {
        let changed = try db.write { database -> (join: Bool, row: Bool) in
            let old = try Row.fetchOne(database, sql: "SELECT * FROM session_state WHERE id = ?", arguments: [sessionID])
            let inserted = old == nil
            try database.execute(
                sql: "INSERT INTO session_state (id, joined_via, joined_at, host) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO NOTHING",
                arguments: [sessionID, via.rawValue, at, core?.host.rawValue ?? HostID.local.rawValue])
            let oldAgent: String? = old?["agent"]
            let oldPath: String? = old?["transcript_path"]
            let hintChanged = (agent != nil && agent?.rawValue != oldAgent) ||
                (transcriptPath != nil && transcriptPath?.path != oldPath)
            if hintChanged {
                try database.execute(sql: "UPDATE session_state SET agent = COALESCE(?, agent), transcript_path = COALESCE(?, transcript_path) WHERE id = ?",
                                     arguments: [agent?.rawValue, transcriptPath?.path, sessionID])
            }
            var coreChanged = false
            if let core {
                try database.execute(sql: """
                    UPDATE session_state SET
                        directory_source = CASE WHEN directory IS NULL AND ? IS NOT NULL THEN ? ELSE directory_source END,
                        directory = COALESCE(directory, ?), title = COALESCE(title, ?),
                        last_active_at = COALESCE(last_active_at, ?)
                    WHERE id = ? AND ((directory IS NULL AND ? IS NOT NULL)
                        OR (title IS NULL AND ? IS NOT NULL) OR (last_active_at IS NULL AND ? IS NOT NULL))
                    """, arguments: [core.directory, core.directorySource?.rawValue, core.directory,
                                       core.title, core.lastActiveAt, sessionID, core.directory, core.title, core.lastActiveAt])
                coreChanged = database.changesCount > 0
            }
            return (inserted || hintChanged, inserted || hintChanged || coreChanged)
        }
        if changed.join { committedJoin(sessionID, awaitingCreation: via == .created && agent == .claude && transcriptPath == nil) }
        if changed.row { committedRowChange(sessionID) }
    }

    /// Undo of an import: the one write that removes membership. It deletes
    /// the row only while the row still says nothing but how the session
    /// joined — imported, never pinned, named, colored, retitled, archived or
    /// opened since, and not in a restorable tab. Anything else and the row
    /// stays: it holds a decision the undo knows nothing about. A transcript
    /// title fill does not block undo: only generated_title records a retitle.
    /// Returns
    /// whether the row went. ADR-023's "first join is kept" is untouched; a
    /// row that is undone was never kept.
    @discardableResult
    public func leave(sessionID: String) throws -> Bool {
        let left = try db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM session_state
                    WHERE id = ? AND joined_via = ?
                      AND pinned = 0 AND archived = 0
                      AND custom_name IS NULL AND color IS NULL
                      AND generated_title IS NULL AND last_opened_at IS NULL
                      AND NOT EXISTS (SELECT 1 FROM open_tabs WHERE session_id = ?)
                    """,
                arguments: [sessionID, JoinedVia.imported.rawValue, sessionID]
            )
            return database.changesCount > 0
        }
        if left {
            committedLeave(sessionID)
            committedRowChange(sessionID)
        }
        return left
    }

    /// A session Temple created whose tab closed before anything was sent:
    /// the row goes only while it still says nothing beyond that creation —
    /// never pinned, named, colored or archived, in no restorable tab, and
    /// never given a transcript path. A terminal title alone does not keep it
    /// (an idle agent titles itself). The caller must also have a completed,
    /// fresh absence verdict for it. Returns whether it went.
    @discardableResult
    public func discardUnstartedCreation(sessionID: String) throws -> Bool {
        let left = try db.write { database in
            try database.execute(
                sql: """
                    DELETE FROM session_state
                    WHERE id = ? AND joined_via = ?
                      AND transcript_path IS NULL
                      AND pinned = 0 AND archived = 0
                      AND custom_name IS NULL AND color IS NULL
                      AND NOT EXISTS (SELECT 1 FROM open_tabs WHERE session_id = ?)
                    """,
                arguments: [sessionID, JoinedVia.created.rawValue, sessionID]
            )
            return database.changesCount > 0
        }
        if left {
            committedLeave(sessionID)
            committedRowChange(sessionID)
        }
        return left
    }

    /// Hints never insert membership or change provenance, and do not trigger a
    /// second resolution after the engine has already parsed this file.
    public func updateTranscriptHint(sessionID: String, agent: Agent, path: URL) throws {
        try updateTranscriptHint(sessionID: sessionID, agent: agent, locator: TranscriptLocator(localURL: path))
    }

    public func updateTranscriptHint(sessionID: String, agent: Agent, locator: TranscriptLocator) throws {
        let changed = try db.write { database in
            try database.execute(sql: "UPDATE session_state SET agent = ?, transcript_path = ? WHERE id = ? AND (agent IS NOT ? OR transcript_path IS NOT ?)",
                                 arguments: [agent.rawValue, locator.path, sessionID, agent.rawValue, locator.path])
            return database.changesCount > 0
        }
        if changed { committedRowChange(sessionID) }
    }

    public func recordOpened(sessionID: String, at: Date = Date()) throws {
        try updateState(sessionID) { database in
            try database.execute(sql: "UPDATE session_state SET last_opened_at = ? WHERE id = ? AND last_opened_at IS NOT ?",
                                 arguments: [at, sessionID, at])
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
                lastOpenedAt: row["last_opened_at"],
                joinedVia: (row["joined_via"] as String?).flatMap(JoinedVia.init(rawValue:)),
                joinedAt: row["joined_at"],
                agent: (row["agent"] as String?).flatMap(Agent.init(rawValue:)),
                transcriptPath: row["transcript_path"],
                host: HostID(rawValue: (row["host"] as String?) ?? ""), directory: row["directory"],
                directorySource: (row["directory_source"] as String?).flatMap(DirectorySource.init(rawValue:)),
                title: row["title"], lastActiveAt: row["last_active_at"]
            )
        }
    }

    public func sessionStates(host: HostID? = nil) throws -> [SessionState] {
        try db.read { database in
            // templectl's read-only watch can inspect a pre-v10 database without
            // migrating it. Its rows are local and have no core facts yet.
            let hasHost = try database.columns(in: "session_state").contains { $0.name == "host" }
            if !hasHost, let host, !host.isLocal { return [] }
            let sql = hasHost && host != nil
                ? "SELECT * FROM session_state WHERE host = ? ORDER BY id"
                : "SELECT * FROM session_state ORDER BY id"
            let arguments: StatementArguments = hasHost && host != nil ? [host!.rawValue] : []
            return try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
                SessionState(
                    id: row["id"],
                    pinned: row["pinned"],
                    archived: row["archived"],
                    customName: row["custom_name"],
                    color: row["color"],
                    generatedTitle: row["generated_title"],
                    lastOpenedAt: row["last_opened_at"],
                    joinedVia: (row["joined_via"] as String?).flatMap(JoinedVia.init(rawValue:)),
                    joinedAt: row["joined_at"],
                    agent: (row["agent"] as String?).flatMap(Agent.init(rawValue:)),
                    transcriptPath: row["transcript_path"],
                    host: HostID(rawValue: (row["host"] as String?) ?? ""), directory: row["directory"],
                    directorySource: (row["directory_source"] as String?).flatMap(DirectorySource.init(rawValue:)),
                    title: row["title"], lastActiveAt: row["last_active_at"]
                )
            }
        }
    }

    /// Actual launch observations replace even a previous tab's directory.
    public func observeLaunchDirectory(sessionID: String, _ directory: String) throws {
        let result = try db.write { database -> (changed: Bool, priorDirectory: String?) in
            let prior = try String.fetchOne(database, sql: "SELECT directory FROM session_state WHERE id = ?", arguments: [sessionID])
            try database.execute(sql: "UPDATE session_state SET directory = ?, directory_source = 'tab' WHERE id = ? AND (directory IS NOT ? OR directory_source IS NOT 'tab')",
                                 arguments: [directory, sessionID, directory])
            return (database.changesCount > 0, prior)
        }
        if result.changed {
            if let prior = result.priorDirectory, prior != directory {
                TempleCoreLog.db.notice("launch directory replaced for \(sessionID, privacy: .public): \(prior, privacy: .public) → \(directory, privacy: .public)")
            }
            committedRowChange(sessionID)
        }
    }

    /// Transcript facts fill NULLs only. Does not insert membership or dual-write
    /// generated_title, so a titled import can still be undone. The host is checked
    /// in the transaction: queued facts cannot fill a row rejoined on another host.
    @discardableResult
    public func fillCoreFields(sessionID: String, expectedHost: HostID = .local, agent: Agent? = nil, directory: String? = nil,
                               title: String? = nil, lastActiveAt: Date? = nil) throws -> Set<SessionCoreField> {
        let changed = try db.write { database -> Set<SessionCoreField> in
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM session_state WHERE id = ? AND host = ?", arguments: [sessionID, expectedHost.rawValue]) else { return [] }
            var fields: Set<SessionCoreField> = []
            if (row["agent"] as String?) == nil && agent != nil { fields.insert(.agent) }
            if (row["directory"] as String?) == nil && directory != nil { fields.insert(.directory) }
            if (row["title"] as String?) == nil && title != nil { fields.insert(.title) }
            if (row["last_active_at"] as Date?) == nil && lastActiveAt != nil { fields.insert(.lastActiveAt) }
            guard !fields.isEmpty else { return [] }
            try database.execute(sql: """
                UPDATE session_state SET agent = COALESCE(agent, ?),
                    directory_source = CASE WHEN directory IS NULL AND ? IS NOT NULL THEN 'transcript' ELSE directory_source END,
                    directory = COALESCE(directory, ?), title = COALESCE(title, ?),
                    last_active_at = COALESCE(last_active_at, ?) WHERE id = ? AND host = ?
                """, arguments: [agent?.rawValue, directory, directory, title, lastActiveAt, sessionID, expectedHost.rawValue])
            return fields
        }
        if !changed.isEmpty { committedRowChange(sessionID) }
        return changed
    }

    public func touch(sessionID: String, at: Date = Date()) throws {
        let changed = try db.write { database in
            try database.execute(sql: "UPDATE session_state SET last_active_at = MAX(COALESCE(last_active_at, ?), ?) WHERE id = ? AND (last_active_at IS NULL OR last_active_at < ?)",
                                 arguments: [at, at, sessionID, at])
            return database.changesCount > 0
        }
        if changed { committedRowChange(sessionID) }
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

    /// Setters can create membership. Insert and update commit together so a
    /// failed update neither leaves an empty row nor sends a premature callback.
    /// The update's predicate must exclude unchanged values.
    private func updateState(_ sessionID: String, _ update: (Database) throws -> Void) throws {
        let result = try db.write { database in
            try database.execute(sql: "INSERT OR IGNORE INTO session_state (id) VALUES (?)", arguments: [sessionID])
            let inserted = database.changesCount > 0
            try update(database)
            return (inserted: inserted, changed: inserted || database.changesCount > 0)
        }
        if result.inserted { committedJoin(sessionID) }
        if result.changed { committedRowChange(sessionID) }
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
        // No backfill: nothing Temple kept before says whether it started a
        // session or resumed one, so existing rows stay unknown.
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
        migrator.registerMigration("v10-session-core") { database in
            try database.alter(table: "session_state") { table in
                table.add(column: "host", .text).notNull().defaults(to: "")
                table.add(column: "directory", .text)
                table.add(column: "directory_source", .text)
                table.add(column: "title", .text)
                table.add(column: "last_active_at", .datetime)
            }
            try database.execute(sql: "UPDATE session_state SET title = generated_title WHERE title IS NULL")
        }
        return migrator
    }
}
