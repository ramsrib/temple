import Foundation

/// Explicit, on-demand disk history. No watcher, membership, or retained cache.
public struct SessionCatalog: Sendable {
    private let stores: [any SessionStore]
    public init(stores: [any SessionStore] = [ClaudeSessionStore(), CodexSessionStore()]) {
        self.stores = stores
    }
    public func load() -> [TranscriptSummary] {
        FileDescriptorLimit.ensureRaised()
        return stores.flatMap { $0.loadSummaries() }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// What a streamed read reports, in order: one `listed`, any number of
    /// `storeFailed` and `sessions`, then the stream finishes.
    public enum Event: Sendable, Equatable {
        /// Every store has been listed. `total` counts session FILES, an upper
        /// bound on sessions: a file that turns out not to be one is skipped.
        case listed(total: Int)
        /// A store could not be listed; its sessions are missing from this
        /// read. `message` is the error as thrown, never a diagnosis.
        case storeFailed(Agent, message: String)
        /// Parsed sessions, newest file first within and across batches.
        /// `read` counts the files consumed so far, out of `total`.
        case sessions([TranscriptSummary], read: Int, total: Int)
    }

    /// The whole disk, newest first, a batch at a time — for a page that wants
    /// rows on screen before the last of ~4,000 logs is parsed. Files are
    /// ordered by modification time before any is opened (a stat each), so the
    /// first batch is the most recent work. Off the caller's thread; ending
    /// the consumer's iteration (or cancelling its task) stops the read at the
    /// next batch boundary.
    public func stream(batchSize: Int = 200) -> AsyncStream<Event> {
        let stores = self.stores
        let size = max(1, batchSize)
        return AsyncStream { continuation in
            let cancelled = CatalogCancellation()
            continuation.onTermination = { _ in cancelled.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.read(stores, batchSize: size, cancelled: cancelled) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    private struct Entry {
        let url: URL?
        let modified: Date
        let parse: @Sendable () -> TranscriptSummary?
    }

    private static func read(_ stores: [any SessionStore], batchSize: Int,
                             cancelled: CatalogCancellation, emit: (Event) -> Void) {
        FileDescriptorLimit.ensureRaised()
        var entries: [Entry] = []
        for store in stores {
            if cancelled.isCancelled { return }
            guard let incremental = store as? any IncrementalSessionStore else {
                // A store that can only load wholesale still takes part; its
                // sessions arrive pre-parsed and sort in with the rest.
                for session in store.loadSummaries() {
                    entries.append(Entry(url: nil, modified: session.modifiedAt, parse: { session }))
                }
                continue
            }
            let files: [URL]
            do {
                files = try incremental.enumerateSessionFiles()
            } catch {
                emit(.storeFailed(store.agent, message: error.localizedDescription))
                continue
            }
            let parser = incremental.catalogParser()
            for url in files {
                entries.append(Entry(url: url, modified: StoreIO.modificationDate(url),
                                     parse: { parser(url) }))
            }
        }
        entries.sort { $0.modified > $1.modified }
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
                $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt
            }
            if cancelled.isCancelled { return }
            emit(.sessions(sessions, read: start, total: total))
        }
    }
}

private final class CatalogCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}
