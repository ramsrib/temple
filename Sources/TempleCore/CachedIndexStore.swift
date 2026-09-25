import Foundation

/// Versioned envelope for the rebuildable session-index startup cache.
struct PersistedIndexCache: Codable {
    /// 2: Codex sessions are keyed by the thread's own id and subagent rollouts
    /// are left out (ADR-024). A version-1 cache still holds each subagent under
    /// its parent's id, and would show it until the first live index lands.
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let savedAt: Date
    let index: SessionIndex
}

/// Where Temple keeps its own state (index cache, SQLite). `TEMPLE_STATE_DIR`
/// redirects it so a demo or test run cannot read or clobber real state.
public enum TempleState {
    public static var directory: URL {
        let url = StoreIO.envRoot("TEMPLE_STATE_DIR") ?? defaultDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The real state directory, the one an installed Temple uses.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Temple", isDirectory: true)
    }

    /// `TEMPLE_STATE_DIR` names a directory other than the real one. An empty
    /// value is no redirect — `directory` falls back to the real state — and
    /// neither is a path that resolves to it, so a tool that must never write
    /// real state can gate on this rather than on the variable being set.
    public static var isRedirected: Bool {
        guard let override = StoreIO.envRoot("TEMPLE_STATE_DIR") else { return false }
        return canonicalPath(override) != canonicalPath(defaultDirectory)
    }

    /// A spelling-proof key for "the same directory", including one that does
    /// not exist yet (a fresh install has no state dir): symlinks are resolved
    /// on the deepest ancestor that exists, and case is folded, because the
    /// default volume is case-insensitive. On a case-sensitive one this can
    /// only make two different paths look alike — for a guard, the safe way
    /// to be wrong.
    static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path.lowercased()
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
