import Foundation

/// Versioned envelope for the rebuildable session-index startup cache.
struct PersistedIndexCache: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    let index: SessionIndex
}

/// Where Temple keeps its own state (index cache, SQLite). `TEMPLE_STATE_DIR`
/// redirects it so a demo or test run cannot read or clobber real state.
public enum TempleState {
    public static var directory: URL {
        let url: URL
        if let override = StoreIO.envRoot("TEMPLE_STATE_DIR") {
            url = override
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Temple", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Loads and saves the rebuildable session index used to make cold launch fast.
public final class CachedIndexStore {
    /// The cache file beside Temple's SQLite application-state store.
    public static var defaultURL: URL {
        TempleState.directory.appendingPathComponent("index-cache.json")
    }

    private init() {}

    /// Returns a compatible cached index, or `nil` for every unavailable or
    /// invalid-cache condition so startup always falls back to the filesystem.
    public static func load(from url: URL = defaultURL) -> SessionIndex? {
        do {
            let data = try Data(contentsOf: url)
            let cache = try JSONDecoder().decode(PersistedIndexCache.self, from: data)
            guard cache.schemaVersion == PersistedIndexCache.currentSchemaVersion else {
                TempleCoreLog.cache.error("cache schema mismatch at \(url.path, privacy: .public): found=\(cache.schemaVersion) expected=\(PersistedIndexCache.currentSchemaVersion)")
                return nil
            }
            return cache.index
        } catch {
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                TempleCoreLog.cache.error("failed to load cache at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// Atomically saves a complete snapshot, creating its parent directory when
    /// necessary. Session files remain the source of truth.
    public static func save(_ index: SessionIndex, to url: URL = defaultURL) throws {
        do {
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
        } catch {
            TempleCoreLog.cache.error("failed to save cache at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
