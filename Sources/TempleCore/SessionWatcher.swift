import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Maintains a live session index from filesystem changes.
///
/// Directory watches are installed recursively and refreshed whenever a watched
/// directory changes, so newly-created project/date directories are included.
public final class SessionWatcher: @unchecked Sendable {
    private let stores: [any SessionStore]
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.temple.session-watcher")

    // Accessed only on `queue`.
    private var continuation: AsyncStream<SessionIndex>.Continuation?
    private var sourcesByPath: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var sessionsByAgent: [Agent: [AgentSession]] = [:]
    private var cachesByAgent: [Agent: StoreCache] = [:]
    private var pendingAgents: Set<Agent> = []
    private var running = false

    public init(
        stores: [any SessionStore] = [ClaudeSessionStore(), CodexSessionStore()],
        debounceInterval: TimeInterval = 0.4
    ) {
        FileDescriptorLimit.ensureRaised()
        self.stores = stores
        self.debounceInterval = debounceInterval
    }

    /// Starts watching and immediately yields the current index.
    public func start() -> AsyncStream<SessionIndex> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.stop() }
            queue.async { [weak self] in
                guard let self else { return }
                self.stopLocked(finishStream: false)
                self.continuation = continuation
                self.running = true
                for store in self.stores {
                    let sessions = store.loadSessions()
                    self.sessionsByAgent[store.agent] = sessions
                    if let incremental = store as? any IncrementalSessionStore {
                        self.cachesByAgent[store.agent] = Self.makeCache(
                            store: incremental,
                            sessions: sessions
                        )
                    }
                }
                self.installWatchesLocked()
                continuation.yield(Self.makeIndex(self.sessionsByAgent.values.flatMap { $0 }))
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopLocked(finishStream: true) }
    }

    private func stopLocked(finishStream: Bool) {
        running = false
        debounceWork?.cancel()
        debounceWork = nil
        sourcesByPath.values.forEach { $0.cancel() }
        sourcesByPath.removeAll()
        if finishStream { continuation?.finish() }
        continuation = nil
        pendingAgents.removeAll()
        cachesByAgent.removeAll()
    }

    private func installWatchesLocked() {
        guard running else { return }

        var desiredTargets: [String: (url: URL, agent: Agent)] = [:]
        for store in stores {
            for url in store.watchedURLs {
                for target in watchTargets(for: url) {
                    desiredTargets[target.path] = (target, store.agent)
                }
            }
        }

        let removedPaths = sourcesByPath.keys.filter { desiredTargets[$0] == nil }
        for path in removedPaths {
            sourcesByPath.removeValue(forKey: path)?.cancel()
        }
        for (path, target) in desiredTargets where sourcesByPath[path] == nil {
            installWatchLocked(url: target.url, agent: target.agent)
        }
    }

    /// Watches existing directories recursively. For a missing file/root, its
    /// closest existing parent is watched so creation is detected.
    private func watchTargets(for url: URL) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return [url] }
            var result = [url]
            if let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let child as URL in enumerator {
                    let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    if isDirectory || child.pathExtension == "jsonl" {
                        result.append(child)
                    }
                }
            }
            return result
        }

        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !fm.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            parent.deleteLastPathComponent()
        }
        return fm.fileExists(atPath: parent.path) ? [parent] : []
    }

    private func installWatchLocked(url: URL, agent: Agent) {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.recordChangeLocked(for: agent) }
        source.setCancelHandler { close(descriptor) }
        sourcesByPath[url.path] = source
        source.resume()
        #endif
    }

    private func recordChangeLocked(for agent: Agent) {
        guard running else { return }
        pendingAgents.insert(agent)
        guard debounceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.debounceWork = nil
            self?.reloadPendingLocked()
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func reloadPendingLocked() {
        guard running, !pendingAgents.isEmpty else { return }
        let agents = pendingAgents
        pendingAgents.removeAll()
        for store in stores where agents.contains(store.agent) {
            if let incremental = store as? any IncrementalSessionStore {
                reloadIncrementallyLocked(incremental)
            } else {
                sessionsByAgent[store.agent] = store.loadSessions()
            }
        }
        continuation?.yield(Self.makeIndex(sessionsByAgent.values.flatMap { $0 }))
        installWatchesLocked()
    }

    private func reloadIncrementallyLocked(_ store: any IncrementalSessionStore) {
        guard var cache = cachesByAgent[store.agent],
              cache.invalidationToken == store.cacheInvalidationToken else {
            let sessions = store.loadSessions()
            sessionsByAgent[store.agent] = sessions
            cachesByAgent[store.agent] = Self.makeCache(store: store, sessions: sessions)
            return
        }

        var updated: [String: CacheEntry] = [:]
        var parsedMidWrite = false
        for file in store.sessionFileURLs() {
            let path = file.path
            guard let signature = FileSignature(file) else { continue }
            if let existing = cache.entries[path], existing.signature == signature {
                updated[path] = existing
                continue
            }

            let session = store.loadSession(at: file)
            // Cache under the PRE-parse signature: if the file was written while
            // we read it (a freshly-created session streaming in is the common
            // case), the next event must re-parse. Caching the post-parse
            // signature here used to pin the incomplete parse forever — a brand
            // new session stayed missing/noise until app restart.
            updated[path] = CacheEntry(signature: signature, session: session)
            if let finalSignature = FileSignature(file), finalSignature != signature {
                parsedMidWrite = true
            }
        }
        cache.entries = updated
        cachesByAgent[store.agent] = cache
        sessionsByAgent[store.agent] = updated.values.compactMap(\.session)
        if parsedMidWrite {
            // Belt and braces: guarantee a follow-up pass even if the writer's
            // last event was coalesced into the reload we just did.
            recordChangeLocked(for: store.agent)
        }
    }

    private static func makeCache(
        store: any IncrementalSessionStore,
        sessions: [AgentSession]
    ) -> StoreCache {
        let sessionsByPath = Dictionary(sessions.map { ($0.filePath.path, $0) },
                                        uniquingKeysWith: { first, _ in first })
        var entries: [String: CacheEntry] = [:]
        for file in store.sessionFileURLs() {
            guard let signature = FileSignature(file) else { continue }
            entries[file.path] = CacheEntry(
                signature: signature,
                session: sessionsByPath[file.path]
            )
        }
        return StoreCache(invalidationToken: store.cacheInvalidationToken, entries: entries)
    }

    private static func makeIndex(_ sessions: [AgentSession]) -> SessionIndex {
        let grouped = Dictionary(grouping: sessions, by: \.projectPath)
        let projects = grouped.map { path, sessions in
            Project(path: path, sessions: sessions.sorted { $0.updatedAt > $1.updatedAt })
        }.sorted { $0.lastActivity > $1.lastActivity }
        return SessionIndex(projects: projects)
    }
}

private struct FileSignature: Equatable {
    let modificationDate: Date
    let fileSize: Int

    init?(_ url: URL) {
        // FileManager attributes, NOT URL.resourceValues — the latter caches
        // per URL instance, so restatting the same URL after a parse returned
        // stale values and mid-write races went undetected.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        modificationDate = date
        fileSize = size
    }
}

private struct CacheEntry {
    let signature: FileSignature
    let session: AgentSession?
}

private struct StoreCache {
    let invalidationToken: String?
    var entries: [String: CacheEntry]
}
