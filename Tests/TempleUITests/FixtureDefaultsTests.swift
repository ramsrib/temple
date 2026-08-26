import XCTest
@testable import TempleUI

/// Pins the one property that matters about `Fixture.uniqueDefaults()`: it must
/// not leave anything on disk.
///
/// Without this, reverting the fixture to `UserDefaults(suiteName:)` leaves every
/// other test green — the round-trip assertions elsewhere pass either way — and
/// the suite silently goes back to writing a permanent plist per call. That is
/// exactly how 2,853 of them accumulated unnoticed.
@MainActor
final class FixtureDefaultsTests: XCTestCase {
    private var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Only the exact shape the fixture's suites used to take. A broad
    /// `temple.*` match would also catch the real app's own preference file and
    /// fail on someone else's writes; this pattern is ours alone.
    ///
    /// The enumeration is allowed to throw: swallowing the error would make both
    /// snapshots empty and the leak assertion pass without having looked.
    private func fixturePlists() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: preferences.path)
        return Set(names.filter {
            $0.range(of: #"^temple\.tests\.[0-9A-F-]+\.plist$"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
        })
    }

    func testFixtureDefaultsWriteNothingToDisk() throws {
        let before = try fixturePlists()
        // On the run where this test earns its keep, the fixture IS leaking —
        // so clean up whatever appeared, or the test that catches the leak
        // becomes a second source of it, once per failing run.
        defer {
            for name in (try? fixturePlists())?.subtracting(before) ?? [] {
                // Deleting the file is not enough on its own: cfprefsd owns the
                // domain and flushes it back at process exit, which is the same
                // reason sweeping suites at testBundleWillFinish did not work.
                // Drop the domain first, then the file it was writing to.
                let domain = String(name.dropLast(".plist".count))
                UserDefaults.standard.removeSuite(named: domain)
                UserDefaults.standard.removePersistentDomain(forName: domain)
                CFPreferencesAppSynchronize(domain as CFString)
                try? FileManager.default.removeItem(at: preferences.appendingPathComponent(name))
            }
        }

        // Written through, then flushed the way a suite would be — so a
        // reverted fixture really does produce its file before we look.
        for index in 0..<5 {
            let defaults = Fixture.uniqueDefaults()
            defaults.set(Data("tabs".utf8), forKey: "temple.openTabs")
            defaults.set("SF Mono", forKey: "temple.settings.fontFamily")
            defaults.set(13.0, forKey: "temple.settings.fontSize")
            XCTAssertEqual(defaults.data(forKey: "temple.openTabs"), Data("tabs".utf8), "call \(index)")
            _ = defaults.synchronize()
        }

        XCTAssertEqual(try fixturePlists().subtracting(before), [],
                       "the fixture left preference files behind")
    }

    /// Each call is its own store, and none of them reach the real defaults —
    /// the reason the fixture exists at all. The probe key is unique per run so
    /// no leftover state, here or in the standard domain, can decide the result.
    func testEachCallIsIsolatedFromEachOtherAndFromTheRealDomain() {
        let key = "temple.tests.probe.\(UUID().uuidString)"
        let first = Fixture.uniqueDefaults()
        let second = Fixture.uniqueDefaults()
        first.set("only mine", forKey: key)

        XCTAssertEqual(first.string(forKey: key), "only mine")
        XCTAssertNil(second.string(forKey: key))
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }
}
