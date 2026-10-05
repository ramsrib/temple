import Foundation

/// Durable row presentation, independent of transcript availability.
public struct Session: Identifiable, Hashable, Sendable {
    public let state: SessionState
    public let resolution: MemberResolution?

    public init(state: SessionState, resolution: MemberResolution? = nil) {
        self.state = state
        self.resolution = resolution
    }

    public var id: String { state.id }
    public var agent: Agent? { state.agent }
    public var host: HostID { state.host }
    public var directory: String? { state.directory }
    public var project: ProjectKey? { directory.map { ProjectKey(host: host, path: $0) } }
    public var canResume: Bool { agent != nil && directory != nil }
    public var displayTitle: String {
        state.customName ?? state.title ?? agent.map(\.newSessionTitle) ?? "Untitled session"
    }
    public var sortDate: Date { state.lastActiveAt ?? state.lastOpenedAt ?? state.joinedAt ?? .distantPast }
    /// The engine finished looking and no transcript carries this id: the
    /// row stays, but nothing on disk can resume it (pruned, or deleted).
    public var transcriptConfirmedMissing: Bool { resolution == .confirmedAbsent }
    /// Archived by Temple, not by the user: the CLI had removed its
    /// transcript (ADR-030). It comes back on its own if the file does.
    public var archivedByTemple: Bool { state.archived && state.archiveReason != nil }
    public var transcript: TranscriptLocator? {
        guard case .loaded(let locator) = resolution, locator.host == host else { return nil }
        return locator
    }
}
