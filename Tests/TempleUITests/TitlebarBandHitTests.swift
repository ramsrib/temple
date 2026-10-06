import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// The tab strip in a real titled window's title bar: a click on the empty
/// band goes to the window content under it (as in a window without the
/// strip, where AppKit's double-click-to-zoom works reliably), and a click
/// on a chip goes to the chip.
@MainActor
final class TitlebarBandHitTests: XCTestCase {
    /// Stands in for the split view under the band.
    private final class Content: NSView {}

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    func testAnEmptyBandClickGoesToTheContentAndAChipClickToTheChip() throws {
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                             database: try TempleDB.inMemory(),
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.history.catalog = { AsyncStream { $0.finish() } }
        model.openSessions.openHistory()         // one chip in the strip

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "test")
        let content = Content()
        window.contentView = content
        let strip = TabStripContainerView(model: model)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = strip
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        strip.detailMinX = 280

        // The claim and SwiftUI's chip layout both land on layout passes.
        // The chips row is the hosting view inside the scrolling clip; the
        // pinned project switcher and the `+` sit directly in the strip.
        let chip: () -> NSView? = {
            self.descendants(of: strip).first {
                $0 is NSHostingView<AnyView> && $0.superview !== strip && $0.frame.width > 20
            }
        }
        pump {
            window.layoutIfNeeded()
            return strip.hasClaimedBand && chip() != nil
        }
        XCTAssertTrue(strip.hasClaimedBand, "the strip spans the band")
        let host = try XCTUnwrap(chip(), "SwiftUI laid out no chip")
        XCTAssertTrue(host.superview?.superview === strip, "the chips row, inside the scrolling clip")
        let clip = try XCTUnwrap(strip.superview)

        // Empty band: right of every chip, left of the trailing cluster.
        let empty = clip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), from: strip)
        XCTAssertFalse(host.convert(host.bounds, to: clip).contains(empty), "the probe point is off the chip")
        let emptyHit = strip.hitTest(empty)
        XCTAssertTrue(emptyHit === content, "the empty band hands the click to the content beneath, got \(String(describing: emptyHit))")

        // On the History chip (the row's only one, at its leading edge):
        // the chip takes it.
        let onChip = clip.convert(NSPoint(x: host.bounds.minX + 20, y: host.bounds.midY), from: host)
        let chipHit = try XCTUnwrap(strip.hitTest(onChip), "a chip click must not fall through")
        XCTAssertTrue(chipHit === host || chipHit.isDescendant(of: host), "got \(chipHit)")
    }
}
