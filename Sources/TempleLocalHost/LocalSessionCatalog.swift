import Foundation
import TempleCore

/// Explicit, on-demand disk history. No watcher, membership, or retained cache.
struct LocalSessionCatalog: Sendable {
    private let stores: [any SessionStore]
    init(stores: [any SessionStore] = [ClaudeSessionStore(), CodexSessionStore()]) {
        self.stores = stores
    }
    func load() -> [TranscriptSummary] {
        FileDescriptorLimit.ensureRaised()
        return stores.flatMap { $0.loadSummaries() }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// What a streamed read reports, in order: one `listed`, any number of
    /// `storeFailed` and `sessions`, then the stream finishes.
    typealias Event = CatalogBatch

    /// The whole disk, newest first, a batch at a time — for a page that wants
    /// rows on screen before the last of ~4,000 logs is parsed. Files are
    /// ordered by modification time before any is opened (a stat each), so the
    /// first batch is the most recent work. Off the caller's thread; ending
    /// the consumer's iteration (or cancelling its task) stops the read at the
    /// next batch boundary.
    func stream(batchSize: Int = 200, newestFirst: Bool = true) -> AsyncStream<Event> {
        let stores = self.stores
        let size = max(1, batchSize)
        return AsyncStream { continuation in
            let cancelled = CatalogCancellation()
            continuation.onTermination = { _ in cancelled.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.read(stores, batchSize: size, newestFirst: newestFirst, cancelled: cancelled) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    private struct Entry {
        let modified: Date
        let parse: @Sendable () -> TranscriptSummary?
    }

    private static func read(_ stores: [any SessionStore], batchSize: Int, newestFirst: Bool,
                             cancelled: CatalogCancellation, emit: (Event) -> Void) {
        FileDescriptorLimit.ensureRaised()
        var entries: [Entry] = []
        for store in stores {
            if cancelled.isCancelled { return }
            guard let incremental = store as? any IncrementalSessionStore else {
                // A store that can only load wholesale still takes part; its
                // sessions arrive pre-parsed and sort in with the rest.
                for session in store.loadSummaries() {
                    entries.append(Entry(modified: session.modifiedAt, parse: { session }))
                }
                continue
            }
            let files: [URL]
            do {
                files = try incremental.enumerateSessionFiles()
            } catch is StoreRootMissing {
                // No store yet is nothing to list here, not a failure to show.
                files = []
            } catch {
                emit(.storeFailed(agent: store.agent, message: error.localizedDescription))
                continue
            }
            // One entry per thread, its file chosen before anything is
            // parsed, by member resolution's own rule: a thread never shows
            // an older rollout while the one the agent would resume exists.
            let parser = incremental.catalogParser()
            let urls = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for thread in TranscriptCandidates.catalogThreads(format: incremental.format, listed: Array(urls.keys)) {
                // Ordered by the file the pick reads first, not by the newest
                // of the thread's files: a rollout the pick passes over must
                // not pull its thread ahead of newer sessions.
                let modified = thread.paths.first.flatMap { urls[$0] }.map(StoreIO.modificationDate) ?? .distantPast
                entries.append(Entry(modified: modified, parse: {
                    TranscriptCandidates.catalogPick(thread) { path in
                        guard let url = urls[path] else { return .missing }
                        return Self.attempt(url, thread: thread.threadID, store: incremental, parser: parser)
                    }
                }))
            }
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
    }
}

extension LocalSessionCatalog {
    /// How often a file that changed while it was read is read again.
    static let readAttempts = 3

    /// One of a thread's files, read the way the engine reads a member's: the
    /// identity the file records is verified first, then its facts are
    /// parsed, and both must come from one version of the file (stat'ed
    /// before and after). A file's name is not its identity: Claude's facts
    /// take the session id from the file name, so `a.jsonl` recording
    /// session `b` would otherwise list — and import — as `a`, with `b`'s
    /// folder and title. A file whose recorded identity is another session's,
    /// or that records none, yields nothing for the thread.
    static func attempt(_ url: URL, thread: String, store: any IncrementalSessionStore,
                        parser: (URL) -> TranscriptSummary?) -> TranscriptCandidates.CatalogAttempt<TranscriptSummary> {
        func failure(_ error: Error) -> TranscriptCandidates.CatalogAttempt<TranscriptSummary> {
            LocalSessionSource.isMissing(error) || isGone(url) ? .missing : .failed
        }
        for _ in 0..<readAttempts {
            let before: FileSignature
            do { before = try FileSignature(url) } catch { return failure(error) }
            let verdict: TranscriptVerification
            do { verdict = try store.verifyIdentity(at: url, expectedID: thread) } catch { return failure(error) }
            guard verdict == .verified else { return .failed }
            guard let summary = parser(url), summary.id == thread else { return isGone(url) ? .missing : .failed }
            let after: FileSignature
            do { after = try FileSignature(url) } catch { return failure(error) }
            if after == before { return .read(summary) }
        }
        return .failed
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
