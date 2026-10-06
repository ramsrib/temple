import Foundation
import TempleCore

/// One History row's identity: the host and agent that offer the session,
/// and its id. Two hosts — or two agents on one host — can list the same id,
/// and each is its own row. Membership is looked up separately, by the
/// session id alone, which is unique in Temple (`TempleDB.join`).
public struct HistoryKey: Hashable, Sendable {
    public let host: HostID
    /// Nil only for a member that never recorded its agent (a legacy row).
    public let agent: Agent?
    public let sessionID: String

    public init(host: HostID, agent: Agent?, sessionID: String) {
        self.host = host; self.agent = agent; self.sessionID = sessionID
    }

    public init(_ summary: TranscriptSummary) {
        self.init(host: summary.locator.host, agent: summary.agent, sessionID: summary.id)
    }

    public init(_ member: Session) {
        self.init(host: member.host, agent: member.agent, sessionID: member.id)
    }
}

/// Where a row stands against Temple: the status column says it, and the
/// row's tone follows it.
public enum HistoryStanding: Equatable, Sendable {
    /// In Temple and in play: what the sidebar and ⌘K show.
    case inTemple
    /// In Temple and put away (ADR-031): by its own flag, or its project's mask.
    case archived(ArchiveStatus)
    /// On disk, not Temple's.
    case outside
    /// Its id is Temple's on another host or as another agent.
    case conflict(JoinConflict)
}

/// Why an archived row is away, as its tooltip says it.
public enum ArchiveStatus: Equatable, Sendable {
    /// The user's archive; the date is unknown for one from before v12.
    case byUser(at: Date?)
    /// Temple's archive (ADR-030), with its reason.
    case byTemple(ArchiveReason)
    /// The row's project is archived (the project mask, ADR-017).
    case withProject(ProjectKey)
}

/// A condition a member is in, tagged after its title.
public enum HistoryConditionTag: Equatable, Sendable {
    case noTranscript, noFolder

    public var label: String {
        switch self {
        case .noTranscript: "No transcript"
        case .noFolder: "No folder"
        }
    }
}

/// History's union, durable member presentation plus optional catalog
/// facts, with everything the row draws computed once when the projection
/// builds it (`HistoryRowBuilder`, off the main actor). The row view looks
/// nothing up: no tab scan, no formatter, no overlay read. Two rows that
/// draw the same compare equal, so an unchanged projection publishes
/// nothing.
public struct HistoryRow: Identifiable, Equatable, Sendable {
    public let id: HistoryKey
    /// For a member attached to a catalog row, its activity time is dropped
    /// here: the row shows disk time, so activity cannot change it.
    public let member: Session?
    public let catalog: TranscriptSummary?
    /// A catalog row whose id is already Temple's on another host, or as
    /// another agent: shown as the catalog has it, never attached to that
    /// member, and never imported or opened from here.
    public let conflict: JoinConflict?

    // MARK: Presentation, precomputed

    public let title: String
    public let updatedAt: Date
    /// The start of `updatedAt`'s day in the projection's calendar; the
    /// distant past for an undated row.
    let day: Date
    /// "14:02"; empty for an undated row.
    public let timeText: String
    public let project: ProjectKey?
    /// "raven", "raven @box", or "No project".
    public let projectName: String
    public let standing: HistoryStanding
    /// Proven: the engine's completed verdict, Temple's recorded reason, or
    /// for an archived member (which the engine no longer watches) a
    /// completed listing of its agent without it. A catalog row is a file on
    /// disk, so never.
    public let transcriptMissing: Bool
    /// The owning host said the member's folder is missing, or Temple
    /// archived it for that.
    public let folderMissing: Bool
    /// A person restored it, and the sweep leaves it alone (ADR-030).
    public let kept: Bool
    public let canResume: Bool
    /// The row has a resume command to copy (an agent and a folder).
    public let hasResumeCommand: Bool
    /// In Temple, not archived, and no tab open on it when the projection ran.
    /// The action rechecks the live tab set.
    public let canArchive: Bool
    /// The row's project is archived: Restore project applies.
    public let projectArchived: Bool
    let colorMark: TabColorMark?
    /// The status column's tooltip: the membership line, the Restore
    /// button's, or a conflict's message.
    public let statusTooltip: String?
    public let conditionTag: HistoryConditionTag?
    public let tagTooltip: String?
    /// "In Temple · opened Sep 25".
    public let membershipTooltip: String
    /// The last message and the details too loose for a column.
    public let rowTooltip: String
    /// Lowercased title, folder, branch and last message, for search.
    let searchKey: [UInt8]
    let idKey: [UInt8]

    public var sessionID: String { id.sessionID }
    public var host: HostID { id.host }
    public var agent: Agent? { member != nil ? member?.agent : catalog?.agent }
    public var projectPath: String { project?.path ?? "" }
    public var isMember: Bool { member != nil }
    public var isArchived: Bool { if case .archived = standing { true } else { false } }
    /// Outside Temple and free to join from this row.
    public var canImport: Bool { member == nil && conflict == nil }
    public var localURL: URL? { catalog?.locator.localURL ?? member?.transcript?.localURL }
    public var gitBranch: String? { catalog?.gitBranch }
    public var model: String? { catalog?.model }
    public var messageCount: Int? { catalog?.messageCount }
    public var lastMessagePreview: String? { catalog?.lastMessagePreview }
    /// Computed when an action asks, never stored or drawn.
    public var resumeArgv: [String] {
        if let member { return SessionLauncher.resumeArgv(member) }
        return catalog.map { $0.agent.resumeArgv(sessionID: $0.id) } ?? []
    }
    public var archiveStatus: ArchiveStatus? {
        if case .archived(let status) = standing { return status }
        return nil
    }

    /// A row built outside a projection (tests, a one-off): nothing archived
    /// by project, no tab open, no folder evidence.
    public init(member: Session? = nil, catalog: TranscriptSummary? = nil, conflict: JoinConflict? = nil) {
        self = HistoryRowBuilder().row(member: member, catalog: catalog, conflict: conflict,
                                       context: HistoryRowBuilder.Context())
    }

    fileprivate init(id: HistoryKey, member: Session?, catalog: TranscriptSummary?, conflict: JoinConflict?,
                     title: String, updatedAt: Date, day: Date, timeText: String, project: ProjectKey?,
                     projectName: String, standing: HistoryStanding, transcriptMissing: Bool,
                     folderMissing: Bool, kept: Bool, canResume: Bool, hasResumeCommand: Bool, canArchive: Bool,
                     projectArchived: Bool, colorMark: TabColorMark?, statusTooltip: String?,
                     conditionTag: HistoryConditionTag?, tagTooltip: String?, membershipTooltip: String,
                     rowTooltip: String, searchKey: [UInt8], idKey: [UInt8]) {
        self.id = id; self.member = member; self.catalog = catalog; self.conflict = conflict
        self.title = title; self.updatedAt = updatedAt; self.day = day; self.timeText = timeText
        self.project = project; self.projectName = projectName; self.standing = standing
        self.transcriptMissing = transcriptMissing; self.folderMissing = folderMissing; self.kept = kept
        self.canResume = canResume; self.hasResumeCommand = hasResumeCommand; self.canArchive = canArchive; self.projectArchived = projectArchived
        self.colorMark = colorMark; self.statusTooltip = statusTooltip; self.conditionTag = conditionTag
        self.tagTooltip = tagTooltip; self.membershipTooltip = membershipTooltip; self.rowTooltip = rowTooltip
        self.searchKey = searchKey; self.idKey = idKey
    }

    /// Case-insensitive substring over everything the row shows or hides in
    /// its tooltip, plus an id prefix (a pasted id from a log finds its row).
    /// `needle` is already lowercased UTF-8.
    func matches(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        if idKey.count >= needle.count, idKey.starts(with: needle) { return true }
        guard searchKey.count >= needle.count else { return false }
        return searchKey.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }
}

/// Builds rows with their presentation. Owned by the projection (off the
/// main actor), which keeps one for its formatters and folder cache; a test
/// builds one for a single row.
final class HistoryRowBuilder {
    /// What a row's standing depends on beyond its own member and catalog
    /// entry, as values.
    struct Context {
        var archivedProjects: Set<ProjectKey> = []
        var openTabs: Set<SessionKey> = []
        var folders: [ProjectKey: DirectoryEvidence] = [:]
        /// Each host's completed listing (`CatalogCompletion.coverage`).
        var coverage: [HostID: CatalogCoverage] = [:]
    }

    let calendar: Calendar
    private let timeFormatter: DateFormatter
    private let dayFormatter: DateFormatter
    private var folderNames: [String: String] = [:]

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "MMM d"
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
    }

    /// "~/Projects/x" for a local path; a remote host's path as it is.
    func folderDisplay(_ key: ProjectKey) -> String {
        guard key.host.isLocal else { return key.path }
        if let hit = folderNames[key.path] { return hit }
        let name = (key.path as NSString).abbreviatingWithTildeInPath
        folderNames[key.path] = name
        return name
    }

    /// The folder a project sits in, home abbreviated: "~/Projects/active".
    func parentFolder(_ key: ProjectKey) -> String {
        let parent = (key.path as NSString).deletingLastPathComponent
        return key.host.isLocal ? (parent as NSString).abbreviatingWithTildeInPath : parent
    }

    func row(member: Session?, catalog: TranscriptSummary?, conflict: JoinConflict?, context: Context) -> HistoryRow {
        precondition(member != nil || catalog != nil)
        precondition(conflict == nil || (member == nil && catalog != nil))
        // Attached to a catalog row, a member shows disk time: its activity
        // is left out so a touch compares equal.
        var member = member
        if let attached = member, catalog != nil, attached.state.lastActiveAt != nil {
            var state = attached.state
            state.lastActiveAt = nil
            member = Session(state: state, resolution: attached.resolution)
        }
        let id = catalog.map(HistoryKey.init) ?? HistoryKey(member!)
        let title = member?.displayTitle ?? catalog!.catalogTitle
        let updatedAt = catalog?.modifiedAt ?? member!.sortDate
        let undated = updatedAt == .distantPast
        let day = undated ? Date.distantPast : calendar.startOfDay(for: updatedAt)
        let project: ProjectKey? = member.map(\.project) ?? catalog.flatMap {
            // No folder at all is "No project", not a key for the empty path ("/").
            $0.catalogDirectory.isEmpty ? nil : ProjectKey(host: $0.locator.host, path: $0.catalogDirectory)
        }

        var standing: HistoryStanding = .outside
        var transcriptMissing = false
        var folderMissing = false
        var kept = false
        var projectArchived = false
        if let conflict {
            standing = .conflict(conflict)
        } else if let member {
            let state = member.state
            projectArchived = project.map { context.archivedProjects.contains($0) } ?? false
            if projectArchived, let project {
                standing = .archived(.withProject(project))
            } else if state.archived {
                standing = .archived(state.archiveReason.map(ArchiveStatus.byTemple) ?? .byUser(at: state.archivedAt))
            } else {
                standing = .inTemple
            }
            let archived = standing != .inTemple
            kept = !archived && state.keptAt != nil
            if catalog == nil {
                transcriptMissing = member.transcriptConfirmedMissing
                    || (member.archivedByTemple && state.archiveReason == .transcriptMissing)
                    || (archived && Self.provenUnlisted(member, context: context))
            }
            folderMissing = (project.map { context.folders[$0] == .missing } ?? false)
                || (member.archivedByTemple && state.archiveReason == .folderMissing)
        }

        let archived: Bool = { if case .archived = standing { return true }; return false }()
        let canResume: Bool = {
            if conflict != nil { return false }
            guard let member else { return catalog != nil }
            return member.canResume && !(archived && (transcriptMissing || folderMissing))
        }()
        let openTab = member.map { context.openTabs.contains(SessionKey(id: $0.id, host: $0.host)) } ?? false
        let canArchive = member != nil && !archived && !openTab
        let tag: HistoryConditionTag? = member == nil ? nil
            : transcriptMissing ? .noTranscript : folderMissing ? .noFolder : nil
        let folder = project.map(folderDisplay) ?? ""
        let membership = Self.membershipTooltip(member?.state, dayFormatter: dayFormatter)
        let statusTooltip: String? = {
            switch standing {
            case .inTemple: return membership
            case .archived(let status): return self.restoreTooltip(status, folder: folder)
            case .conflict(let conflict): return conflict.message
            case .outside: return nil
            }
        }()
        let tagTooltip = tag.map {
            Self.tagTooltip($0, standing: standing, kept: kept, folder: folder, statusTooltip: statusTooltip)
        }

        var details: [String] = []
        if let model = catalog?.model { details.append(model) }
        if let count = catalog?.messageCount { details.append("\(count) messages") }
        let localURL = catalog?.locator.localURL ?? member?.transcript?.localURL
        if let url = localURL { details.append((url.path as NSString).abbreviatingWithTildeInPath) }
        let rowTooltip = [conflict?.message, catalog?.lastMessagePreview, details.joined(separator: " · ")]
            .compactMap { $0 }
            .joined(separator: "\n")
        // The displayed title and every original one the row or its listing
        // has: a renamed session is still found by what it was first called.
        var titles = member?.searchTitles ?? [title]
        for listed in [catalog?.titleFact, catalog?.firstPrompt] {
            if let listed, !listed.isEmpty, !titles.contains(listed) { titles.append(listed) }
        }
        let searchable = (titles + [project?.path ?? "", catalog?.gitBranch ?? "", catalog?.lastMessagePreview ?? ""])
            .joined(separator: "\n").lowercased()

        return HistoryRow(
            id: id, member: member, catalog: catalog, conflict: conflict,
            title: title, updatedAt: updatedAt, day: day,
            timeText: undated ? "" : timeFormatter.string(from: updatedAt),
            project: project, projectName: project?.displayName ?? "No project",
            standing: standing, transcriptMissing: transcriptMissing, folderMissing: folderMissing,
            kept: kept, canResume: canResume,
            hasResumeCommand: !(member.map(SessionLauncher.resumeArgv) ?? catalog.map { $0.agent.resumeArgv(sessionID: $0.id) } ?? []).isEmpty,
            canArchive: canArchive, projectArchived: projectArchived,
            colorMark: member?.state.color.flatMap(TabColorMark.init(rawValue:)),
            statusTooltip: statusTooltip, conditionTag: tag, tagTooltip: tagTooltip,
            membershipTooltip: membership, rowTooltip: rowTooltip,
            searchKey: Array(searchable.utf8), idKey: Array(id.sessionID.lowercased().utf8))
    }

    /// An archived member that a completed listing of its agent found no
    /// file for: the engine no longer watches it, so this is the only verdict
    /// there is (ADR-031). A file that was found but did not read (unreadable,
    /// mismatched, changing) is a candidate, not an absence. An agentless
    /// member needs every agent's listing.
    private static func provenUnlisted(_ member: Session, context: Context) -> Bool {
        guard let complete = context.coverage[member.host] else { return false }
        let agents = member.agent.map { [$0] } ?? Agent.allCases
        return agents.allSatisfy { complete.provesAbsent(member.id, agent: $0) }
    }

    /// "In Temple · opened Sep 25" — how and when it joined, where known.
    static func membershipTooltip(_ state: SessionState?, dayFormatter: DateFormatter) -> String {
        guard let state, let date = state.joinedAt else { return "In Temple" }
        let verb: String
        switch state.joinedVia {
        case .created: verb = "started"
        case .opened: verb = "opened"
        case .imported: verb = "imported"
        case nil: return "In Temple"
        }
        return "In Temple · \(verb) \(dayFormatter.string(from: date))"
    }

    func restoreTooltip(_ status: ArchiveStatus, folder: String) -> String {
        Self.restoreTooltip(status, folder: folder, dayFormatter: dayFormatter)
    }

    /// One sentence of fact, one of what Restore does.
    private static func restoreTooltip(_ status: ArchiveStatus, folder: String,
                                       dayFormatter: DateFormatter? = nil) -> String {
        switch status {
        case .byUser(let at):
            let when = at.flatMap { date in dayFormatter.map { " on \($0.string(from: date))" } } ?? ""
            return "You archived it\(when). Restore puts it back in the sidebar."
        case .byTemple(let reason) where reason == .transcriptMissing:
            return "No transcript on disk carries this session, so Temple archived it; it can't be resumed. Restore puts it back in the sidebar anyway."
        case .byTemple(let reason) where reason == .folderMissing:
            return "The folder \(folder) no longer exists, so Temple archived it. Restore puts it back in the sidebar anyway."
        case .byTemple:
            return "Temple archived it. Restore puts it back in the sidebar."
        case .withProject(let project):
            return "Its project \(project.displayName) is archived. Restore brings back this session; the rest of \(project.displayName) stays archived."
        }
    }

    private static func tagTooltip(_ tag: HistoryConditionTag, standing: HistoryStanding, kept: Bool,
                                   folder: String, statusTooltip: String?) -> String {
        if case .archived(let status) = standing {
            // Temple's own reason already says it; any other archive states
            // the condition, then what Restore does.
            if case .byTemple(let reason) = status,
               (reason == .transcriptMissing && tag == .noTranscript) || (reason == .folderMissing && tag == .noFolder) {
                return statusTooltip ?? ""
            }
            switch tag {
            case .noTranscript:
                return "No transcript on disk carries this session, so it can't be resumed. Restore puts it back in the sidebar anyway."
            case .noFolder:
                return "The folder \(folder) no longer exists. Restore puts it back in the sidebar anyway."
            }
        }
        switch tag {
        case .noTranscript where kept:
            return "No transcript on disk carries this session, so it can't be resumed. You restored it, so it stays in the sidebar."
        case .noTranscript:
            return "The session file is no longer on disk. Opening it will fail; archive it from here."
        case .noFolder:
            return "The folder \(folder) no longer exists. Opening it starts nothing."
        }
    }
}

/// A project in the popup, with how many rows it holds, its name and where
/// it sits, all prepared.
public struct ProjectCount: Equatable, Sendable {
    public let key: ProjectKey
    public var path: String { key.path }
    public let count: Int
    public let displayName: String
    public let parentFolder: String
}
