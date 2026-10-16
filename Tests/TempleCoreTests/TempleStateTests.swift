import XCTest
@testable import TempleCore

final class TempleStateTests: XCTestCase {
    /// Nothing in a test run may resolve to the installed app's state, with
    /// or without TEMPLE_STATE_DIR.
    func testTheSuiteNeverResolvesTheRealStateDirectory() {
        let key = "TEMPLE_STATE_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        for value in [saved, nil] {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
            XCTAssertNotEqual(TempleState.canonicalPath(TempleState.directory),
                              TempleState.canonicalPath(TempleState.defaultDirectory))
            XCTAssertNotEqual(TempleState.canonicalPath(TempleDB.defaultPath().deletingLastPathComponent()),
                              TempleState.canonicalPath(TempleState.defaultDirectory))
        }
    }

    /// `TEMPLE_DEFAULTS_SUITE` (what `make demo` sets): settings written
    /// through `settingsDefaults` land in that suite, never in the process's
    /// own domain; unset or empty, it is `.standard`.
    func testSettingsDefaultsFollowTheSuiteVariable() throws {
        let key = "TEMPLE_DEFAULTS_SUITE"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        let suite = "com.sriramb.temple.test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        unsetenv(key)
        XCTAssertIdentical(TempleState.settingsDefaults, UserDefaults.standard)
        setenv(key, "", 1)
        XCTAssertIdentical(TempleState.settingsDefaults, UserDefaults.standard)

        setenv(key, suite, 1)
        let probe = "templeSuiteProbe-\(UUID().uuidString)"
        TempleState.settingsDefaults.set("written", forKey: probe)
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: probe), "written")
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)?[probe])
        XCTAssertEqual(UserDefaults().persistentDomain(forName: suite)?[probe] as? String, "written")
    }

    /// What `templectl --import-all` gates on. Set, empty and the real
    /// directory spelled another way must all read as "not redirected".
    func testStateIsRedirectedOnlyToADirectoryOtherThanTheRealOne() {
        let key = "TEMPLE_STATE_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }
        let real = TempleState.defaultDirectory.path

        unsetenv(key)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, "", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real, 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real + "/", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real + "/../Temple", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, "~/Library/Application Support/Temple", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, FileManager.default.temporaryDirectory.appendingPathComponent("temple-demo-state").path, 1)
        XCTAssertTrue(TempleState.isRedirected)
    }

    /// A fresh install has no state dir yet, which is exactly when a spelling
    /// of it that Foundation will not resolve could slip past the guard.
    func testCanonicalPathMatchesMissingDirectoriesAcrossCaseAndSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-canonical-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("Real", isDirectory: true)
        let link = base.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        let missing = target.appendingPathComponent("Application Support/Temple")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let recased = URL(fileURLWithPath: missing.path.replacingOccurrences(of: "Real/Application", with: "real/application"))
        let throughLink = link.appendingPathComponent("Application Support/Temple")

        XCTAssertEqual(TempleState.canonicalPath(recased), TempleState.canonicalPath(missing))
        XCTAssertEqual(TempleState.canonicalPath(throughLink), TempleState.canonicalPath(missing))
        XCTAssertNotEqual(TempleState.canonicalPath(base.appendingPathComponent("Other/Temple")),
                          TempleState.canonicalPath(missing))
    }

}
