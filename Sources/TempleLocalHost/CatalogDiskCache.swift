import Foundation
import GRDB
import TempleCore

/// The catalog's kept summaries on disk (ADR-032), in the state directory,
/// so the first History read after a relaunch reparses only what changed
/// while Temple was not running.
///
/// It is a cache and nothing else. It holds summaries of transcripts for
/// browsing, each with the stamp its read saw; every one is checked against
/// a fresh stamp before use, exactly like one kept in memory. It holds no
/// membership, is never read by anything but the catalog, and never
/// populates `session_state`. Losing it loses nothing but time.
///
/// More than one Temple can use it at once — the installed app beside a
/// dev build share the state directory — so nothing here ever deletes a
/// file another process may have open:
/// - The file name carries the table layout and the facts version
///   (`history-catalog-cache.s1-f1.sqlite`): a build with other parsers
///   uses another file, and never touches this one.
/// - Every process using the file holds a shared `flock` on its lock file
///   (`<file>.lock`) for as long as it has the file open.
/// - Contention of any kind — that lock unavailable, a busy or locked
///   database, a write that times out — makes this process keep its
///   summaries in memory for the rest of the run. Nothing is deleted.
/// - Only a file SQLite itself reports corrupt (`SQLITE_CORRUPT`,
///   `SQLITE_NOTADB`) is deleted and rebuilt, and only while this process
///   holds the lock file exclusively — that is, while no other process has
///   the file open. Otherwise memory only, and the file stays.
/// Writes are batched per catalog read, only for what changed, never on a
/// timer.
final class CatalogDiskCache: @unchecked Sendable {
    /// The table layout. Bump with any change to the tables, or to the
    /// fields of `TranscriptSummary` (`CatalogCacheTests` counts them).
    static let schemaVersion = 1

    static func fileName(schema: Int = schemaVersion, facts: Int = TranscriptFormats.factsVersion) -> String {
        "history-catalog-cache.s\(schema)-f\(facts).sqlite"
    }

    struct Changes: Sendable {
        var roots: [Agent: CatalogRoot]
        /// Per agent and key: an upsert, or nil for a delete.
        var files: [Agent: [String: CatalogSummaryCache.Entry?]]
    }

    let url: URL
    var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }
    private let host: HostID
    private let schema: Int
    private let facts: Int
    private let busyTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.sriramb.temple.catalog-disk-cache", qos: .utility)
    /// Opened on the queue, on first use; nil in memory-only mode.
    private var database: DatabaseQueue?
    private var lockDescriptor: Int32 = -1
    private var state: State = .unopened
    private enum State { case unopened, open, memoryOnly }

    init(directory: URL, host: HostID = .local, schema: Int = CatalogDiskCache.schemaVersion,
         facts: Int = TranscriptFormats.factsVersion, busyTimeout: TimeInterval = 0.5) {
        self.url = directory.appendingPathComponent(Self.fileName(schema: schema, facts: facts))
        self.host = host
        self.schema = schema
        self.facts = facts
        self.busyTimeout = busyTimeout
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    /// The default file, in `TempleState.directory` (so `TEMPLE_STATE_DIR`
    /// and test processes never reach the real one).
    static var defaultDirectory: URL { TempleState.directory }

    // MARK: Reading and writing (on the queue)

    func load(_ completion: @escaping @Sendable ([Agent: CatalogSummaryCache.AgentEntries]) -> Void) {
        queue.async {
            completion(self.loadNow())
        }
    }

    func write(_ changes: Changes) {
        queue.async { self.writeNow(changes) }
    }

    /// Runs after everything queued so far (tests, and the bench).
    func sync() { queue.sync {} }

    /// The disk is out of use for this run (tests).
    var isMemoryOnly: Bool { queue.sync { state == .memoryOnly } }

    /// Holds the queue until `gate` is signalled: a load that stalls (tests).
    func stallForTesting(until gate: DispatchSemaphore) { queue.async { gate.wait() } }

    private func loadNow() -> [Agent: CatalogSummaryCache.AgentEntries] {
        guard let database = openNow() else { return [:] }
        do {
            return try database.read { db in
                var result: [Agent: CatalogSummaryCache.AgentEntries] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT agent, path, inode FROM roots") {
                    guard let agent = Agent(rawValue: row["agent"]) else { continue }
                    let inode: Int64 = row["inode"]
                    result[agent] = .init(root: CatalogRoot(path: row["path"], inode: UInt64(bitPattern: inode)), files: [:])
                }
                let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM entries")
                while let row = try cursor.next() {
                    guard let agent = Agent(rawValue: row["agent"]), result[agent] != nil,
                          let entry = Self.entry(row, agent: agent) else { continue }
                    result[agent]?.files[row["key"]] = entry
                }
                return result
            }
        } catch {
            failed(error, during: "load")
            return [:]
        }
    }

    private func writeNow(_ changes: Changes) {
        guard let database = openNow() else { return }
        do {
            try database.write { db in
                for (agent, root) in changes.roots {
                    let stored = try Row.fetchOne(db, sql: "SELECT path, inode FROM roots WHERE agent = ?", arguments: [agent.rawValue])
                    let same = stored.map { $0["path"] as String == root.path && UInt64(bitPattern: $0["inode"] as Int64) == root.inode } ?? false
                    guard !same else { continue }
                    // Another root: nothing kept under the old one applies.
                    try db.execute(sql: "DELETE FROM entries WHERE agent = ?", arguments: [agent.rawValue])
                    try db.execute(sql: "INSERT OR REPLACE INTO roots (agent, path, inode) VALUES (?, ?, ?)",
                                   arguments: [agent.rawValue, root.path, Int64(bitPattern: root.inode)])
                }
                for (agent, files) in changes.files {
                    for (key, entry) in files {
                        if let entry {
                            try Self.upsert(db, agent: agent, key: key, entry: entry)
                        } else {
                            try db.execute(sql: "DELETE FROM entries WHERE agent = ? AND key = ?", arguments: [agent.rawValue, key])
                        }
                    }
                }
            }
        } catch {
            failed(error, during: "write")
        }
    }

    /// Anything that went wrong with an open file: memory only from now on,
    /// and — only when SQLite says the file is corrupt and nobody else has
    /// it open — the file is rebuilt first.
    private func failed(_ error: Error, during operation: String) {
        if Self.isCorruption(error), rebuildIfSole() {
            LocalHostLog.catalog.notice("catalog cache was corrupt during \(operation, privacy: .public); rebuilt")
            return
        }
        LocalHostLog.catalog.notice("catalog cache \(operation, privacy: .public) failed, keeping summaries in memory: \(String(describing: error), privacy: .public)")
        goMemoryOnly()
    }

    // MARK: Opening

    private func openNow() -> DatabaseQueue? {
        switch state {
        case .open: return database
        case .memoryOnly: return nil
        case .unopened: break
        }
        // A shared hold on the lock file for as long as the file is open:
        // what lets a corrupt file be rebuilt only by its sole user.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lockDescriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            LocalHostLog.catalog.notice("catalog cache is being rebuilt by another process; keeping summaries in memory")
            goMemoryOnly()
            return nil
        }
        do {
            let opened = try openDatabase()
            database = opened; state = .open
            return opened
        } catch {
            if Self.isCorruption(error), rebuildIfSole() { return database }
            LocalHostLog.catalog.notice("catalog cache unavailable, keeping summaries in memory: \(String(describing: error), privacy: .public)")
            goMemoryOnly()
            return nil
        }
    }

    private func goMemoryOnly() {
        try? database?.close()
        database = nil
        state = .memoryOnly
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    /// Deletes and recreates a corrupt file, but only while no other
    /// process holds it (an exclusive lock on the lock file, without
    /// waiting); the shared hold is taken back afterwards. False when
    /// someone else has it, or the rebuild failed: then memory only.
    private func rebuildIfSole() -> Bool {
        try? database?.close()
        database = nil
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { if lockDescriptor >= 0 { _ = flock(lockDescriptor, LOCK_SH) } }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        guard let fresh = try? openDatabase() else { return false }
        database = fresh; state = .open
        return true
    }

    static func isCorruption(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    private struct MetaMismatch: Error {}

    private func openDatabase() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeout)
        configuration.label = "history-catalog-cache"
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        let mine = ["schema": String(schema), "facts": String(facts), "host": host.rawValue]
        // A file already set up is only read here: a reader elsewhere does
        // not keep this process from using it.
        let existing: [String: String]? = try database.read { db in
            guard try db.tableExists("meta"), try db.tableExists("roots"), try db.tableExists("entries") else { return nil }
            return try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
                .reduce(into: [String: String]()) { $0[$1["key"]] = $1["value"] }
        }
        if let existing, !existing.isEmpty {
            // The name says these versions; a file that says otherwise is
            // not ours to use, nor to delete.
            guard existing == mine else { throw MetaMismatch() }
            return database
        }
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS roots (agent TEXT PRIMARY KEY, path TEXT NOT NULL, inode INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS entries (
                    agent TEXT NOT NULL, key TEXT NOT NULL,
                    size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, ctime_ns INTEGER NOT NULL, inode INTEGER NOT NULL,
                    outcome INTEGER NOT NULL,
                    id TEXT, locator_path TEXT, modified_at REAL, cwd TEXT, first_prompt TEXT, created_at REAL,
                    git_branch TEXT, model TEXT, message_count INTEGER, last_message_preview TEXT, originator TEXT,
                    recorded_title TEXT, directory_hint TEXT, later_prompt_hint TEXT, legacy_title_hint TEXT,
                    selection_key TEXT,
                    PRIMARY KEY (agent, key)
                ) WITHOUT ROWID;
                """)
            let stored = try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
                .reduce(into: [String: String]()) { $0[$1["key"]] = $1["value"] }
            if stored.isEmpty {
                for (key, value) in mine {
                    try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
                }
            } else if stored != mine {
                // The name says these versions; a file that says otherwise
                // is not ours to use, nor to delete.
                throw MetaMismatch()
            }
        }
        return database
    }

    // MARK: Rows

    /// Every `TranscriptSummary` field but the shared ones (applied fresh on
    /// every use, never kept), its dates as their exact `Double`s.
    private static func upsert(_ db: Database, agent: Agent, key: String, entry: CatalogSummaryCache.Entry) throws {
        var arguments: StatementArguments = [agent.rawValue, key, entry.stamp.size, entry.stamp.modifiedNanos,
                                             entry.stamp.changedNanos, Int64(bitPattern: entry.stamp.inode)]
        switch entry.outcome {
        case .noSession:
            arguments += [1, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil] as StatementArguments
        case .summary(let s):
            arguments += [0, s.id, s.locator.path, s.modifiedAt.timeIntervalSinceReferenceDate, s.cwd, s.firstPrompt,
                          s.createdAt?.timeIntervalSinceReferenceDate, s.gitBranch, s.model, s.messageCount,
                          s.lastMessagePreview, s.originator, s.recordedTitle, s.directoryHint, s.laterPromptHint,
                          s.legacyTitleHint, s.selectionKey] as StatementArguments
        }
        try db.execute(sql: """
            INSERT OR REPLACE INTO entries (agent, key, size, mtime_ns, ctime_ns, inode, outcome,
                id, locator_path, modified_at, cwd, first_prompt, created_at, git_branch, model, message_count,
                last_message_preview, originator, recorded_title, directory_hint, later_prompt_hint,
                legacy_title_hint, selection_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: arguments)
    }

    private static func entry(_ row: Row, agent: Agent) -> CatalogSummaryCache.Entry? {
        let inode: Int64 = row["inode"]
        let stamp = CatalogStamp(size: row["size"], modifiedNanos: row["mtime_ns"], changedNanos: row["ctime_ns"],
                                 inode: UInt64(bitPattern: inode))
        let outcome: Int = row["outcome"]
        if outcome == 1 { return .init(stamp: stamp, outcome: .noSession) }
        guard outcome == 0, let id: String = row["id"], let path: String = row["locator_path"],
              let modified: Double = row["modified_at"] else { return nil }
        let created: Double? = row["created_at"]
        let summary = TranscriptSummary(
            id: id, agent: agent, locator: TranscriptLocator(localURL: URL(fileURLWithPath: path)),
            modifiedAt: Date(timeIntervalSinceReferenceDate: modified), cwd: row["cwd"], firstPrompt: row["first_prompt"],
            createdAt: created.map(Date.init(timeIntervalSinceReferenceDate:)), gitBranch: row["git_branch"],
            model: row["model"], messageCount: row["message_count"], lastMessagePreview: row["last_message_preview"],
            originator: row["originator"], recordedTitle: row["recorded_title"], directoryHint: row["directory_hint"],
            laterPromptHint: row["later_prompt_hint"], legacyTitleHint: row["legacy_title_hint"],
            selectionKey: row["selection_key"])
        return .init(stamp: stamp, outcome: .summary(summary))
    }
}
