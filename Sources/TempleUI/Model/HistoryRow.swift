import Foundation
import TempleCore

/// History's union: durable member presentation plus optional catalog facts.
public struct HistoryRow: Identifiable, Equatable, Sendable {
    public let member: Session?
    public let catalog: AgentSession?
    public init(member: Session? = nil, catalog: AgentSession? = nil) {
        precondition(member != nil || catalog != nil)
        self.member = member
        self.catalog = catalog
    }
    public var id: String { member?.id ?? catalog!.id }
    public var title: String { member?.displayTitle ?? catalog!.title }
    public var agent: Agent? { member != nil ? member?.agent : catalog?.agent }
    public var project: ProjectKey? { member != nil ? member?.project : catalog.map { ProjectKey(host: .local, path: $0.projectPath) } }
    public var projectPath: String { project?.path ?? "" }
    public var updatedAt: Date { catalog?.updatedAt ?? member!.sortDate }
    public var canResume: Bool { member?.canResume ?? (catalog != nil) }
    public var transcriptMissing: Bool { catalog == nil && member?.resolution == .confirmedAbsent }
    public var localURL: URL? { catalog?.filePath ?? member?.transcript?.localURL }
    public var gitBranch: String? { catalog?.gitBranch }
    public var model: String? { catalog?.model }
    public var messageCount: Int? { catalog?.messageCount }
    public var lastMessagePreview: String? { catalog?.lastMessagePreview }
    public var resumeArgv: [String] {
        if let member { return SessionLauncher.resumeArgv(member) }
        return catalog?.resume.argv ?? []
    }
}
