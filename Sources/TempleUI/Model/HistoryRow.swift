import Foundation
import TempleCore

/// History's union: durable member presentation plus optional catalog facts.
public struct HistoryRow: Identifiable, Equatable, Sendable {
    public let member: Session?
    public let catalog: TranscriptSummary?
    public init(member: Session? = nil, catalog: TranscriptSummary? = nil) {
        precondition(member != nil || catalog != nil)
        self.member = member
        self.catalog = catalog
    }
    public var id: String { member?.id ?? catalog!.id }
    public var title: String { member?.displayTitle ?? catalog!.catalogTitle }
    public var agent: Agent? { member != nil ? member?.agent : catalog?.agent }
    public var project: ProjectKey? { member != nil ? member?.project : catalog.map { ProjectKey(host: $0.locator.host, path: $0.catalogDirectory) } }
    public var projectPath: String { project?.path ?? "" }
    public var updatedAt: Date { catalog?.modifiedAt ?? member!.sortDate }
    public var canResume: Bool { member?.canResume ?? (catalog != nil) }
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
