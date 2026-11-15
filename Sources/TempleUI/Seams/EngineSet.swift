import Foundation
import TempleCore

/// One engine per host (`HostRegistry`), merged into the one snapshot the
/// app consumes, keyed by session: each engine's ids are its own host's
/// sessions (ADR-041), so the same id from two hosts is two entries and
/// nothing is decided about who owns an id.
@MainActor
public final class EngineSet {
    /// The local engine and one per enabled remote host. Remote hosts come
    /// and go with Settings (`add`, `remove`); the local engine never does.
    public private(set) var engines: [any HostEngine]
    private var perHost: [HostID: EngineSnapshot] = [:]
    private var tasks: [HostID: [Task<Void, Never>]] = [:]
    private var started = false
    private var generation: UInt64 = 0
    private var onUpdate: ((SessionsSnapshot) -> Void)?
    public private(set) var latest: SessionsSnapshot?

    public init(engines: [any HostEngine]) {
        precondition(Set(engines.map(\.host)).count == engines.count)
        self.engines = engines
    }

    public func engine(for host: HostID) -> (any HostEngine)? { engines.first { $0.host == host } }

    public func start(onUpdate: @escaping (SessionsSnapshot) -> Void) {
        self.onUpdate = onUpdate
        if let latest { onUpdate(latest) }
        guard !started else { return }
        started = true
        for engine in engines { run(engine) }
    }

    private func run(_ engine: any HostEngine) {
        let snapshots = engine.snapshots()
        let host = engine.host
        tasks[host, default: []].append(Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { break }
                if let old = self.perHost[host], snapshot.generation < old.generation { continue }
                self.perHost[host] = snapshot
                self.remerge()
            }
        })
        tasks[host, default: []].append(Task { await engine.start() })
    }

    /// A host was enabled: its engine joins, and starts at once if the set
    /// is running. A host already present is left as it is.
    public func add(_ engine: any HostEngine) {
        guard self.engine(for: engine.host) == nil else { return }
        engines.append(engine)
        if started { run(engine) }
    }

    /// A host was removed or disabled: its engine stops and nothing it
    /// published stays in the merge.
    public func remove(host: HostID) {
        guard let engine = engine(for: host) else { return }
        engines.removeAll { $0.host == host }
        tasks.removeValue(forKey: host)?.forEach { $0.cancel() }
        Task { await engine.stop() }
        guard perHost.removeValue(forKey: host) != nil else { return }
        remerge(force: true)
    }

    public func stop() {
        tasks.values.joined().forEach { $0.cancel() }; tasks.removeAll()
        started = false
        perHost.removeAll()
        latest = nil; onUpdate = nil
        for engine in engines { Task { await engine.stop() } }
    }

    /// No snapshot reaches the app after this call (the first half of a
    /// quit, done in the same call as the drain's end).
    public func stopListening() {
        tasks.values.joined().forEach { $0.cancel() }; tasks.removeAll()
        started = false
        perHost.removeAll()
        latest = nil; onUpdate = nil
    }

    /// Quitting: stops every engine and its source (`HostEngine.shutDown`)
    /// and returns once all of them have, or once `timeout` has passed,
    /// whichever comes first, so a stuck host can never hold up the quit.
    /// Returns whether every engine finished in time.
    @discardableResult
    public func shutDown(timeout: TimeInterval) async -> Bool {
        stopListening()
        let engines = self.engines
        // Not a task group: a group waits for every child before it returns,
        // so an engine that never finished would hold the quit after all.
        // The two racers are unstructured, and the first answer wins.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = FirstAnswer(continuation)
            Task.detached {
                await withTaskGroup(of: Void.self) { all in
                    for engine in engines { all.addTask { await engine.shutDown() } }
                }
                answer.give(true)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                answer.give(false)
            }
        }
    }

    /// Asks the owning engine to re-read a row (a write found it gone).
    public func reconcileMembership(_ id: String, host: HostID) {
        guard let engine = engine(for: host) else { return }
        Task { await engine.reconcileMembership(id) }
    }

    private func remerge(force: Bool = false) {
        guard !perHost.isEmpty || force else { return }
        let merged = EngineSnapshot.merged(perHost: perHost, generation: generation &+ 1)
        if let latest, latest.resolutions == merged.resolutions, latest.facts == merged.facts,
           latest.memberships == merged.memberships { return }
        generation &+= 1
        latest = merged
        onUpdate?(merged)
    }
}

public extension EngineSnapshot {
    /// Per-host snapshots as one, keyed by session: each engine's ids are
    /// its host's sessions. Facts whose transcript is on another host, and
    /// memberships naming another host, are not that engine's to give and
    /// are left out.
    static func merged(perHost: [HostID: EngineSnapshot], generation: UInt64) -> SessionsSnapshot {
        var resolutions: [SessionKey: MemberResolution] = [:]
        var facts: [SessionKey: AuthorizedFacts] = [:]
        var memberships: [SessionKey: MembershipRef] = [:]
        for (host, snapshot) in perHost {
            for (id, resolution) in snapshot.resolutions { resolutions[SessionKey(id: id, host: host)] = resolution }
            for (id, entry) in snapshot.facts where entry.locator.host == host { facts[SessionKey(id: id, host: host)] = entry }
            for (id, ref) in snapshot.memberships where ref.host == host && ref.id == id {
                memberships[SessionKey(id: id, host: host)] = ref
            }
        }
        return SessionsSnapshot(generation: generation, resolutions: resolutions, facts: facts, memberships: memberships)
    }
}

/// Resumes a continuation with the first answer given, and ignores the rest.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func give(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
