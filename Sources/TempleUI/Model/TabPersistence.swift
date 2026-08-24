import Foundation
import TempleCore

/// A restorable tab descriptor (UX §B "lazy restore"). Codex provisional tabs
/// (no id yet) are never persisted.
public struct PersistedTab: Codable, Equatable {
    public var sessionID: String
    public var agent: String
    public var projectPath: String
    public var title: String
    /// The tab that was on screen when the app was last quit, so a relaunch can
    /// put the user back where they were instead of on the launcher.
    public var isActive: Bool = false

    public init(sessionID: String, agent: Agent, projectPath: String, title: String,
                isActive: Bool = false) {
        self.sessionID = sessionID
        self.agent = agent.rawValue
        self.projectPath = projectPath
        self.title = title
        self.isActive = isActive
    }

    /// Hand-written because a stored-property default does NOT make the
    /// synthesized decoder tolerant of a missing key — it still requires it and
    /// throws `keyNotFound`. `load()` turns any throw into an empty set, so
    /// relying on the default would have silently erased every restored tab the
    /// first time a set written before this field was read back.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agent = try container.decode(String.self, forKey: .agent)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        title = try container.decode(String.self, forKey: .title)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }

    public var resolvedAgent: Agent { Agent(rawValue: agent) ?? .claude }
}

/// Persists per-project open-tab set + order (ADR-009 `open_tabs`, U2).
///
/// The real app uses `DBTabPersistence`; the UserDefaults implementation remains
/// useful for isolated model tests.
@MainActor
public protocol TabPersistence: AnyObject {
    func load() -> [PersistedTab]
    func save(_ tabs: [PersistedTab])
}

@MainActor
public final class DBTabPersistence: TabPersistence {
    private let db: TempleDB

    public init(db: TempleDB) {
        self.db = db
    }

    public func load() -> [PersistedTab] {
        (try? db.openTabRecords().map {
            PersistedTab(
                sessionID: $0.sessionID,
                agent: Agent(rawValue: $0.agent) ?? .claude,
                projectPath: $0.projectPath,
                title: $0.title,
                isActive: $0.isActive
            )
        }) ?? []
    }

    public func save(_ tabs: [PersistedTab]) {
        var positions: [String: Int] = [:]
        let records = tabs.map { tab in
            let position = positions[tab.projectPath, default: 0]
            positions[tab.projectPath] = position + 1
            return OpenTabRecord(
                projectPath: tab.projectPath,
                sessionID: tab.sessionID,
                position: position,
                agent: tab.agent,
                title: tab.title,
                isActive: tab.isActive
            )
        }
        try? db.replaceOpenTabs(records)
    }
}

@MainActor
public final class UserDefaultsTabPersistence: TabPersistence {
    private let defaults: UserDefaults
    private let key = "temple.openTabs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [PersistedTab] {
        guard let data = defaults.data(forKey: key),
              let tabs = try? JSONDecoder().decode([PersistedTab].self, from: data) else { return [] }
        return tabs
    }

    public func save(_ tabs: [PersistedTab]) {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: key)
    }
}
