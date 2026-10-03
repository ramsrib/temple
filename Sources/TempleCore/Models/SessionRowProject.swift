import Foundation

/// Row grouping kept distinct from the legacy Project until consumers switch.
public struct SessionRowProject: Identifiable, Equatable, Sendable {
    public let key: ProjectKey
    public let sessions: [Session]
    public init(key: ProjectKey, sessions: [Session]) { self.key = key; self.sessions = sessions }
    public var localDirectoryURL: URL? { key.host.isLocal ? URL(fileURLWithPath: key.path) : nil }
    public var path: String { key.path }
    public var name: String { key.displayName }
    public var id: ProjectKey { key }
    public var lastActivity: Date { sessions.map(\.sortDate).max() ?? .distantPast }

    public static func grouping(_ sessions: [Session]) -> [SessionRowProject] {
        let grouped = Dictionary(grouping: sessions.filter { $0.project != nil }) { $0.project! }
        return grouped.map { key, rows in
            SessionRowProject(key: key, sessions: rows.sorted {
                $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate
            })
        }.sorted {
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            if $0.key.host != $1.key.host { return $0.key.host.rawValue < $1.key.host.rawValue }
            return $0.key.path < $1.key.path
        }
    }
}
