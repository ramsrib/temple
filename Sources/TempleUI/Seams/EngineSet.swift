import Foundation
import TempleCore

/// One engine per host (`HostRegistry`), merged into the one snapshot the
/// app consumes. An id comes only from the engine of the host that owns its
/// row now; the merge is recomputed on every engine snapshot *and* on every
/// ownership change, so a snapshot from a host the id has just left cannot
/// win, and one from the host it has just joined is not lost for arriving
/// before the row did.
@MainActor
public final class EngineSet {
    public let engines: [any HostEngine]
    private var perHost: [HostID: EngineSnapshot] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var generation: UInt64 = 0
    private var onUpdate: ((EngineSnapshot) -> Void)?
    /// The host whose row holds the id now (nil: not a member anywhere).
    var owner: (String) -> HostID? = { _ in nil }
    public private(set) var latest: EngineSnapshot?

    public init(engines: [any HostEngine]) {
        precondition(Set(engines.map(\.host)).count == engines.count)
        self.engines = engines
    }

    public func engine(for host: HostID) -> (any HostEngine)? { engines.first { $0.host == host } }

    public func start(onUpdate: @escaping (EngineSnapshot) -> Void) {
        self.onUpdate = onUpdate
        if let latest { onUpdate(latest) }
        guard tasks.isEmpty else { return }
        for engine in engines {
            let snapshots = engine.snapshots()
            let host = engine.host
            tasks.append(Task { [weak self] in
                for await snapshot in snapshots {
                    guard !Task.isCancelled, let self else { break }
                    if let old = self.perHost[host], snapshot.generation < old.generation { continue }
                    self.perHost[host] = snapshot
                    self.remerge()
                }
            })
            tasks.append(Task { await engine.start() })
        }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        perHost.removeAll()
        latest = nil; onUpdate = nil
        for engine in engines { Task { await engine.stop() } }
    }

    /// A row joined, left or changed host: the merge is decided again.
    public func ownershipChanged() { remerge() }

    /// Asks the owning engine to re-read a row (a write found it gone).
    public func reconcileMembership(_ id: String, host: HostID) {
        guard let engine = engine(for: host) else { return }
        Task { await engine.reconcileMembership(id) }
    }

    private func remerge() {
        guard !perHost.isEmpty else { return }
        let merged = EngineSnapshot.merged(perHost: perHost, owner: owner, generation: generation &+ 1)
        if let latest, latest.resolutions == merged.resolutions, latest.facts == merged.facts,
           latest.memberships == merged.memberships, latest.absenceCoverage == merged.absenceCoverage { return }
        generation &+= 1
        latest = merged
        onUpdate?(merged)
    }
}

public extension EngineSnapshot {
    /// Per-host snapshots as one: each id from the engine of the host that
    /// owns it now, and from no other.
    static func merged(perHost: [HostID: EngineSnapshot], owner: (String) -> HostID?,
                       generation: UInt64) -> EngineSnapshot {
        var resolutions: [String: MemberResolution] = [:]
        var facts: [String: AuthorizedFacts] = [:]
        var memberships: [String: MembershipRef] = [:]
        var absences: [String: UInt64] = [:]
        for (host, snapshot) in perHost {
            for (id, coverage) in snapshot.absenceCoverage where owner(id) == host { absences[id] = coverage }
            for (id, resolution) in snapshot.resolutions where owner(id) == host { resolutions[id] = resolution }
            for (id, entry) in snapshot.facts where owner(id) == host { facts[id] = entry }
            for (id, ref) in snapshot.memberships where owner(id) == host && ref.host == host { memberships[id] = ref }
        }
        return EngineSnapshot(generation: generation, resolutions: resolutions, facts: facts, memberships: memberships,
                              absenceCoverage: absences)
    }
}
