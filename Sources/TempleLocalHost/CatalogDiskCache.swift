import Foundation
import GRDB
import TempleCore

/// The catalog's kept summaries on disk (ADR-032): `history-catalog-cache
/// .sqlite` in the state directory, so the first History read after a
/// relaunch reparses only what changed while Temple was not running.
///
/// It is a cache and nothing else. It holds summaries of transcripts for
/// browsing, each with the stamp its read saw; every one is checked against
/// a fresh `lstat` before use, exactly like one kept in memory. It holds no
/// membership, is never read by anything but the catalog, and never
/// populates `session_state`. Deleting it at any moment loses nothing but
/// time. So: a file that cannot be opened or read, or that was written by
/// an older layout or older parsers, is deleted and started over; one
/// written by a newer build is left alone (that build is using it) and this
/// process keeps its summaries in memory only. Writes are batched per
/// catalog read, only for what changed, never on a timer.
final class CatalogDiskCache: @unchecked Sendable {
    /// The table layout. Bump with any change to the tables, or to the
    /// fields of `TranscriptSummary` (`CatalogCacheTests` counts them).
    static let schemaVersion = 1
    static let fileName = "history-catalog-cache.sqlite"

    struct Changes: Sendable {
        var roots: [Agent: CatalogRoot]
        /// Per agent and key: an upsert, or nil for a delete.
        var files: [Agent: [String: CatalogSummaryCache.Entry?]]
    }

    let url: URL
    private let host: HostID
    private let queue = DispatchQueue(label: "com.sriramb.temple.catalog-disk-cache", qos: .utility)
    /// Opened on the queue, on first use; nil once the file proved unusable.
    private var database: DatabaseQueue?
    private var state: State = .unopened
    private enum State { case unopened, open, disabled }

    init(url: URL, host: HostID = .local) {
        self.url = url
        self.host = host
    }

    /// The default file, in `TempleState.directory` (so `TEMPLE_STATE_DIR`
    /// and test processes never reach the real one).
    static var defaultURL: URL { TempleState.directory.appendingPathComponent(fileName) }

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
                          let entry = Self.entry(row, agent: agent, host: host) else { continue }
                    result[agent]?.files[row["key"]] = entry
                }
                return result
            }
        } catch {
            LocalHostLog.catalog.error("catalog cache unreadable, starting over: \(String(describing: error), privacy: .public)")
            resetNow()
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
            LocalHostLog.catalog.error("catalog cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Opening

    private func openNow() -> DatabaseQueue? {
        switch state {
        case .open: return database
        case .disabled: return nil
        case .unopened: break
        }
        do {
            // Nil: a newer build's file, left alone (`open` disabled us).
            guard let database = try open() else { return nil }
            self.database = database; state = .open
            return database
        } catch {
            // Unopenable or of an older layout: a cache, so start over, once.
            resetNow()
            return database
        }
    }

    /// Deletes the file and opens a fresh one; on failure, memory only.
    private func resetNow() {
        database = nil
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        if let fresh = try? open() {
            database = fresh; state = .open
        } else {
            LocalHostLog.catalog.error("catalog cache cannot be created; keeping summaries in memory only")
            state = .disabled
        }
    }

    private enum OpenError: Error { case newer, older }

    private func open() throws -> DatabaseQueue? {
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        configuration.label = "history-catalog-cache"
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            try database.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                let stored = try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
                    .reduce(into: [String: String]()) { $0[$1["key"]] = $1["value"] }
                let mine = Self.meta(host: host)
                if stored.isEmpty {
                    try Self.createTables(db)
                    for (key, value) in mine {
                        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
                    }
                    return
                }
                guard stored != mine else { return }
                // A newer build's file is that build's: leave it be.
                let newer = ["schema", "facts"].contains { key in
                    (stored[key].flatMap(Int.init) ?? 0) > (mine[key].flatMap(Int.init) ?? 0)
                }
                throw newer ? OpenError.newer : OpenError.older
            }
        } catch OpenError.newer {
            LocalHostLog.catalog.notice("catalog cache written by a newer build; keeping summaries in memory only")
            state = .disabled
            return nil
        }
        return database
    }

    private static func meta(host: HostID) -> [String: String] {
        ["schema": String(schemaVersion), "facts": String(TranscriptFormats.factsVersion), "host": host.rawValue]
    }

    private static func createTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE roots (agent TEXT PRIMARY KEY, path TEXT NOT NULL, inode INTEGER NOT NULL);
            CREATE TABLE entries (
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

    private static func entry(_ row: Row, agent: Agent, host: HostID) -> CatalogSummaryCache.Entry? {
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
