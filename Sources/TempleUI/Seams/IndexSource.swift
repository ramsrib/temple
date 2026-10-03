import Foundation
import TempleCore

/// Supplies coherent member facts and resolution outcomes to the row overlay.
@MainActor
public protocol IndexSource: AnyObject {
    func start(onUpdate: @escaping (EngineSnapshot) -> Void)
    func stop()
}

@MainActor
public final class WatcherIndexSource: IndexSource {
    let watcher: SessionWatcher
    private var task: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var latestSnapshot: EngineSnapshot?
    var onSnapshotUpdate: ((EngineSnapshot) -> Void)? {
        didSet { if let latestSnapshot { onSnapshotUpdate?(latestSnapshot) } }
    }
    var onResolutionUpdate: (([String: MemberResolution]) -> Void)? {
        didSet { if let latestSnapshot { onResolutionUpdate?(latestSnapshot.resolutions) } }
    }
    private var observers: [UUID: (EngineSnapshot) -> Void] = [:]
    private var onUpdate: ((EngineSnapshot) -> Void)?
    public init(watcher: SessionWatcher = SessionWatcher()) { self.watcher = watcher }
    public func start(onUpdate: @escaping (EngineSnapshot) -> Void) {
        self.onUpdate = onUpdate
        if let latestSnapshot { onUpdate(latestSnapshot) }
        startEngineIfNeeded()
    }
    public func stop() {
        task?.cancel(); task = nil
        snapshotTask?.cancel(); snapshotTask = nil
        latestSnapshot = nil; onUpdate = nil
        watcher.stop()
    }
    func observe(_ observer: @escaping (EngineSnapshot) -> Void) -> UUID {
        let id = UUID(); observers[id] = observer
        if let latestSnapshot { observer(latestSnapshot) }
        startEngineIfNeeded()
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func startEngineIfNeeded() {
        guard task == nil else { return }
        let snapshots = watcher.snapshots()
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { break }
                self.latestSnapshot = snapshot
                self.onResolutionUpdate?(snapshot.resolutions)
                self.onSnapshotUpdate?(snapshot)
                self.onUpdate?(snapshot)
                for observer in Array(self.observers.values) { observer(snapshot) }
            }
        }
        let stream = watcher.start()
        task = Task { for await _ in stream { if Task.isCancelled { break } } }
    }
}
