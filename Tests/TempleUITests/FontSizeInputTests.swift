import XCTest
@testable import TempleUI

/// A non-finite size stored by a build that let "nan" through must not keep
/// crashing Settings: it falls back to the shipped size (without rewriting the
/// key; the commit path now refuses such input, see SettingsEditingTests).
@MainActor
final class FontSizeInputTests: XCTestCase {
    func testANonFiniteStoredSizeFallsBackToTheShippedOne() {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(Double.nan, forKey: "temple.settings.fontSize")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fontSize, SettingsStore.shippedFontSize)
        XCTAssertTrue(store.fontSize.isFinite)
    }
}
