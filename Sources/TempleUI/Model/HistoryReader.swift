import Foundation
import TempleCore

/// History's rows read once, without a page: the same catalog read
/// (`HistoryCatalogRead`) and the same projection (`HistoryProjector`) the
/// History tab runs, so a session reads here exactly as it does there. The
/// `temple history` commands use it, and so does the app when the command
/// line opens a session Temple has never seen (ADR-034).
public enum HistoryReader {
    public struct Result: Sendable {
        /// Every row, newest first: History's All scope.
        public let rows: [HistoryRow]
        /// Stores that could not be read; their sessions are missing.
        public let failures: [HistoryModel.StoreFailure]
        public init(rows: [HistoryRow], failures: [HistoryModel.StoreFailure]) {
            self.rows = rows; self.failures = failures
        }
    }

    @MainActor
    public static func read(hosts: HostRegistry, members: [Session], archivedProjects: Set<ProjectKey>,
                            openTabs: Set<SessionKey> = []) async -> Result {
        var memberFolders: [HostID: Set<ProjectKey>] = [:]
        for member in members { if let project = member.project { memberFolders[project.host, default: []].insert(project) } }
        let collected = Collected()
        let completion = await HistoryCatalogRead.run(
            hosts.catalog(), memberFolders: memberFolders,
            directoryEvidence: { key in await hosts.entry(for: key.host)?.source.directoryEvidence(key.path) ?? .unknown }
        ) { event in
            switch event {
            case .delta(let delta): collected.deltas.append(delta)
            case .failed(let failure, _): collected.failures.append(failure)
            case .progress: break
            }
        }
        var input = HistoryProjectionInput(catalog: collected.deltas, members: members,
                                           archivedProjects: archivedProjects, openTabs: openTabs)
        if let completion { input.catalog.append(.complete(completion)) }
        let snapshot = await HistoryProjector().apply(input)
        return Result(rows: snapshot?.allRows ?? [], failures: collected.failures)
    }

    /// What the catalog says about one id, for judging it against
    /// membership as it is when the caller acts (ADR-034): the slow part of
    /// History's read, without a verdict. Nil when the read was cancelled.
    struct Lookup: Sendable {
        let facts: HistoryProjector.IDFacts
        let failures: [HistoryModel.StoreFailure]
    }

    @MainActor
    static func lookup(_ id: String, hosts: HostRegistry, members: [Session]) async -> Lookup? {
        var memberFolders: [HostID: Set<ProjectKey>] = [:]
        for member in members { if let project = member.project { memberFolders[project.host, default: []].insert(project) } }
        let collected = Collected()
        let completion = await HistoryCatalogRead.run(
            hosts.catalog(), memberFolders: memberFolders,
            directoryEvidence: { key in await hosts.entry(for: key.host)?.source.directoryEvidence(key.path) ?? .unknown }
        ) { event in
            switch event {
            case .delta(let delta): collected.deltas.append(delta)
            case .failed(let failure, _): collected.failures.append(failure)
            case .progress: break
            }
        }
        guard let completion, !Task.isCancelled else { return nil }
        let projector = HistoryProjector()
        _ = await projector.apply(HistoryProjectionInput(catalog: collected.deltas + [.complete(completion)]))
        guard !Task.isCancelled else { return nil }
        return Lookup(facts: await projector.facts(for: id), failures: collected.failures)
    }

    /// History's rows for one id from a lookup and membership as it is now:
    /// synchronous, so a caller acting on the verdict acts on state no
    /// later than the verdict's.
    @MainActor
    static func rows(_ facts: HistoryProjector.IDFacts, member: Session?, archivedProjects: Set<ProjectKey>,
                     openTabs: Set<SessionKey>) -> [HistoryRow] {
        HistoryProjector.rows(member: member, disk: facts.disk, builder: HistoryRowBuilder(),
                              context: HistoryRowBuilder.Context(archivedProjects: archivedProjects, openTabs: openTabs,
                                                                 folders: facts.folders, coverage: facts.coverage))
    }

    @MainActor private final class Collected {
        var deltas: [CatalogDelta] = []
        var failures: [HistoryModel.StoreFailure] = []
    }
}

extension HistoryRow {
    /// History's search: case-insensitive, over everything the row shows or
    /// keeps in its tooltip, or a prefix of its id.
    public func matches(search term: String) -> Bool {
        matches(Array(term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
    }

    /// The session's own words for where it stands, as History's status
    /// column says it.
    public var standingName: String {
        switch standing {
        case .inTemple: "in-temple"
        case .archived: "archived"
        case .outside: "outside"
        case .conflict: "conflict"
        }
    }
}
