import Foundation
import TempleCore

/// A restorable tab descriptor (UX §B "lazy restore"). Codex provisional tabs
/// (no id yet) are never persisted.
public struct PersistedTab: Codable, Equatable {
    public var sessionID: String
    public var agent: String
    public var projectPath: String
    public var title: String

    public init(sessionID: String, agent: Agent, projectPath: String, title: String) {
        self.sessionID = sessionID
        self.agent = agent.rawValue
        self.projectPath = projectPath
        self.title = title
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
                title: $0.title
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
                title: tab.title
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
