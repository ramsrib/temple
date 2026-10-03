import Foundation

/// Row grouping kept distinct from the legacy Project until consumers switch.
public struct SessionRowProject: Identifiable, Equatable, Sendable {
    public let key: ProjectKey
    public let sessions: [Session]
    public init(key: ProjectKey, sessions: [Session]) {
        self.key = key; self.sessions = sessions
        self.lastActivity = sessions.map(\.sortDate).max() ?? .distantPast
    }
    public var localDirectoryURL: URL? { key.host.isLocal ? URL(fileURLWithPath: key.path) : nil }
    public var path: String { key.path }
    public var name: String { key.displayName }
    public var id: ProjectKey { key }
    public let lastActivity: Date

    public static func grouping(_ sessions: [Session]) -> [SessionRowProject] {
        let grouped = Dictionary(grouping: sessions.filter { $0.project != nil }) { $0.project! }
        return grouped.map { key, rows in
            SessionRowProject(key: key, sessions: rows.sorted {
                $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate
            })
        }.sorted(by: moreRecent)
    }

    public static func moreRecent(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.key.host != rhs.key.host { return lhs.key.host.rawValue < rhs.key.host.rawValue }
        return lhs.key.path < rhs.key.path
    }
}
