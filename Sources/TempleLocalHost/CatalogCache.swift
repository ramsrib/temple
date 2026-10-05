import Foundation
import TempleCore

/// What one `lstat(2)` says about a transcript, for the catalog's cache:
/// size, modification and change times to the nanosecond, and the inode.
///
/// The change time is what makes a kept summary safe to reuse. It moves on
/// every write, truncation, chmod, rename onto the path and timestamp change,
/// and no ordinary process can set it: a rewrite that keeps the size and the
/// inode and then puts the old modification time back (`touch -m -t`, a
/// restore tool) still moves it. What a stamp cannot see is a change made
/// with the system clock set back to the old change time (root only), or a
/// filesystem that reports no change time — then size, mtime and inode are
/// all there is, and a same-size in-place rewrite within the mtime's
/// resolution goes unseen until the next write. Not the device: it is not
/// stable across reboots for every volume, and a cache that misses after
/// each reboot would be no cache.
struct CatalogStamp: Hashable, Sendable {
    let size: Int64
    let modifiedNanos: Int64
    let changedNanos: Int64
    let inode: UInt64

    init(size: Int64, modifiedNanos: Int64, changedNanos: Int64, inode: UInt64) {
        self.size = size; self.modifiedNanos = modifiedNanos; self.changedNanos = changedNanos; self.inode = inode
    }

    init(_ info: stat) {
        size = Int64(info.st_size)
        modifiedNanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        changedNanos = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
        inode = UInt64(info.st_ino)
    }

    /// The modification time as `FileSignature` reads it (for ordering only).
    var modifiedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedNanos / 1_000_000_000) + TimeInterval(modifiedNanos % 1_000_000_000) / 1_000_000_000)
    }

    enum Stat: Equatable {
        case present(CatalogStamp)
        /// `ENOENT`/`ENOTDIR`: the file is provably gone.
        case missing
        /// Any other failure: the file may well exist.
        case failed
    }

    static func of(_ path: String) -> Stat {
        var info = stat()
        if lstat(path, &info) == 0 { return .present(CatalogStamp(info)) }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .failed
    }
}

/// Which directory an agent's store is, for the cache: its path and the
/// inode of what that path resolves to. A store root replaced by another
/// directory (a moved store, another volume mounted at the path, a
/// `TEMPLE_*_ROOT` pointed elsewhere) is another root, and every summary
/// kept for the old one goes.
struct CatalogRoot: Hashable, Sendable {
    let path: String
    let inode: UInt64

    init(path: String, inode: UInt64) { self.path = path; self.inode = inode }

    init?(_ url: URL?) {
        guard let url else { return nil }
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        path = SessionPaths.normalized(url.path)
        inode = UInt64(info.st_ino)
    }
}

/// The local catalog's kept summaries (ADR-032), one per transcript the
/// catalog has read: what the read found and the stamp it started and ended
/// with. Owned by `LocalSessionSource`, so it outlives any one History tab;
/// optionally backed by `CatalogDiskCache`, so it outlives the process.
///
/// What is kept and what is not:
/// - Only reads whose identity verified and whose stamps before and after
///   agreed. An unreadable, mismatched or incomplete file keeps nothing —
///   and loses whatever was kept for it — so it is read again every time.
/// - Summaries without their shared-input fields (`TranscriptFormat
///   .withShared(_, .empty)`): those are applied fresh on every use, so a
///   change to Codex's history.jsonl costs no transcript read.
/// - A verified file whose bytes state no session (a Codex subagent
///   rollout) is kept as `noSession`, so it is not reparsed every refresh.
///
/// Nothing here is consulted to decide which file is a thread's: the
/// catalog picks first (`TranscriptCandidates`), then looks up the picked
/// path under the stamp it just took. Nothing here is membership, or ever
/// reaches `session_state`.
final class CatalogSummaryCache: @unchecked Sendable {
    enum Outcome: Hashable, Sendable {
        /// Shared-input fields stripped.
        case summary(TranscriptSummary)
        case noSession
    }

    struct Entry: Hashable, Sendable {
        let stamp: CatalogStamp
        let outcome: Outcome
    }

    /// Everything kept for one agent, under the root it was read from.
    struct AgentEntries: Sendable, Equatable {
        var root: CatalogRoot
        var files: [String: Entry]
    }

    private let lock = NSLock()
    private var agents: [Agent: AgentEntries] = [:]
    /// Changes not yet on disk, per agent: an upsert, or nil for a delete.
    private var pending: [Agent: [String: Entry?]] = [:]
    /// Agents whose root is to be written (the disk drops every row kept
    /// under another root when it is).
    private var pendingRoots: Set<Agent> = []
    private let disk: CatalogDiskCache?
    private var loadStarted = false
    private let loaded = DispatchGroup()

    init(disk: CatalogDiskCache? = nil) {
        self.disk = disk
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    // MARK: Disk

    /// Starts reading the disk cache, once, off the caller's thread.
    func startLoading() {
        guard let disk else { return }
        let start: Bool = locked {
            guard !loadStarted else { return false }
            loadStarted = true
            loaded.enter()
            return true
        }
        guard start else { return }
        // Held until the load lands: a group released while entered traps.
        disk.load { snapshot in
            self.merge(snapshot)
            self.loaded.leave()
        }
    }

    /// Blocks until the disk cache is in memory, or `timeout` passes; a
    /// cache that is slow to load is read without, never waited on forever.
    func waitUntilLoaded(timeout: TimeInterval = 5) {
        let started = locked { loadStarted }
        guard started else { return }
        _ = loaded.wait(timeout: .now() + timeout)
    }

    /// Entries from disk fill only what memory does not already know: what
    /// this process read, or decided to forget, is newer.
    private func merge(_ snapshot: [Agent: AgentEntries]) {
        locked {
            for (agent, stored) in snapshot {
                if let current = agents[agent] {
                    guard current.root == stored.root else { continue }
                    var files = current.files
                    let decided = pending[agent] ?? [:]
                    for (key, entry) in stored.files where files[key] == nil && decided.index(forKey: key) == nil {
                        files[key] = entry
                    }
                    agents[agent]?.files = files
                } else {
                    agents[agent] = stored
                }
            }
        }
    }

    /// Writes what changed since the last flush, off the caller's thread. An
    /// unchanged refresh writes nothing.
    func flush() {
        guard let disk else { return }
        let changes: CatalogDiskCache.Changes? = locked {
            guard !pending.isEmpty || !pendingRoots.isEmpty else { return nil }
            var roots: [Agent: CatalogRoot] = [:]
            for agent in Set(pending.keys).union(pendingRoots) { roots[agent] = agents[agent]?.root }
            let changes = CatalogDiskCache.Changes(roots: roots, files: pending)
            pending = [:]; pendingRoots = []
            return changes
        }
        if let changes { disk.write(changes) }
    }

    // MARK: Use

    /// The agent's store is at `root` for this read. A different root than
    /// the one entries were kept under drops them all (on disk too, when the
    /// new root is written). Called after `waitUntilLoaded`, so what the
    /// disk kept is already here to compare.
    func begin(_ agent: Agent, root: CatalogRoot) {
        locked {
            guard agents[agent]?.root != root else { return }
            agents[agent] = AgentEntries(root: root, files: [:])
            pending[agent] = nil
            pendingRoots.insert(agent)
        }
    }

    /// The kept outcome for `key`, when it was read under this root at
    /// exactly this stamp.
    func lookup(_ agent: Agent, root: CatalogRoot, key: String, stamp: CatalogStamp) -> Outcome? {
        locked {
            guard let kept = agents[agent], kept.root == root, let entry = kept.files[key], entry.stamp == stamp else { return nil }
            return entry.outcome
        }
    }

    func record(_ agent: Agent, root: CatalogRoot, key: String, entry: Entry) {
        locked {
            guard agents[agent]?.root == root else { return }
            guard agents[agent]?.files[key] != entry else { return }
            agents[agent]?.files[key] = entry
            pending[agent, default: [:]][key] = .some(entry)
        }
    }

    func forget(_ agent: Agent, key: String) {
        locked {
            guard agents[agent]?.files.removeValue(forKey: key) != nil else { return }
            pending[agent, default: [:]][key] = .some(nil)
        }
    }

    /// The agent's listing under `root` completed: anything kept for a path
    /// it did not name is gone from the store.
    func complete(_ agent: Agent, root: CatalogRoot, listed: Set<String>) {
        locked {
            guard let kept = agents[agent], kept.root == root else { return }
            for key in kept.files.keys where !listed.contains(key) {
                agents[agent]?.files.removeValue(forKey: key)
                pending[agent, default: [:]][key] = .some(nil)
            }
        }
    }

    /// What is kept, for tests and the disk writer.
    var snapshot: [Agent: AgentEntries] { locked { agents } }
    var count: Int { locked { agents.values.reduce(0) { $0 + $1.files.count } } }
}
