import Foundation

/// Row-side presentation. Legacy TranscriptSummary consumers switch in later phases.
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
        state.customName ?? state.title ?? agent.map { "New \($0.displayName) session" } ?? "Untitled session"
    }
    public var sortDate: Date { state.lastActiveAt ?? state.lastOpenedAt ?? state.joinedAt ?? .distantPast }
    public var transcript: TranscriptLocator? {
        guard case .loaded(let url) = resolution else { return nil }
        return TranscriptLocator(host: host, path: url.path)
    }
}
