import Foundation
import TempleCore

/// Explicit, on-demand disk history. No watcher and no membership; the
/// summaries it read are kept in a `CatalogSummaryCache` its source owns
/// (ADR-032), each reused only under the exact stamp it was read at.
struct LocalSessionCatalog: Sendable {
    private let stores: [any SessionStore]
    private let cache: CatalogSummaryCache?
    private let onParse: @Sendable () -> Void
    init(stores: [any SessionStore] = [ClaudeSessionStore(), CodexSessionStore()],
         cache: CatalogSummaryCache? = nil, onParse: @escaping @Sendable () -> Void = {}) {
        self.stores = stores
        self.cache = cache
        self.onParse = onParse
    }
    func load() -> [TranscriptSummary] {
        FileDescriptorLimit.ensureRaised()
        return stores.flatMap { $0.loadSummaries() }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// What a streamed read reports, in order: one `listed`, any number of
    /// `storeFailed` and `sessions`, then — when the read ran to its end —
    /// one `completed`, and the stream finishes.
    typealias Event = CatalogBatch

    /// The whole disk, newest first, a batch at a time — for a page that wants
    /// rows on screen before the last of ~4,000 logs is parsed. Files are
    /// ordered by modification time before any is opened (a stat each), so the
    /// first batch is the most recent work. Off the caller's thread; ending
    /// the consumer's iteration (or cancelling its task) stops the read at the
    /// next batch boundary.
    func stream(batchSize: Int = 200, newestFirst: Bool = true) -> AsyncStream<Event> {
        let stores = self.stores, cache = self.cache, onParse = self.onParse
        let size = max(1, batchSize)
        return AsyncStream { continuation in
            let cancelled = CatalogCancellation()
            continuation.onTermination = { _ in cancelled.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.read(stores, cache: cache, onParse: onParse, batchSize: size, newestFirst: newestFirst,
                          cancelled: cancelled) { continuation.yield($0) }
                // Whatever this read learned is kept, finished or not.
                cache?.flush()
                continuation.finish()
            }
        }
    }

    private struct Entry {
        let modified: Date
        let parse: @Sendable () -> TranscriptSummary?
    }

    private static func read(_ stores: [any SessionStore], cache: CatalogSummaryCache?, onParse: @escaping @Sendable () -> Void,
                             batchSize: Int, newestFirst: Bool, cancelled: CatalogCancellation, emit: (Event) -> Void) {
        FileDescriptorLimit.ensureRaised()
        // The disk cache loads while the stores are listed.
        cache?.startLoading()
        var entries: [Entry] = []
        // Listings that completed, with what they named: the cache forgets
        // the rest once every thread has been decided.
        var completed: [(agent: Agent, root: CatalogRoot?, listed: Set<String>)] = []
        for store in stores {
            if cancelled.isCancelled { return }
            guard let incremental = store as? any IncrementalSessionStore else {
                // A store that can only load wholesale still takes part; its
                // sessions arrive pre-parsed and sort in with the rest. Its
                // tolerant load cannot tell a failure from an empty store,
                // so it completes nothing.
                for session in store.loadSummaries() {
                    entries.append(Entry(modified: session.modifiedAt, parse: { session }))
                }
                continue
            }
            let files: [URL]
            var complete = true
            do {
                files = try incremental.enumerateSessionFiles()
            } catch is StoreRootMissing {
                // No store yet is nothing to list here, not a failure to
                // show — and not proof that anything is gone (ADR-030).
                files = []
                complete = false
            } catch {
                emit(.storeFailed(agent: store.agent, message: error.localizedDescription))
                continue
            }
            // One entry per thread, its file chosen before anything is
            // parsed (or looked up), by member resolution's own rule: a
            // thread never shows an older rollout while the one the agent
            // would resume exists.
            let urls = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let root = cache == nil ? nil : CatalogRoot(incremental.catalogRoot)
            if let cache, let root {
                cache.waitUntilLoaded()
                cache.begin(store.agent, root: root)
            }
            let pass = AgentPass(store: incremental, parser: incremental.catalogParser(),
                                 shared: incremental.sharedFactsSnapshot().facts,
                                 cache: root == nil ? nil : cache, root: root, onParse: onParse)
            for thread in TranscriptCandidates.catalogThreads(format: incremental.format, listed: Array(urls.keys)) {
                // Ordered by the file the pick reads first, not by the newest
                // of the thread's files: a rollout the pick passes over must
                // not pull its thread ahead of newer sessions. That stat is
                // also the first attempt's.
                let first = thread.paths.first.map(CatalogStamp.of)
                let modified: Date
                if case .present(let stamp) = first { modified = stamp.modifiedAt } else { modified = .distantPast }
                entries.append(Entry(modified: modified, parse: {
                    TranscriptCandidates.catalogPick(thread) { path in
                        guard let url = urls[path] else { return .missing }
                        return pass.attempt(url, thread: thread.threadID, stat: path == thread.paths.first ? first : nil)
                    }
                }))
            }
            if complete { completed.append((store.agent, root, Set(files.map { SessionPaths.normalized($0.path) }))) }
        }
        entries.sort { newestFirst ? $0.modified > $1.modified : $0.modified < $1.modified }
        let total = entries.count
        emit(.listed(total: total))

        var start = 0
        while start < total {
            if cancelled.isCancelled { return }
            let chunk = Array(entries[start..<min(start + batchSize, total)])
            let collector = TranscriptSummaryCollector()
            DispatchQueue.concurrentPerform(iterations: chunk.count) { index in
                if let session = chunk[index].parse() { collector.append(session) }
            }
            start += chunk.count
            let sessions = collector.result().sorted {
                $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : (newestFirst ? $0.modifiedAt > $1.modifiedAt : $0.modifiedAt < $1.modifiedAt)
            }
            if cancelled.isCancelled { return }
            emit(.sessions(sessions, read: start, total: total))
        }
        if cancelled.isCancelled { return }
        for listing in completed {
            if let cache, let root = listing.root { cache.complete(listing.agent, root: root, listed: listing.listed) }
        }
        emit(.completed(agents: Set(completed.map(\.agent))))
    }
}

extension LocalSessionCatalog {
    /// How often a file that changed while it was read is read again.
    static let readAttempts = 3

    /// One agent's part of a read: its store, parser, the shared facts every
    /// summary it emits carries, and its view of the cache.
    struct AgentPass: Sendable {
        let store: any IncrementalSessionStore
        let parser: @Sendable (URL) -> TranscriptSummary?
        let shared: SharedFacts
        /// Nil when nothing is kept for this agent (no cache, or a store
        /// whose root could not be identified).
        let cache: CatalogSummaryCache?
        let root: CatalogRoot?
        let onParse: @Sendable () -> Void

        var agent: Agent { store.agent }
        var format: any TranscriptFormat { store.format }

        /// One of a thread's files. A kept outcome is the answer when the
        /// file's stamp now is the one it was read at; otherwise the file is
        /// read the way the engine reads a member's: the identity the file
        /// records is verified first, then its facts are parsed, and both
        /// must come from one version of the file (stamped before and
        /// after, change time included). A file's name is not its identity:
        /// Claude's facts take the session id from the file name, so
        /// `a.jsonl` recording session `b` would otherwise list — and import
        /// — as `a`, with `b`'s folder and title. A file whose recorded
        /// identity is another session's, or that records none, yields
        /// nothing for the thread, and nothing kept for it survives.
        func attempt(_ url: URL, thread: String, stat known: CatalogStamp.Stat?) -> TranscriptCandidates.CatalogAttempt<TranscriptSummary> {
            let key = SessionPaths.normalized(url.path)
            if let cache, let root, case .present(let stamp) = known ?? CatalogStamp.of(url.path),
               let kept = cache.lookup(agent, root: root, key: key, stamp: stamp) {
                switch kept {
                case .summary(let summary) where summary.id == thread && summary.locator.path == url.path:
                    return .read(format.withShared(summary, shared))
                case .noSession:
                    return .failed
                case .summary:
                    break // kept under another spelling or thread: read it again
                }
            }
            let (result, kept) = read(url, thread: thread, key: key)
            if !kept, let cache { cache.forget(agent, key: key) }
            return result
        }

        /// The read, and whether its outcome was kept (anything else forgets
        /// what was kept for the file).
        private func read(_ url: URL, thread: String, key: String)
            -> (TranscriptCandidates.CatalogAttempt<TranscriptSummary>, kept: Bool) {
            func gone() -> TranscriptCandidates.CatalogAttempt<TranscriptSummary> {
                LocalSessionCatalog.isGone(url) ? .missing : .failed
            }
            func stamp() -> CatalogStamp? {
                if case .present(let stamp) = CatalogStamp.of(url.path) { return stamp }
                return nil
            }
            for _ in 0..<LocalSessionCatalog.readAttempts {
                guard let before = stamp() else { return (gone(), false) }
                let verdict: TranscriptVerification
                do { verdict = try store.verifyIdentity(at: url, expectedID: thread) }
                catch { return (LocalSessionSource.isMissing(error) ? .missing : gone(), false) }
                guard verdict == .verified else { return (.failed, false) }
                onParse()
                guard let parsed = parser(url) else {
                    if LocalSessionCatalog.isGone(url) { return (.missing, false) }
                    // Verified, and its bytes state no session (a Codex
                    // subagent rollout): kept as such, so it is not
                    // reparsed every refresh.
                    guard let cache, let root, stamp() == before else { return (.failed, false) }
                    cache.record(agent, root: root, key: key, entry: .init(stamp: before, outcome: .noSession))
                    return (.failed, true)
                }
                guard parsed.id == thread, let after = stamp() else { return (gone(), false) }
                guard after == before else { continue }
                let kept = format.withShared(parsed, .empty)
                if let cache, let root {
                    cache.record(agent, root: root, key: key, entry: .init(stamp: after, outcome: .summary(kept)))
                }
                return (.read(format.withShared(kept, shared)), true)
            }
            return (.failed, false)
        }
    }

    /// Only `ENOENT`/`ENOTDIR` prove a file gone; a file that cannot be
    /// read or stat'ed for any other reason still exists as far as anyone
    /// knows.
    static func isGone(_ url: URL) -> Bool {
        var info = stat()
        if stat(url.path, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}

private final class CatalogCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}
