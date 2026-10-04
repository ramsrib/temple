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

/// History's union: durable member presentation plus optional catalog facts.
public struct HistoryRow: Identifiable, Equatable, Sendable {
    public let member: Session?
    public let catalog: TranscriptSummary?
    /// A catalog row whose id is already Temple's on another host, or as
    /// another agent: shown as the catalog has it, never attached to that
    /// member, and never imported or opened from here.
    public let conflict: JoinConflict?

    public init(member: Session? = nil, catalog: TranscriptSummary? = nil, conflict: JoinConflict? = nil) {
        precondition(member != nil || catalog != nil)
        precondition(conflict == nil || (member == nil && catalog != nil))
        self.member = member
        self.catalog = catalog
        self.conflict = conflict
    }

    /// The catalog's key when there is one (a member attaches to a catalog
    /// row only when host and known agent match), else the member's.
    public var id: HistoryKey { catalog.map(HistoryKey.init) ?? HistoryKey(member!) }
    public var sessionID: String { member?.id ?? catalog!.id }
    public var host: HostID { id.host }
    public var title: String { member?.displayTitle ?? catalog!.catalogTitle }
    public var agent: Agent? { member != nil ? member?.agent : catalog?.agent }
    public var project: ProjectKey? {
        if let member { return member.project }
        // No folder at all is "No project", not a key for the empty path ("/").
        return catalog.flatMap { $0.catalogDirectory.isEmpty ? nil : ProjectKey(host: $0.locator.host, path: $0.catalogDirectory) }
    }
    public var projectPath: String { project?.path ?? "" }
    public var updatedAt: Date { catalog?.modifiedAt ?? member!.sortDate }
    public var isMember: Bool { member != nil }
    /// Outside Temple and free to join from this row.
    public var canImport: Bool { member == nil && conflict == nil }
    public var canResume: Bool { conflict == nil && (member?.canResume ?? (catalog != nil)) }
    public var transcriptMissing: Bool { catalog == nil && member?.resolution == .confirmedAbsent }
    public var localURL: URL? { catalog?.locator.localURL ?? member?.transcript?.localURL }
    public var gitBranch: String? { catalog?.gitBranch }
    public var model: String? { catalog?.model }
    public var messageCount: Int? { catalog?.messageCount }
    public var lastMessagePreview: String? { catalog?.lastMessagePreview }
    public var resumeArgv: [String] {
        if let member { return SessionLauncher.resumeArgv(member) }
        return catalog.map { $0.agent.resumeArgv(sessionID: $0.id) } ?? []
    }
}
