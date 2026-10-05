import Foundation
import TempleCore

/// The one place History consumes `HostRegistry.catalog`: one read of every
/// host, turned into the steps the projection applies (`CatalogDelta`) and
/// the progress and failures the page shows. Everything here runs off the
/// main actor; the page hears each step through `deliver`.
///
/// Each host is consumed on its own: the merged stream is read without ever
/// waiting on a host, and each host's batches go to a lane task of its own,
/// so a stalled host (a folder check that hangs, a slow link) holds up only
/// its own rows. A lane waits only on History's side: `deliver` returns once
/// the page's pump has room (`HistoryModel.catalogBacklogLimit`), so the rows
/// waiting to be projected stay bounded and nothing is dropped. What a lane
/// has not consumed yet is not bounded: batches are small (200 summaries)
/// and a 10,000-row read is a few megabytes, so an unbounded hand-off from
/// the source is accepted rather than pushing back on the host (ADR-031).
///
/// A host's catalog ends with `.completed(candidates:)` when its read ran to
/// its end: that becomes the host's `CatalogCoverage` in the completion
/// (its keys the completed agents, each with the session ids its listing
/// found a file for), and pruning and the absence of archived members'
/// transcripts stay inside it. A host that sends none proves nothing.
enum HistoryCatalogRead {
    enum Event: Sendable {
        /// One host's progress: files consumed, and the total once listed.
        case progress(host: HostID, read: Int, total: Int?)
        case failed(HistoryModel.StoreFailure, wholeHost: Bool)
        case delta(CatalogDelta)
    }

    /// Reads every host at once. Each host's batches run in a lane of their
    /// own, in order: the noise check asks the owning host about each
    /// project once a read, and a host whose folder checks stall holds up its
    /// own rows, never another host's. After its last
    /// batch a lane asks about the folders of that host's members the
    /// catalog did not cover. Returns the completion, or nil when the read
    /// was cancelled.
    static func run(
        _ stream: AsyncStream<HostCatalogEvent>,
        memberFolders: [HostID: Set<ProjectKey>],
        directoryEvidence: @escaping @Sendable (ProjectKey) async -> DirectoryEvidence,
        deliver: @escaping @MainActor @Sendable (Event) async -> Void
    ) async -> CatalogCompletion? {
        let (seen, coverage) = await withTaskGroup(of: (HostID, Set<HistoryKey>, [Agent: Set<String>]?).self) {
            group -> (Set<HistoryKey>, [HostID: CatalogCoverage]) in
            var lanes: [HostID: AsyncStream<CatalogBatch>.Continuation] = [:]
            for await event in stream {
                if Task.isCancelled { break }
                if lanes[event.host] == nil {
                    let (batches, lane) = AsyncStream<CatalogBatch>.makeStream()
                    lanes[event.host] = lane
                    let host = event.host
                    let folders = memberFolders[host] ?? []
                    group.addTask {
                        let (seen, completed) = await runLane(batches, host: host, memberFolders: folders,
                                                              directoryEvidence: directoryEvidence, deliver: deliver)
                        return (host, seen, completed)
                    }
                }
                // Never waits: one host's lane cannot hold up another's.
                lanes[event.host]?.yield(event.batch)
            }
            for lane in lanes.values { lane.finish() }
            var seen = Set<HistoryKey>()
            var coverage: [HostID: CatalogCoverage] = [:]
            for await (host, keys, completed) in group {
                seen.formUnion(keys)
                if let completed { coverage[host] = CatalogCoverage(candidates: completed) }
            }
            return (seen, coverage)
        }
        guard !Task.isCancelled else { return nil }
        return CatalogCompletion(seen: seen, coverage: coverage)
    }

    private static func runLane(
        _ batches: AsyncStream<CatalogBatch>, host: HostID, memberFolders: Set<ProjectKey>,
        directoryEvidence: @escaping @Sendable (ProjectKey) async -> DirectoryEvidence,
        deliver: @escaping @MainActor @Sendable (Event) async -> Void
    ) async -> (seen: Set<HistoryKey>, completed: [Agent: Set<String>]?) {
        var seen = Set<HistoryKey>()
        var completed: [Agent: Set<String>]?
        var exists: [ProjectKey: DirectoryEvidence] = [:]
        var read = 0
        for await batch in batches {
            guard !Task.isCancelled else { return (seen, nil) }
            switch batch {
            case .listed(let total):
                await deliver(.progress(host: host, read: 0, total: total))
            case .storeFailed(let agent, let message):
                // A host that failed as a whole failed for every agent, and
                // has nothing more to read.
                for failed in agent.map({ [$0] }) ?? Agent.allCases {
                    await deliver(.failed(HistoryModel.StoreFailure(host: host, agent: failed, message: message),
                                          wholeHost: agent == nil))
                }
                if agent == nil { await deliver(.progress(host: host, read: read, total: read)) }
            case .sessions(let rows, let count, let total):
                // One summary per host, agent and id by the catalog's own selection.
                let fresh = rows.filter { $0.locator.host == host }
                var asked: [ProjectKey: DirectoryEvidence] = [:]
                for key in Set(fresh.map(HistoryModel.noiseKey)) where exists[key] == nil {
                    let answer = await directoryEvidence(key)
                    guard !Task.isCancelled else { return (seen, nil) }
                    exists[key] = answer
                    asked[key] = answer
                }
                let sorted = HistoryModel.classify(fresh, exists: exists) { exists[$0] ?? .unknown }
                exists = sorted.exists
                for session in fresh { seen.insert(HistoryKey(session)) }
                read = count
                guard !Task.isCancelled else { return (seen, nil) }
                // Returns once the page's pump has room for it.
                await deliver(.delta(.upsert(fresh, noise: Set(sorted.noise), folders: asked)))
                await deliver(.progress(host: host, read: count, total: total))
            case .completed(let candidates):
                // The host's word on what its listing covered; it counts
                // only if the read is not cancelled before it ends.
                completed = candidates
            }
        }
        // Members whose folder no catalog row of this host named.
        var answers: [ProjectKey: DirectoryEvidence] = [:]
        for key in memberFolders where exists[key] == nil {
            guard !Task.isCancelled else { return (seen, nil) }
            answers[key] = await directoryEvidence(key)
        }
        if !answers.isEmpty, !Task.isCancelled { await deliver(.delta(.folders(answers))) }
        return (seen, Task.isCancelled ? nil : completed)
    }
}
