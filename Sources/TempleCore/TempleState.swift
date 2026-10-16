import Foundation

public enum TempleState {
    /// `TEMPLE_STATE_DIR`, tilde-expanded; unset or empty is no override.
    static var environmentOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["TEMPLE_STATE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var directory: URL {
        let url = environmentOverride ?? (underTest ? testDirectory : defaultDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A test process never reaches the real state: without an explicit
    /// TEMPLE_STATE_DIR it gets a directory of its own under /tmp. XCTest is
    /// loaded only into test bundles' processes, never into the app or tools.
    private static let underTest = NSClassFromString("XCTestCase") != nil
    private static let testDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("temple-test-state-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// The defaults domain Temple's own settings live in: the app's own
    /// (`.standard`), or the suite `TEMPLE_DEFAULTS_SUITE` names, so a demo
    /// never writes the owner's preferences (`make demo` sets it). The one
    /// place Temple obtains its settings' `UserDefaults`. AppKit's own
    /// autosaves (window frames, split view widths, open-panel folders) can
    /// only use `.standard`; see AGENTS.md for how the demo keeps those apart.
    ///
    /// A suite that cannot be opened, or one that names the app's own domain
    /// or the global one, stops the launch rather than falling back: a
    /// redirect that silently reached the real domain is the failure this
    /// variable exists to prevent.
    public static var settingsDefaults: UserDefaults {
        guard let suite = defaultsSuiteOverride else { return .standard }
        guard let defaults = settingsDefaults(suite: suite, open: UserDefaults.init(suiteName:)) else {
            fatalError("TEMPLE_DEFAULTS_SUITE=\(suite) is not a defaults suite Temple can keep apart from the real one")
        }
        return defaults
    }

    /// The suite's defaults, or nil for a suite that names the app's own
    /// domain or the global one, or that `open` cannot open. `open` is a
    /// seam: tests must not create real suites, which leave a plist behind.
    static func settingsDefaults(suite: String, open: (String) -> UserDefaults?) -> UserDefaults? {
        let refused: Set<String> = ["com.sriramb.temple", UserDefaults.globalDomain,
                                    Bundle.main.bundleIdentifier ?? "com.sriramb.temple"]
        guard !refused.contains(suite) else { return nil }
        return open(suite)
    }

    /// `TEMPLE_DEFAULTS_SUITE`; unset or empty is no override.
    public static var defaultsSuiteOverride: String? {
        guard let suite = ProcessInfo.processInfo.environment["TEMPLE_DEFAULTS_SUITE"], !suite.isEmpty else { return nil }
        return suite
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
        guard let override = environmentOverride else { return false }
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

