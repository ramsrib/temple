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
    /// The ⌘P switcher's order: projects most recently used first. Kept beside
    /// the tabs because a relaunch restores both, and the tab set alone cannot
    /// say which project you were in before the one you quit in.
    func loadProjectRecency() -> [ProjectKey]
    func saveProjectRecency(_ keys: [ProjectKey])
}

public extension TabPersistence {
    /// Stores without a place for it start every launch with no recency, which
    /// is what every build before this one did.
    func loadProjectRecency() -> [ProjectKey] { [] }
    func saveProjectRecency(_ keys: [ProjectKey]) {}
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

    /// In `ui_state`, not a new table: a migration would lock every older
    /// build out of the file (`hasBeenSuperseded`), and this is window state
    /// like the sidebar's, isolated by `TEMPLE_STATE_DIR` the same way.
    public func loadProjectRecency() -> [ProjectKey] {
        do {
            return ProjectRecencyCodec.decode(try db.uiState(UIStateStore.Key.projectRecency))
        } catch {
            TempleUILog.db.error(
                "failed to read project recency, starting from tab order: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func saveProjectRecency(_ keys: [ProjectKey]) {
        do {
            try db.setUIState(ProjectRecencyCodec.encode(keys), for: UIStateStore.Key.projectRecency)
        } catch {
            TempleUILog.db.error(
                "failed to persist project recency — it will not survive relaunch: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The stored form of the project recency list: a JSON array of
/// `{"host", "path"}`, most recent first. Spelled out rather than leaning on
/// `ProjectKey`'s synthesized `Codable`, so the bytes on disk don't change
/// shape when that type does.
///
/// Reading never throws. Whatever cannot be read is dropped — an element, or
/// the whole value — and an empty list only means "follow tab order", which
/// is where every launch started before this was kept.
enum ProjectRecencyCodec {
    /// The list only ever holds projects with a tab open (closing a project's
    /// last tab forgets it), so this bounds a hand-edited or runaway value,
    /// not normal use.
    static let limit = 64

    private struct Entry: Encodable {
        var host: String
        var path: String
    }

    /// One element, or nothing: a malformed entry must not take the rest of
    /// the list down with it. A missing host is this Mac's, as it is
    /// everywhere else a host is absent.
    private struct LossyEntry: Decodable {
        private enum CodingKeys: String, CodingKey { case host, path }
        let key: ProjectKey?

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            guard let path = try? container?.decode(String.self, forKey: .path), !path.isEmpty else {
                key = nil
                return
            }
            let host = (try? container?.decodeIfPresent(String.self, forKey: .host)) ?? nil
            key = ProjectKey(host: HostID(rawValue: host ?? HostID.local.rawValue), path: path)
        }
    }

    /// `nil` for an empty list, so it clears the key instead of storing a
    /// stand-in for "nothing".
    static func encode(_ keys: [ProjectKey]) -> String? {
        let entries = deduplicated(keys).map { Entry(host: $0.host.rawValue, path: $0.path) }
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ value: String?) -> [ProjectKey] {
        guard let data = value?.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LossyEntry].self, from: data) else { return [] }
        return deduplicated(entries.compactMap(\.key))
    }

    private static func deduplicated(_ keys: [ProjectKey]) -> [ProjectKey] {
        var seen = Set<ProjectKey>()
        return Array(keys.filter { seen.insert($0).inserted }.prefix(limit))
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
