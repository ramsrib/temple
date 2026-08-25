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

    private func templePlists() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return Set(names.filter { $0.hasPrefix("temple.") && $0.hasSuffix(".plist") })
    }

    func testFixtureDefaultsWriteNothingToDisk() {
        let before = templePlists()

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

        XCTAssertEqual(templePlists().subtracting(before), [],
                       "the fixture left preference files behind")
    }

    /// Each call is its own store: one test's writes must never be visible to
    /// another's, which is the reason the fixture exists at all.
    func testEachCallIsIsolated() {
        let first = Fixture.uniqueDefaults()
        let second = Fixture.uniqueDefaults()
        first.set("only mine", forKey: "temple.settings.fontFamily")

        XCTAssertEqual(first.string(forKey: "temple.settings.fontFamily"), "only mine")
        XCTAssertNil(second.string(forKey: "temple.settings.fontFamily"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "temple.settings.fontFamily"))
    }
}
