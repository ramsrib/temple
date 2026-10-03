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
    let engines: [SessionEngine]
    var watcher: SessionEngine { engines.first { $0.host.isLocal } ?? engines[0] }
    private var tasks: [Task<Void, Never>] = []
    private var hostSnapshots: [HostID: EngineSnapshot] = [:]
    private var publicationGeneration: UInt64 = 0
    func engine(for host: HostID) -> SessionEngine? { engines.first { $0.host == host } }
    func setEnrichmentWanted(_ missing: [String: Set<SessionCoreField>]) {
        for engine in engines { engine.setEnrichmentWanted(missing) }
    }
    private var latestSnapshot: EngineSnapshot?
    var onResolutionUpdate: (([String: MemberResolution]) -> Void)? {
        didSet { if let latestSnapshot { onResolutionUpdate?(latestSnapshot.resolutions) } }
    }
    private var observers: [UUID: (EngineSnapshot) -> Void] = [:]
    private var onUpdate: ((EngineSnapshot) -> Void)?
    public convenience init(watcher: SessionEngine = SessionEngine(source: LocalSessionSource())) {
        self.init(engines: [watcher])
    }
    public init(engines: [SessionEngine]) {
        precondition(!engines.isEmpty)
        precondition(Set(engines.map(\.host)).count == engines.count)
        self.engines = engines
    }
    public func start(onUpdate: @escaping (EngineSnapshot) -> Void) {
        self.onUpdate = onUpdate
        if let latestSnapshot { onUpdate(latestSnapshot) }
        startEngineIfNeeded()
    }
    public func stop() {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        hostSnapshots.removeAll()
        latestSnapshot = nil; onUpdate = nil
        engines.forEach { $0.stop() }
    }
    func observe(_ observer: @escaping (EngineSnapshot) -> Void) -> UUID {
        let id = UUID(); observers[id] = observer
        if let latestSnapshot { observer(latestSnapshot) }
        startEngineIfNeeded()
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func startEngineIfNeeded() {
        guard tasks.isEmpty else { return }
        for engine in engines {
            let snapshots = engine.snapshots()
            tasks.append(Task { [weak self] in
                for await snapshot in snapshots {
                    guard !Task.isCancelled, let self else { break }
                    if let old = self.hostSnapshots[engine.host], snapshot.generation < old.generation { continue }
                    self.hostSnapshots[engine.host] = snapshot
                    self.publicationGeneration &+= 1
                    let merged = EngineSnapshot(generation: self.publicationGeneration,
                        resolutions: self.hostSnapshots.values.reduce(into: [:]) { $0.merge($1.resolutions) { first, _ in first } },
                        summaries: self.hostSnapshots.values.reduce(into: [:]) { $0.merge($1.summaries) { first, _ in first } })
                    self.latestSnapshot = merged
                    self.onResolutionUpdate?(merged.resolutions)
                    self.onUpdate?(merged)
                    for observer in Array(self.observers.values) { observer(merged) }
                }
            })
            let stream = engine.start()
            tasks.append(Task { for await _ in stream { if Task.isCancelled { break } } })
        }
    }
}
