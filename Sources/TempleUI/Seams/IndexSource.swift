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

    let watcher: SessionWatcher
    private var task: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var latestSnapshot: EngineSnapshot?
    var onSnapshotUpdate: ((EngineSnapshot) -> Void)? {
        didSet { if let latestSnapshot { onSnapshotUpdate?(latestSnapshot) } }
    }
    private var latestResolutions: [String: MemberResolution]?
    var onResolutionUpdate: (([String: MemberResolution]) -> Void)? {
        didSet {
            if let latestResolutions { onResolutionUpdate?(latestResolutions) }
        }
    }
    private var onUpdate: ((SessionIndex) -> Void)?
    private var observers: [UUID: (SessionIndex) -> Void] = [:]
    private var latestIndex: SessionIndex?

    public init(watcher: SessionWatcher = SessionWatcher()) {
        self.watcher = watcher
    }

    public func start(onUpdate: @escaping (SessionIndex) -> Void) {
        self.onUpdate = onUpdate
        if let latestIndex { onUpdate(latestIndex) }
        startIfNeeded()
    }

    public func stop() {
        task?.cancel()
        task = nil
        latestSnapshot = nil; latestIndex = nil; latestResolutions = nil; onUpdate = nil
        snapshotTask?.cancel(); snapshotTask = nil
        resolutionTask?.cancel(); resolutionTask = nil
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

    func startEngineIfNeeded() { startIfNeeded() }

    private func startIfNeeded() {
        guard task == nil else { return }
        let resolutions = watcher.resolutionUpdates()
        resolutionTask = Task { [weak self] in
            for await states in resolutions {
                guard !Task.isCancelled, let self else { break }
                self.latestResolutions = states
                self.onResolutionUpdate?(states)
            }
        }
        let snapshots = watcher.snapshots()
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { break }
                self.latestSnapshot = snapshot
                self.onSnapshotUpdate?(snapshot)
                // All existing consumers retain the legacy presentation and cache.
                let index = snapshot.legacyIndex
                guard index != self.latestIndex else { continue }
                self.latestIndex = index
                self.onUpdate?(index)
                for observer in Array(self.observers.values) { observer(index) }
            }
        }
        let stream = watcher.start()
        task = Task {
            for await _ in stream { if Task.isCancelled { break } }
        }
    }

}
