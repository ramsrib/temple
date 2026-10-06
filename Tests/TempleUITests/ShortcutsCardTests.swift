import AppKit
import SwiftUI
import XCTest
@testable import TempleUI

/// The ⌘/ card sizes its panel by its ideal size (the panel is fixed-size):
/// bounded by the window, it must stay within the bound and scroll, and keep
/// its natural height where that fits. An unbounded card in a 653 pt window
/// grew the window-level stack and pushed the split view into the title bar.
@MainActor
final class ShortcutsCardTests: XCTestCase {
    private func idealSize(_ view: ShortcutsView) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = .intrinsicContentSize
        return host.intrinsicContentSize
    }

    func testTheCardKeepsItsNaturalHeightWhenItFits() {
        let natural = idealSize(ShortcutsView())
        XCTAssertGreaterThan(natural.height, 653 - 52 - 2 * ShortcutsView.windowMargin,
                             "the card is taller than a minimum-size window offers, so the bound matters")
        XCTAssertEqual(idealSize(ShortcutsView(maxHeight: natural.height + 200)).height, natural.height, accuracy: 0.5)
        XCTAssertEqual(natural.width, 540, accuracy: 0.5)
    }

    func testABoundedCardIsNoTallerThanItsBound() {
        for bound in [300.0, 450.0, 553.0] {
            let size = idealSize(ShortcutsView(maxHeight: bound))
            XCTAssertLessThanOrEqual(size.height, bound + 0.5, "bound \(bound)")
            XCTAssertGreaterThan(size.height, bound - 1, "and uses the room it has, scrolling the rest")
            XCTAssertEqual(size.width, 540, accuracy: 0.5)
        }
    }
}
