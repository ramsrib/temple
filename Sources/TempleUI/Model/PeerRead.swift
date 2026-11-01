import Foundation
import TempleCore

/// One of another Temple's own sessions, as History's page for its host
/// shows it (docs/designs/open-existing-sessions.md section 1). Read from
/// that Temple's database; never written here except by a join.
public struct PeerRow: Equatable, Sendable {
    /// The host whose Temple listed it.
    public let host: HostID
    public let id: String
    public let agent: Agent
    /// Where it runs on that host: the other Temple's word, used only as
    /// where a launch starts.
    public let directory: String
    public let transcriptPath: String?
    public let customName: String?
    public let title: String?
    public let color: String?
    /// Archived there: the session itself or its project.
    public let archivedThere: Bool
    /// The other Temple has a saved tab for it (not proof one runs).
    public let tabThere: Bool
    public let lastActiveAt: Date?
    /// The host's configuration this row was read under (History stamps it
    /// when the read lands): an action on it is refused once the host is
    /// another configuration, whatever has been read since.
    public internal(set) var readUnder: Int?

    public init(host: HostID, id: String, agent: Agent, directory: String, transcriptPath: String? = nil,
                customName: String? = nil, title: String? = nil, color: String? = nil,
                archivedThere: Bool = false, tabThere: Bool = false, lastActiveAt: Date? = nil) {
        self.host = host; self.id = id; self.agent = agent; self.directory = directory; self.transcriptPath = transcriptPath
        self.customName = customName; self.title = title; self.color = color
        self.archivedThere = archivedThere; self.tabThere = tabThere; self.lastActiveAt = lastActiveAt
    }

    /// What the other Temple shows: its name, else its title, else the
    /// agent's placeholder (`Session.displayTitle`'s chain).
    public var displayTitle: String { customName ?? title ?? agent.newSessionTitle }

    /// The name and colour an import or an open brings with it.
    public var marks: CarriedMarks { CarriedMarks(name: customName, color: color) }
    public var key: HistoryKey { HistoryKey(host: host, agent: agent, sessionID: id) }
    public var project: ProjectKey { ProjectKey(host: host, path: directory) }
    public var locator: TranscriptLocator? { transcriptPath.map { TranscriptLocator(host: host, path: $0) } }
}

/// One read of another Temple: what History lists for its host.
public struct PeerListing: Equatable, Sendable {
    public let sessions: [PeerRow]
    /// Rows left out as unusable.
    public let skipped: Int
    public init(sessions: [PeerRow], skipped: Int = 0) { self.sessions = sessions; self.skipped = skipped }
}

/// What asking a host for its Temple came to.
public enum PeerRead: Equatable, Sendable {
    case listed(PeerListing)
    case noTemple
    case noReader
    case needsOpen
    case incompatible
    case tooLarge
    /// sqlite3's words, or "it was busy".
    case unreadable(String)
    /// The host couldn't be reached: the transport's first line.
    case unreachable(String)
}
