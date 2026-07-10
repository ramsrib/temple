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
    private let watcher: SessionWatcher
    private var task: Task<Void, Never>?
    private var onUpdate: ((SessionIndex) -> Void)?
    private var observers: [UUID: (SessionIndex) -> Void] = [:]
    private var latestIndex: SessionIndex?

    public init(watcher: SessionWatcher = SessionWatcher()) {
        self.watcher = watcher
    }

    public func start(onUpdate: @escaping (SessionIndex) -> Void) {
        self.onUpdate = onUpdate
        startIfNeeded()
    }

    public func stop() {
        task?.cancel()
        task = nil
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
            }
        }
    }
}
