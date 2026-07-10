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
/// **Seam for Track C5.** `UserDefaults` JSON today; C5's `open_tabs` table
/// implements the same two methods later.
@MainActor
public protocol TabPersistence: AnyObject {
    func load() -> [PersistedTab]
    func save(_ tabs: [PersistedTab])
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
