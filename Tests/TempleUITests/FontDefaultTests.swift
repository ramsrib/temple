import XCTest
@testable import TempleUI

/// The shipped default is Ghostty's built-in font, named honestly and never
/// warned about. It used to be "SF Mono", which is not an installed family on
/// macOS (it lives inside Terminal.app): every terminal fell back to the
/// built-in font while Settings claimed SF Mono, and the font check would have
/// warned everyone on first open.
@MainActor
final class FontDefaultTests: XCTestCase {
    func testTheShippedFontIsTheBuiltInOneAndIsNeverWarnedAbout() {
        let fresh = SettingsStore(defaults: Fixture.uniqueDefaults())
        XCTAssertEqual(fresh.fontFamily, "")
        XCTAssertNil(fresh.appearance(scheme: .dark).fontFamily, "empty must reach Ghostty as its default")
        XCTAssertNil(FontFamilyCheck.verdict(for: fresh.fontFamily, isInstalled: { _ in false }))
    }

    func testAStoredFontChoiceIsKept() {
        let chosen = Fixture.uniqueDefaults()
        chosen.set("Menlo", forKey: "temple.settings.fontFamily")
        XCTAssertEqual(SettingsStore(defaults: chosen).fontFamily, "Menlo")
    }
}
