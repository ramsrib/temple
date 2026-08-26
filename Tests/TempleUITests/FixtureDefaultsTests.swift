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

    /// The canonical UUID grammar, not a loose character class: cleanup below
    /// deletes a persistent domain, and `[0-9A-F-]+` would also accept
    /// `temple.tests.face.plist` — someone else's domain, destroyed by a test
    /// that does not own it.
    ///
    /// The enumeration is allowed to throw: swallowing the error would make both
    /// snapshots empty and the leak assertion pass without having looked.
    private func fixturePlists() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: preferences.path)
        return Set(names.filter {
            $0.range(of: #"^temple\.tests\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.plist$"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
        })
    }

    /// Written into every defaults object this test makes, so cleanup can prove
    /// a domain is one of ours before removing it. A name that merely looks
    /// right is not ownership — a concurrent run's file matches the pattern too.
    private static let sentinelKey = "temple.tests.sentinel"

    func testFixtureDefaultsWriteNothingToDisk() throws {
        let before = try fixturePlists()
        let sentinel = UUID().uuidString
        // Best effort, and no more than that. On the run where this test earns
        // its keep the fixture IS writing plists, and cfprefsd owns them: it
        // flushes the domains it has cached back to disk at process exit, after
        // any cleanup this process can run. Measured three ways now — the
        // testBundleWillFinish sweep, a plain unlink here, and this — the files
        // can still return. So the assertion names them, and this removes what
        // it can.
        defer {
            for name in (try? fixturePlists())?.subtracting(before) ?? [] {
                let domain = String(name.dropLast(".plist".count))
                // Ownership, not resemblance: removePersistentDomain is
                // destructive, so only touch a domain carrying THIS run's
                // sentinel — a parallel run's file looks identical from outside.
                // Read the plist directly rather than through
                // `UserDefaults(suiteName:)`, which would re-register the domain
                // with cfprefsd just to ask whose it is.
                let contents = NSDictionary(
                    contentsOf: preferences.appendingPathComponent(name))
                guard contents?[Self.sentinelKey] as? String == sentinel else { continue }
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
            defaults.set(sentinel, forKey: Self.sentinelKey)
            defaults.set(Data("tabs".utf8), forKey: "temple.openTabs")
            defaults.set("SF Mono", forKey: "temple.settings.fontFamily")
            defaults.set(13.0, forKey: "temple.settings.fontSize")
            XCTAssertEqual(defaults.data(forKey: "temple.openTabs"), Data("tabs".utf8), "call \(index)")
            _ = defaults.synchronize()
        }

        let leaked = try fixturePlists().subtracting(before)
        XCTAssertEqual(leaked, [], """
            Fixture.uniqueDefaults() is writing preference files again. \
            Delete these from ~/Library/Preferences if they outlive the run \
            (cfprefsd rewrites them at exit, so cleanup here cannot be sure): \
            \(leaked.sorted().joined(separator: ", "))
            """)
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
