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

    /// `TEMPLE_DEFAULTS_SUITE` (what `make demo` sets): unset or empty, the
    /// settings are `.standard`; set, they are that suite's, and a suite that
    /// names the real domain or the global one is refused. No real suite is
    /// opened here: one leaves a plist in ~/Library/Preferences for good.
    func testSettingsDefaultsFollowTheSuiteVariable() throws {
        let key = "TEMPLE_DEFAULTS_SUITE"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }

        unsetenv(key)
        XCTAssertNil(TempleState.defaultsSuiteOverride)
        XCTAssertIdentical(TempleState.settingsDefaults, UserDefaults.standard)
        setenv(key, "", 1)
        XCTAssertNil(TempleState.defaultsSuiteOverride)
        XCTAssertIdentical(TempleState.settingsDefaults, UserDefaults.standard)
        setenv(key, "com.sriramb.temple.demo.settings", 1)
        XCTAssertEqual(TempleState.defaultsSuiteOverride, "com.sriramb.temple.demo.settings")

        let stand = try XCTUnwrap(UserDefaults(suiteName: nil))   // a handle on .standard's domain, no new plist
        var opened: [String] = []
        let open: (String) -> UserDefaults? = { opened.append($0); return stand }
        XCTAssertIdentical(TempleState.settingsDefaults(suite: "com.sriramb.temple.demo.settings", open: open), stand)
        XCTAssertNil(TempleState.settingsDefaults(suite: "com.sriramb.temple", open: open))
        XCTAssertNil(TempleState.settingsDefaults(suite: UserDefaults.globalDomain, open: open))
        XCTAssertEqual(opened, ["com.sriramb.temple.demo.settings"], "a refused suite is never opened")
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
