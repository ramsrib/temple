import Foundation
import TempleCore

/// The segmented control: which side of the Temple line a row must be on.
/// The three narrow scopes partition All (ADR-031): In Temple is what the
/// sidebar and ⌘K show, Archived is in Temple and put away.
public enum HistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all, inTemple, archived, notInTemple

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .inTemple: "In Temple"
        case .archived: "Archived"
        case .notInTemple: "Not in Temple"
        }
    }

    func admits(_ row: HistoryRow) -> Bool {
        switch self {
        case .all: true
        case .inTemple: row.isMember && !row.isArchived
        case .archived: row.isArchived
        case .notInTemple: !row.isMember
        }
    }
}

/// The question the page asks of the rows: scope, filters, search, and the
/// "Archived just now" chip. A value, handed to the projection whole.
struct HistoryQuery: Equatable, Sendable {
    var scope: HistoryScope = .all
    var agent: Agent?
    var project: ProjectKey?
    /// Trimmed, as typed (case is ignored when matching).
    var search: String = ""
    /// The chip: exactly these memberships (the sidebar notice's).
    var justArchived: Set<MembershipRef>?

    var isDefault: Bool { self == HistoryQuery() }

    func admits(_ row: HistoryRow, needle: [UInt8]) -> Bool {
        guard scope.admits(row) else { return false }
        if let agent, row.agent != agent { return false }
        if let project, row.project != project { return false }
        if let justArchived {
            guard let state = row.member?.state, let incarnation = state.incarnation,
                  justArchived.contains(MembershipRef(id: state.id, host: state.host, incarnation: incarnation))
            else { return false }
        }
        return row.matches(needle)
    }
}

/// One host's completed listings, as its catalog's `.completed(candidates:)`
/// reported them (ADR-032): for each agent whose listing completed, and
/// only those, every session id that listing found a transcript file named
/// for, whatever reading it came to, in the agent's candidate spelling. An
/// agent with no entry proves nothing. A file that did not read (unreadable,
/// another session's, changing under the read) is no usable summary, but it
/// is no absence either. Per agent, so another agent's file under the same
/// id never hides an absence.
struct CatalogCoverage: Equatable, Sendable {
    /// Keys are the completed agents.
    var candidates: [Agent: Set<String>]

    var completedAgents: Set<Agent> { Set(candidates.keys) }

    /// Proven gone: `agent`'s listing completed and found no file for `id`.
    /// The host side's own rule (`CatalogBatch.provesNoTranscript`), with its
    /// id spelling (`TranscriptFormat.candidateKey`).
    func provesAbsent(_ id: String, agent: Agent) -> Bool {
        CatalogBatch.completed(candidates: candidates).provesNoTranscript(id: id, agent: agent) ?? false
    }
}

/// What a finished read proves: the keys it saw, and each host's completed
/// listings. Pruning and absence stay inside a completed listing; a host
/// that did not complete (a failed or missing store, a lost transport, a
/// cancelled read) proves nothing and keeps what it showed before.
struct CatalogCompletion: Sendable {
    var seen: Set<HistoryKey>
    /// Each host's completed listings; a host absent here completed none.
    var coverage: [HostID: CatalogCoverage]

    /// A summary this read did not deliver leaves the page only inside a
    /// completed listing of its agent (its file may still be a candidate
    /// that did not read: then it is no usable summary, and no absence).
    func prunes(_ key: HistoryKey) -> Bool {
        guard !seen.contains(key), let agent = key.agent else { return false }
        return coverage[key.host]?.completedAgents.contains(agent) == true
    }
}

/// One step of a read, in order.
enum CatalogDelta: Sendable {
    /// One host's batch: every summary (noise included, so a later join
    /// shows its disk facts), which of them are noise, and the folder
    /// answers asked for it.
    case upsert([TranscriptSummary], noise: Set<HistoryKey>, folders: [ProjectKey: DirectoryEvidence])
    /// Folder answers for members' projects.
    case folders([ProjectKey: DirectoryEvidence])
    case complete(CatalogCompletion)

    var rowCount: Int {
        if case .upsert(let rows, _, _) = self { return rows.count }
        return 0
    }
}

/// Everything that changed since the last projection, as values. Catalog
/// steps keep their order; the rest is latest-wins.
struct HistoryProjectionInput: Sendable {
    var catalog: [CatalogDelta] = []
    var members: [Session]?
    var archivedProjects: Set<ProjectKey>?
    var openTabs: Set<SessionKey>?
    var query: HistoryQuery?
    /// The generation of the query this input belongs to; a snapshot built
    /// for an older one never lands.
    var generation: UInt64 = 0
    /// Rebuild every row (the clock's zone or the day moved).
    var rebuildAll = false

    var isEmpty: Bool {
        catalog.isEmpty && members == nil && archivedProjects == nil && openTabs == nil && query == nil && !rebuildAll
    }

    mutating func merge(_ other: HistoryProjectionInput) {
        catalog += other.catalog
        members = other.members ?? members
        archivedProjects = other.archivedProjects ?? archivedProjects
        openTabs = other.openTabs ?? openTabs
        query = other.query ?? query
        generation = max(generation, other.generation)
        rebuildAll = rebuildAll || other.rebuildAll
    }
}

public struct HistoryCounts: Equatable, Sendable {
    public var all = 0
    /// In Temple and not archived.
    public var inTemple = 0
    public var archived = 0
    public var transcriptMissing = 0
    public var agents: [Agent: Int] = [:]
    /// Rows by host and agent: what a store failure's banner says is still shown.
    public var hostAgents: [HostID: [Agent: Int]] = [:]
}

/// One coherent page: every row, the rows the query admits, their days, and
/// the counts, built together off the main actor and installed in one
/// assignment.
public struct HistorySnapshot: Sendable {
    /// The query generation it answers.
    let generation: UInt64
    let query: HistoryQuery
    public let allRows: [HistoryRow]
    public let visibleRows: [HistoryRow]
    public let groups: [HistoryRowDayGroup]
    /// Where each group starts in `visibleRows`.
    let groupStarts: [Int]
    /// A visible row's position, for selection and the keyboard.
    let indexByKey: [HistoryKey: Int]
    public let counts: HistoryCounts
    public let projects: [ProjectCount]
    public let archivedProjects: Set<ProjectKey>

    static let empty = HistorySnapshot(generation: 0, query: HistoryQuery(), allRows: [], visibleRows: [],
                                       groups: [], groupStarts: [], indexByKey: [:], counts: HistoryCounts(),
                                       projects: [], archivedProjects: [])
}

/// The History projection, off the main actor: membership union, noise,
/// keyed rows in chronological order, counts, filtering, search and day
/// grouping. It keeps its inputs between projections (retained across the
/// tab closing), applies each input as a change to what it has, and answers
/// nil when nothing the page shows changed.
actor HistoryProjector {
    /// Work counts, for tests and measurement.
    struct Stats: Sendable {
        var projections = 0
        var published = 0
        var rowsBuilt = 0
        var fullSorts = 0
        var merges = 0
        var ranOnMainThread = false
        var lastDuration: TimeInterval = 0
    }
    private(set) var stats = Stats()

    private var catalog: [HistoryKey: TranscriptSummary] = [:]
    private var keysByID: [String: Set<HistoryKey>] = [:]
    private var noise: Set<HistoryKey> = []
    private var folders: [ProjectKey: DirectoryEvidence] = [:]
    private var coverage: [HostID: CatalogCoverage] = [:]
    private var members: [String: Session] = [:]
    private var memberIDsByProject: [ProjectKey: Set<String>] = [:]
    private var archivedProjects: Set<ProjectKey> = []
    private var openTabs: Set<SessionKey> = []
    private var query = HistoryQuery()
    private var generation: UInt64 = 0

    private var rowsByID: [String: [HistoryRow]] = [:]
    private var ordered: [HistoryRow] = []
    private var counts = HistoryCounts()
    private var projects: [ProjectCount] = []
    private var builder: HistoryRowBuilder
    private var builtZone: TimeZone
    private var today: Date
    private let now: @Sendable () -> Date
    /// The last two snapshots made: the main actor releasing the one it
    /// replaces never frees ten thousand rows there.
    private var recent: [HistorySnapshot] = []
    private var published: HistorySnapshot?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        builder = HistoryRowBuilder(calendar: .current)
        builtZone = TimeZone.current
        today = Calendar.current.startOfDay(for: now())
    }

    var rowCount: Int { ordered.count }

    /// How many times the calendar and formatters were made afresh.
    private(set) var builderGeneration = 0

    func apply(_ input: HistoryProjectionInput) -> HistorySnapshot? {
        let started = Date()
        stats.projections += 1
        if pthread_main_np() != 0 { stats.ranOnMainThread = true }
        defer { stats.lastDuration = Date().timeIntervalSince(started) }

        var dirty = Set<String>()
        var rebuildAll = input.rebuildAll
        // The day, the clock's zone or the locale moved (a notification, or
        // noticed here): every row's day and time text, with a fresh
        // calendar and fresh formatters.
        if TimeZone.current != builtZone || input.rebuildAll {
            builtZone = TimeZone.current
            builder = HistoryRowBuilder(calendar: .current)
            builderGeneration += 1
            rebuildAll = true
        }
        for delta in input.catalog { applyCatalog(delta, dirty: &dirty) }
        if let next = input.members { applyMembers(next, dirty: &dirty) }
        if let next = input.archivedProjects, next != archivedProjects {
            for key in next.symmetricDifference(archivedProjects) { dirty.formUnion(memberIDsByProject[key] ?? []) }
            archivedProjects = next
        }
        if let next = input.openTabs, next != openTabs {
            for key in next.symmetricDifference(openTabs) { dirty.insert(key.id) }
            openTabs = next
        }
        if rebuildAll { dirty = Set(keysByID.keys).union(members.keys) }

        let rowsChanged = rebuildRows(dirty, full: rebuildAll)
        if rowsChanged { recount() }

        let queryChanged = input.generation != generation || (input.query.map { $0 != query } ?? false)
        if let next = input.query { query = next }
        generation = max(generation, input.generation)
        let day = builder.calendar.startOfDay(for: now())
        let dayMoved = day != today
        today = day

        guard rowsChanged || queryChanged || dayMoved || published == nil else { return nil }
        let snapshot = project()
        published = snapshot
        recent.append(snapshot)
        if recent.count > 2 { recent.removeFirst() }
        stats.published += 1
        return snapshot
    }

    // MARK: Inputs

    private func applyCatalog(_ delta: CatalogDelta, dirty: inout Set<String>) {
        switch delta {
        case .upsert(let summaries, let noiseKeys, let answers):
            for summary in summaries {
                let key = HistoryKey(summary)
                catalog[key] = summary
                keysByID[summary.id, default: []].insert(key)
                noise.remove(key)
                dirty.insert(summary.id)
            }
            noise.formUnion(noiseKeys)
            applyFolders(answers, dirty: &dirty)
        case .folders(let answers):
            applyFolders(answers, dirty: &dirty)
        case .complete(let completion):
            for key in catalog.keys where completion.prunes(key) {
                catalog.removeValue(forKey: key)
                keysByID[key.sessionID]?.remove(key)
                if keysByID[key.sessionID]?.isEmpty == true { keysByID.removeValue(forKey: key.sessionID) }
                noise.remove(key)
                dirty.insert(key.sessionID)
            }
            // The latest read's evidence, whole: an older read's listing
            // proves nothing about now.
            if completion.coverage != coverage {
                coverage = completion.coverage
                // What a listing proves about archived members changed.
                dirty.formUnion(members.keys)
            }
        }
    }

    private func applyFolders(_ answers: [ProjectKey: DirectoryEvidence], dirty: inout Set<String>) {
        for (key, evidence) in answers where folders[key] != evidence {
            folders[key] = evidence
            dirty.formUnion(memberIDsByProject[key] ?? [])
        }
    }

    private func applyMembers(_ next: [Session], dirty: inout Set<String>) {
        let incoming = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, member) in incoming where members[id] != member { dirty.insert(id) }
        for id in members.keys where incoming[id] == nil { dirty.insert(id) }
        members = incoming
        var byProject: [ProjectKey: Set<String>] = [:]
        for member in incoming.values { if let project = member.project { byProject[project, default: []].insert(member.id) } }
        memberIDsByProject = byProject
    }

    // MARK: Rows

    private var context: HistoryRowBuilder.Context {
        HistoryRowBuilder.Context(archivedProjects: archivedProjects, openTabs: openTabs,
                                  folders: folders, coverage: coverage)
    }

    /// Rebuilds the rows of `ids` and merges them into the chronology.
    /// Returns whether any row changed.
    private func rebuildRows(_ ids: Set<String>, full: Bool) -> Bool {
        guard !ids.isEmpty else { return false }
        let context = context
        var removed = Set<HistoryKey>()
        var added: [HistoryRow] = []
        for id in ids {
            let next = rows(for: id, context: context)
            let previous = rowsByID[id] ?? []
            guard next != previous else { continue }
            removed.formUnion(previous.map(\.id))
            added += next
            rowsByID[id] = next.isEmpty ? nil : next
        }
        guard !removed.isEmpty || !added.isEmpty else { return false }
        if full || removed.count + added.count > max(64, ordered.count / 4) {
            stats.fullSorts += 1
            ordered = rowsByID.values.flatMap { $0 }.sorted(by: Self.newerFirst)
        } else {
            stats.merges += 1
            if !removed.isEmpty { ordered.removeAll { removed.contains($0.id) } }
            ordered = Self.merge(ordered, added.sorted(by: Self.newerFirst))
        }
        return true
    }

    private func rows(for id: String, context: HistoryRowBuilder.Context) -> [HistoryRow] {
        let member = members[id]
        let keys = keysByID[id] ?? []
        var rows: [HistoryRow] = []
        var attached = false
        for key in keys {
            guard let disk = catalog[key] else { continue }
            let otherAgentListed = keys.contains { $0.host == key.host && $0.agent != key.agent }
            switch HistoryModel.standing(of: key, member: member?.state, otherAgentListed: otherAgentListed) {
            case .member:
                rows.append(builder.row(member: member, catalog: disk, conflict: nil, context: context))
                attached = true
            case .conflict(let conflict):
                if !noise.contains(key) { rows.append(builder.row(member: nil, catalog: disk, conflict: conflict, context: context)) }
            case .outside:
                if !noise.contains(key) { rows.append(builder.row(member: nil, catalog: disk, conflict: nil, context: context)) }
            }
        }
        if let member, !attached { rows.append(builder.row(member: member, catalog: nil, conflict: nil, context: context)) }
        stats.rowsBuilt += rows.count
        return rows.sorted(by: Self.newerFirst)
    }

    static func newerFirst(_ lhs: HistoryRow, _ rhs: HistoryRow) -> Bool {
        guard lhs.updatedAt == rhs.updatedAt else { return lhs.updatedAt > rhs.updatedAt }
        if lhs.sessionID != rhs.sessionID { return lhs.sessionID < rhs.sessionID }
        if lhs.host != rhs.host { return lhs.host.rawValue < rhs.host.rawValue }
        return (lhs.agent?.rawValue ?? "") < (rhs.agent?.rawValue ?? "")
    }

    private static func merge(_ base: [HistoryRow], _ incoming: [HistoryRow]) -> [HistoryRow] {
        guard !incoming.isEmpty else { return base }
        guard !base.isEmpty else { return incoming }
        var result: [HistoryRow] = []
        result.reserveCapacity(base.count + incoming.count)
        var i = 0, j = 0
        while i < base.count, j < incoming.count {
            if newerFirst(incoming[j], base[i]) { result.append(incoming[j]); j += 1 }
            else { result.append(base[i]); i += 1 }
        }
        result.append(contentsOf: base[i...])
        result.append(contentsOf: incoming[j...])
        return result
    }

    private func recount() {
        var counts = HistoryCounts()
        var byProject: [ProjectKey: Int] = [:]
        counts.all = ordered.count
        for row in ordered {
            if row.isArchived { counts.archived += 1 } else if row.isMember { counts.inTemple += 1 }
            if row.transcriptMissing { counts.transcriptMissing += 1 }
            if let agent = row.agent {
                counts.agents[agent, default: 0] += 1
                counts.hostAgents[row.host, default: [:]][agent, default: 0] += 1
            }
            if let project = row.project { byProject[project, default: 0] += 1 }
        }
        self.counts = counts
        projects = byProject
            .map { ProjectCount(key: $0.key, count: $0.value, displayName: $0.key.displayName,
                                parentFolder: builder.parentFolder($0.key)) }
            .sorted { $0.count == $1.count ? $0.path < $1.path : $0.count > $1.count }
    }

    // MARK: Projection

    private func project() -> HistorySnapshot {
        let visible: [HistoryRow]
        if query.isDefault {
            visible = ordered
        } else {
            let needle = Array(query.search.lowercased().utf8)
            visible = ordered.filter { query.admits($0, needle: needle) }
        }
        let titles = HistoryRowGrouping.Titles(calendar: builder.calendar, now: now())
        let (groups, starts) = HistoryRowGrouping.groups(visible, titles: titles)
        var index: [HistoryKey: Int] = [:]
        index.reserveCapacity(visible.count)
        for (offset, row) in visible.enumerated() { index[row.id] = offset }
        return HistorySnapshot(generation: generation, query: query, allRows: ordered, visibleRows: visible,
                               groups: groups, groupStarts: starts, indexByKey: index, counts: counts,
                               projects: projects, archivedProjects: archivedProjects)
    }
}
