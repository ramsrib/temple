import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// The strip's leading edge (where the project switcher starts) follows its
/// two inputs, the detail pane's window-space origin and the toolbar items
/// parked at the band's leading side, whenever either moves, not only when
/// the installer itself is laid out.
///
/// Shipped broken: v0.5.0's first launch with no saved frame, sidebar
/// collapsed, had the switcher a sidebar's width out into the band until
/// the window was resized. The strip only re-read the pane's origin when
/// the installer itself was laid out, which a move of an ANCESTOR (the
/// split view settling its columns) never does; nor did a toolbar item
/// settling to its width re-measure the obstruction. The ancestor and
/// toolbar-item tests failed before the strip observed those frames; the
/// window-resize one held already (a resize lays the window out), and
/// keeps the path the report's workaround took.
///
/// A real titled window with the real installer and strip. The installer
/// sits in a holder view standing in for the split view's detail column:
/// moving the holder moves the pane without touching the installer's frame.
@MainActor
final class TitlebarStripLeadingEdgeTests: XCTestCase {
    /// Stands in for AppKit's private toolbar item viewer: the strip
    /// measures views whose class name says `ToolbarItemViewer` and that
    /// have content.
    final class FakeToolbarItemViewer: NSView {}

    private var window: NSWindow!
    private var holder: NSView!
    private var installer: TitlebarTabStripInstaller.InstallerView!

    override func setUp() async throws {
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                             database: try TempleDB.inMemory(),
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.history.catalog = { AsyncStream { $0.finish() } }
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "test")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        window.contentView = content
        // The detail column, a full sidebar's width in: where the split view
        // first laid it out before collapsing the sidebar.
        holder = NSView(frame: NSRect(x: 360, y: 0, width: 640, height: 600))
        content.addSubview(holder)
        installer = TitlebarTabStripInstaller.InstallerView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        installer.model = model
        holder.addSubview(installer)
        window.alphaValue = 0
        window.orderFront(nil)
        pump { (try? self.strip())?.hasClaimedBand == true }
    }

    override func tearDown() async throws {
        window.close()
    }

    private func pump(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func strip() throws -> TabStripContainerView {
        try XCTUnwrap(descendants(of: window.contentView!.superview!)
            .first { $0 is TabStripContainerView } as? TabStripContainerView, "the strip is installed")
    }

    /// The strip's left edge in window coordinates.
    private func stripLeft() throws -> CGFloat {
        let strip = try strip()
        return strip.convert(strip.bounds, to: nil).minX
    }

    /// Waits for the strip's left edge to reach `expected`, without ever
    /// laying out the window by hand: what moves it must be the strip's
    /// own response to the geometry, not the test's layout pass.
    private func assertStripLeft(_ expected: CGFloat, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        pump(2) { ((try? self.stripLeft()).map { abs($0 - expected) < 0.5 }) ?? false }
        XCTAssertEqual(try stripLeft(), expected, accuracy: 0.5, message, file: file, line: line)
    }

    func testTheLeadingEdgeFollowsTheDetailPaneWhenAnAncestorMoves() throws {
        XCTAssertTrue(try strip().hasClaimedBand, "the strip spans the band")
        // No toolbar item to measure: the obstruction is the fixed 190 pt
        // fallback, under the pane's 360.
        try assertStripLeft(364, "past the pane's leading edge")

        // The sidebar collapses: the column slides to the window's edge and
        // the installer's own frame does not change, so nothing lays it out.
        holder.setFrameOrigin(.zero)
        XCTAssertEqual(installer.frame.origin, .zero, "the installer itself did not move")
        try assertStripLeft(194, "back to the window buttons once the pane moved under them")

        // And out again, for an expand.
        holder.setFrameOrigin(NSPoint(x: 300, y: 0))
        try assertStripLeft(304, "out to the pane's new edge")
    }

    func testTheLeadingEdgeFollowsAToolbarItemThatShrinks() throws {
        let band = try XCTUnwrap(descendants(of: window.contentView!.superview!)
            .first { $0.className == "NSToolbarView" }, "the window has a toolbar band")
        holder.setFrameOrigin(.zero)
        try assertStripLeft(194, "the fallback while nothing is measurable")

        // A leading-side item that first lays out oversized, as a viewer can
        // on a cold launch, and then settles to its real width.
        let viewer = FakeToolbarItemViewer(frame: NSRect(x: 80, y: 0, width: 330, height: band.bounds.height))
        viewer.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        band.addSubview(viewer)
        // Joining the band is not a frame change of anything observed;
        // whichever pass measures it next must find it.
        try strip().needsLayout = true
        try assertStripLeft(414, "past the oversized item")

        viewer.setFrameSize(NSSize(width: 100, height: band.bounds.height))
        try assertStripLeft(184, "follows the item as it settles")
    }

    func testTheLeadingEdgeFollowsAWindowResize() throws {
        // A window resize that moves the pane's origin with it: the holder
        // is pinned to the window's right edge, so its origin moves and its
        // size (and the installer's) does not.
        holder.autoresizingMask = [.minXMargin]
        try assertStripLeft(364, "past the pane's leading edge")
        var frame = window.frame
        frame.size.width -= 200
        window.setFrame(frame, display: true)
        XCTAssertEqual(installer.frame.size.width, 640, "the installer's own size did not change")
        try assertStripLeft(194, "follows the pane after the resize")
    }
}
