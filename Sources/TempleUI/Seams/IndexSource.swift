import Foundation
import TempleCore

/// Supplies the live session index to the UI (U5).
@MainActor
public protocol IndexSource: AnyObject {
    /// Emit the current index immediately, then on every change.
    func start(onUpdate: @escaping (SessionIndex) -> Void)
    func stop()
}

@MainActor
public final class WatcherIndexSource: IndexSource {
    private static let cacheSaveInterval = Duration.seconds(5)

    private let watcher: SessionWatcher
    private let cacheURL: URL
    private var task: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var pendingCacheIndex: SessionIndex?
    private var onUpdate: ((SessionIndex) -> Void)?
    private var observers: [UUID: (SessionIndex) -> Void] = [:]
    private var latestIndex: SessionIndex?

    public init(
        watcher: SessionWatcher = SessionWatcher(),
        cacheURL: URL = CachedIndexStore.defaultURL
    ) {
        self.watcher = watcher
        self.cacheURL = cacheURL
    }

    public func start(onUpdate: @escaping (SessionIndex) -> Void) {
        self.onUpdate = onUpdate
        startIfNeeded()
    }

    public func stop() {
        task?.cancel()
        task = nil
        cacheTask?.cancel()
        cacheTask = nil
        pendingCacheIndex = nil
        watcher.stop()
    }

    /// Adds a second consumer without installing another filesystem watcher.
    /// The latest index is replayed immediately when available.
    func observe(_ observer: @escaping (SessionIndex) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if let latestIndex { observer(latestIndex) }
        startIfNeeded()
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        let stream = watcher.start()
        task = Task { [weak self] in
            for await index in stream {
                guard !Task.isCancelled, let self else { break }
                self.latestIndex = index
                self.onUpdate?(index)
                for observer in Array(self.observers.values) {
                    observer(index)
                }
                self.scheduleCacheSave(index)
            }
        }
    }

    /// Coalesces watcher snapshots and keeps JSON encoding and disk I/O away
    /// from the main actor that delivers sidebar updates.
    private func scheduleCacheSave(_ index: SessionIndex) {
        pendingCacheIndex = index
        guard cacheTask == nil else { return }
        cacheTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.cacheSaveInterval)
            } catch {
                return
            }
            guard let self, let index = self.pendingCacheIndex else { return }
            self.pendingCacheIndex = nil
            let cacheURL = self.cacheURL
            await Task.detached(priority: .utility) {
                try? CachedIndexStore.save(index, to: cacheURL)
            }.value
            self.cacheTask = nil
            if let pending = self.pendingCacheIndex {
                self.scheduleCacheSave(pending)
            }
        }
    }
}
