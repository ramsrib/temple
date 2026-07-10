import Foundation

/// Versioned envelope for the rebuildable session-index startup cache.
struct PersistedIndexCache: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    let index: SessionIndex
}

/// Loads and saves the rebuildable session index used to make cold launch fast.
public final class CachedIndexStore {
    /// The cache file beside Temple's SQLite application-state store.
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Temple", isDirectory: true)
        .appendingPathComponent("index-cache.json")

    private init() {}

    /// Returns a compatible cached index, or `nil` for every unavailable or
    /// invalid-cache condition so startup always falls back to the filesystem.
    public static func load(from url: URL = defaultURL) -> SessionIndex? {
        do {
            let data = try Data(contentsOf: url)
            let cache = try JSONDecoder().decode(PersistedIndexCache.self, from: data)
            guard cache.schemaVersion == PersistedIndexCache.currentSchemaVersion else {
                return nil
            }
            return cache.index
        } catch {
            return nil
        }
    }

    /// Atomically saves a complete snapshot, creating its parent directory when
    /// necessary. Session files remain the source of truth.
    public static func save(_ index: SessionIndex, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cache = PersistedIndexCache(
            schemaVersion: PersistedIndexCache.currentSchemaVersion,
            savedAt: Date(),
            index: index
        )
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}
