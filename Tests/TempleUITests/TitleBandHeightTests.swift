import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// The title band is one height in every state and window size, the tab
/// strip fills exactly that band, and the detail pane (whose top edge is
/// where `MainContentView` draws the band's divider) starts at the band's
/// bottom: the divider is always below the chips, never through them.
///
/// Shipped broken: Home with History and Settings open but inactive, at
/// 900 x 652. The launcher's content (five recent projects) was taller than
/// the pane, so the pane's flexible frame grew to the content and was
/// centred on the pane, overhanging it by half the excess at each end. The
/// divider rides that frame's top edge, so it was drawn 22 pt up into the
/// band, through the chip labels. The band itself never moved. With a tab
/// active (History, Settings) or a taller window, nothing overflowed.
///
/// A real titled window with the app's split view and the real strip, as
/// in TitleBandDoubleClickTests.
@MainActor
final class TitleBandHeightTests: XCTestCase {
    /// Records window drags instead of running AppKit's drag loop.
    final class DragRecordingWindow: NSWindow {
        var drags = 0
        override func performDrag(with event: NSEvent) { drags += 1 }
    }

    private var model: AppModel!
    private var window: DragRecordingWindow!

    override func setUp() async throws {
        let database = try TempleDB.inMemory()
        // Five projects with a session each fill the launcher's Recent list,
        // as on any machine that has been used: that is what makes the
        // launcher taller than a 600 pt pane.
        for index in 1...5 {
            try database.join(sessionID: "s\(index)", via: .opened, agent: .claude,
                              core: SessionCore(directory: "/private/tmp/project-\(index)",
                                                directorySource: .tab, title: "Session \(index)",
                                                lastActiveAt: Date(timeIntervalSince1970: Double(index))))
        }
        model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                         engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                         database: database,
                         settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                         hostRegistry: Fixture.hostsWithoutFolderEvidence())
        model.history.catalog = { AsyncStream { $0.finish() } }
        // AppStartup's root, minus its launch side effects.
        let root = NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView().navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            MainContentView()
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(model)
        .frame(minWidth: 900, minHeight: 600)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = [.toolbars]
        window = DragRecordingWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 652),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.alphaValue = 0
        window.orderFront(nil)
        pump(1.0)
    }

    override func tearDown() async throws {
        window.close()
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private var frameView: NSView { window.contentView!.superview! }

    /// What one state measures, in window coordinates (y up).
    private struct Band: CustomStringConvertible {
        /// Window top minus the content layout rect's top.
        let height: CGFloat
        /// The strip's frame.
        let strip: NSRect
        /// The detail pane's frame as `MainContentView` lays it out: the
        /// installer is that frame's background, and the divider is that
        /// frame's top-aligned overlay, so its top IS the divider's y.
        let pane: NSRect
        /// Where the band ends: the top of the content layout rect.
        let bottom: CGFloat
        var description: String { "band \(height) (bottom \(bottom)), strip \(strip), pane \(pane)" }
    }

    private func measure() throws -> Band {
        let strip = try XCTUnwrap(descendants(of: frameView).first { $0 is TabStripContainerView },
                                  "the strip is installed")
        let installer = try XCTUnwrap(
            descendants(of: frameView).first { $0 is TitlebarTabStripInstaller.InstallerView },
            "the detail pane's installer is in the window")
        let bottom = window.contentLayoutRect.maxY
        return Band(height: window.frame.height - bottom,
                    strip: strip.convert(strip.bounds, to: nil),
                    pane: installer.convert(installer.bounds, to: nil),
                    bottom: bottom)
    }

    private func setContentSize(_ size: NSSize) {
        window.setContentSize(size)
        pump(0.4)
    }

    private func settle() { pump(0.4) }

    /// The band's invariants in one state; returns its height for comparing
    /// states with each other.
    @discardableResult
    private func assertBand(_ state: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let band = try measure()
        let label = "\(state) at \(window.frame.size): \(band)"
        XCTAssertGreaterThan(band.height, 40, "the band has its toolbar height: \(label)", file: file, line: line)
        XCTAssertEqual(band.strip.minY, band.bottom, accuracy: 0.5,
                       "the strip ends where the band does: \(label)", file: file, line: line)
        XCTAssertEqual(band.strip.maxY, window.frame.height, accuracy: 0.5,
                       "the strip starts at the window's top: \(label)", file: file, line: line)
        XCTAssertEqual(band.pane.maxY, band.bottom, accuracy: 0.5,
                       "the detail pane, and so its divider, starts at the band's bottom: \(label)",
                       file: file, line: line)
        XCTAssertLessThanOrEqual(band.pane.maxY, band.strip.minY + 0.5,
                                 "the divider is below the chips: \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(band.pane.minY, -0.5,
                                    "the pane does not overhang the window's bottom: \(label)",
                                    file: file, line: line)
        return band.height
    }

    // MARK: The launcher's own content

    /// The frame, in window coordinates, of the launcher view marked `id`.
    private func marked(_ id: NSUserInterfaceItemIdentifier) throws -> NSRect {
        let view = try XCTUnwrap(descendants(of: frameView).first { $0.identifier == id },
                                 "\(id.rawValue) is in the window")
        return view.convert(view.bounds, to: nil)
    }

    private func markedView(_ id: NSUserInterfaceItemIdentifier) throws -> NSView {
        try XCTUnwrap(descendants(of: frameView).first { $0.identifier == id }, "\(id.rawValue) is in the window")
    }

    /// The part of `view` that can show on screen, in window coordinates:
    /// its frame cut by every ancestor that clips to its bounds.
    private func shownRect(of view: NSView) -> NSRect {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: nil)) }
            ancestor = current.superview
        }
        return rect
    }

    /// The launcher's scroll view: the one whose page carries the drag view.
    private func launcherScrollView() throws -> NSScrollView {
        let drag = try XCTUnwrap(descendants(of: frameView).first { $0.className.contains("DraggableStripView") },
                                 "the launcher's drag view is in the window")
        var view: NSView? = drag
        while let current = view, !(current is NSScrollView) { view = current.superview }
        return try XCTUnwrap(view as? NSScrollView, "the launcher's page is in a scroll view")
    }

    /// The visible part of the launcher, in window coordinates.
    private func launcherViewport() throws -> NSRect {
        let scroll = try launcherScrollView()
        var rect = scroll.convert(scroll.bounds, to: nil)
        rect.size.height -= scroll.contentInsets.top + scroll.contentInsets.bottom
        rect.origin.y += scroll.contentInsets.bottom
        return rect
    }

    /// A mouse-wheel scroll of `lines` (negative: towards the end) at a
    /// window point, delivered as AppKit delivers one: to the view under it.
    private func scrollWheel(at point: NSPoint, lines: Int32) throws {
        let screen = window.convertPoint(toScreen: point)
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                          wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        event.location = CGPoint(x: screen.x, y: primary - screen.y)
        let nsEvent = try XCTUnwrap(NSEvent(cgEvent: event))
        let target = try XCTUnwrap(frameView.hitTest(frameView.convert(point, from: nil)),
                                   "something is under the scroll point")
        target.scrollWheel(with: nsEvent)
        pump(0.3)
    }

    /// The launcher in Home: its viewport starts at the band's bottom; the
    /// masthead sits the band gap below it (exactly, when the page overflows
    /// and is at the top); the last Recent project row is on screen or
    /// scrolls into view with the wheel; and a drag on empty page still
    /// moves the window.
    private func assertTheLauncher(_ tag: String, overflows: Bool,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let bandBottom = window.contentLayoutRect.maxY
        let viewport = try launcherViewport()
        XCTAssertEqual(viewport.maxY, bandBottom, accuracy: 0.5,
                       "the launcher's viewport starts at the band's bottom at \(tag): \(viewport)",
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(viewport.minY, -0.5, "and ends inside the window at \(tag)", file: file, line: line)

        let mastheadTop = try marked(LauncherView.mastheadMarker).maxY
        if overflows {
            XCTAssertEqual(mastheadTop, bandBottom - LauncherView.topGap, accuracy: 1,
                           "the overflowing page starts the band gap below the band at \(tag)", file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(mastheadTop, bandBottom - LauncherView.topGap + 1,
                                     "the masthead is at least the gap below the band at \(tag)", file: file, line: line)
        }

        let scroll = try launcherScrollView()
        let clipBefore = scroll.contentView.bounds.origin.y
        if overflows {
            XCTAssertLessThan(try marked(LauncherView.recentMarker).minY, viewport.minY,
                              "the last Recent row starts out below the viewport at \(tag)", file: file, line: line)
            // An empty point on the page, right of the rows' column.
            try scrollWheel(at: NSPoint(x: viewport.maxX - 20, y: viewport.midY), lines: -40)
            XCTAssertNotEqual(scroll.contentView.bounds.origin.y, clipBefore,
                              "the wheel scrolls the launcher at \(tag)", file: file, line: line)
        }
        // Scrolled or not, nothing of the launcher shows in the band. The
        // scroll view itself runs under the band (SwiftUI extends it into
        // the safe area, insetting its content), so this is a question of
        // what clips it, not of where it is: scrolled to the end, the
        // masthead is above the band's bottom edge, and must be cut off there.
        let masthead = try markedView(LauncherView.mastheadMarker)
        let mastheadFrame = masthead.convert(masthead.bounds, to: nil)
        if overflows {
            XCTAssertGreaterThan(mastheadFrame.maxY, bandBottom,
                                 "scrolled to the end, the masthead has moved up past the band's edge at \(tag)",
                                 file: file, line: line)
        }
        let shown = shownRect(of: masthead)
        XCTAssertTrue(shown.isEmpty || shown.maxY <= bandBottom + 0.5,
                      "no launcher content in the band at \(tag): masthead \(mastheadFrame) shows as \(shown)",
                      file: file, line: line)
        let page = shownRect(of: try XCTUnwrap(scroll.documentView, file: file, line: line))
        XCTAssertLessThanOrEqual(page.maxY, bandBottom + 0.5,
                                 "the launcher's page is cut off at the band's bottom at \(tag): shows as \(page)",
                                 file: file, line: line)

        // The Recent list's bottom is its last row's.
        let recent = try marked(LauncherView.recentMarker)
        XCTAssertGreaterThanOrEqual(recent.minY, viewport.minY - 0.5,
                      "the last Recent row is reachable at \(tag): list \(recent), viewport \(viewport)",
                      file: file, line: line)

        // Empty page, right of the rows' column: a press and a drag move the
        // window. Delivered as AppKit delivers them, to the hit view (the
        // test app is never active, so the window itself would spend the
        // click on activation): the point is that the scroll view leaves
        // the drag view as the hit, and that view still drags the window.
        let drags = window.drags
        let point = NSPoint(x: viewport.maxX - 20, y: viewport.midY)
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(point, from: nil)), file: file, line: line)
        XCTAssertTrue(hit.className.contains("DraggableStripView"),
                      "empty launcher page is the drag view at \(tag), got \(hit)", file: file, line: line)
        for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 8.0), (.leftMouseUp, 8.0)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: point.x + offset, y: point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            switch type {
            case .leftMouseDown: hit.mouseDown(with: event)
            case .leftMouseDragged: hit.mouseDragged(with: event)
            default: hit.mouseUp(with: event)
            }
        }
        XCTAssertEqual(window.drags, drags + 1, "a drag on empty launcher page moves the window at \(tag)",
                       file: file, line: line)

        // Back to the top for the next state.
        if overflows { try scrollWheel(at: point, lines: 40) }
    }

    /// TitleBandDoubleClick's classification with the launcher pinned to
    /// the pane: every band point clear of a control is empty band, over the
    /// sidebar and over the detail side, and every chip and band control is not.
    private func assertTheOwnerClassifiesTheBand(_ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(TitleBandDoubleClick.isInstalled(on: window), file: file, line: line)
        let y = (window.contentLayoutRect.maxY + window.frame.height) / 2
        let controls = descendants(of: frameView)
            .filter { $0 is TitleBandControl && !$0.isHidden && $0.frame.width > 0 }
            .map { $0.convert($0.bounds, to: nil) }
            .filter { $0.minY < y && y < $0.maxY }
        let split = descendants(of: frameView).compactMap { $0 as? NSSplitView }
            .first { $0.arrangedSubviews.count >= 2 }
        let divider = split.map { $0.convert(NSPoint(x: $0.arrangedSubviews[0].frame.maxX, y: 0), to: nil).x } ?? 280
        let lights = window.standardWindowButton(.zoomButton)!.convert(
            window.standardWindowButton(.zoomButton)!.bounds, to: nil).maxX
        var empty = Array(stride(from: lights + 16, through: divider - 100, by: 30))
        empty += stride(from: divider + 12, through: window.frame.width - 12, by: 40)
            .filter { x in !controls.contains { $0.insetBy(dx: -10, dy: 0).minX <= x && x <= $0.insetBy(dx: -10, dy: 0).maxX } }
        XCTAssertTrue(empty.contains { $0 > divider }, "detail-side empty band at \(tag)", file: file, line: line)
        for x in empty {
            let hit = TitleBand.hit(at: NSPoint(x: x, y: y), in: window)
            XCTAssertTrue(TitleBand.isEmpty(hit), "empty band at x=\(Int(x)), \(tag): hit \(String(describing: hit))",
                          file: file, line: line)
        }
        XCTAssertFalse(controls.filter { $0.minX > divider }.isEmpty, "the strip's controls are in the band at \(tag)",
                       file: file, line: line)
        for control in controls where control.minX > divider {
            let hit = TitleBand.hit(at: NSPoint(x: control.midX, y: y), in: window)
            XCTAssertFalse(TitleBand.isEmpty(hit), "a band control at x=\(Int(control.midX)), \(tag)",
                           file: file, line: line)
        }
    }

    func testTheBandIsOneHeightAndTheDividerBelowTheChipsInEveryState() throws {
        model.openSessions.openHistory()
        model.openSessions.openSettings()
        var heights: [String: CGFloat] = [:]

        for size in [NSSize(width: 900, height: 652), NSSize(width: 1300, height: 800)] {
            setContentSize(size)
            let tag = "\(Int(size.width))x\(Int(size.height))"

            // Home with both utility tabs open and inactive: the state that
            // drew the divider through the chips at 900 x 652.
            model.openSessions.showHome()
            settle()
            heights["home+tabs \(tag)"] = try assertBand("Home, History and Settings inactive")
            try assertTheLauncher(tag, overflows: size.height < 700)
            assertTheOwnerClassifiesTheBand(tag)

            model.openSessions.openHistory()
            settle()
            heights["history \(tag)"] = try assertBand("History active")

            model.openSessions.openSettings()
            settle()
            heights["settings \(tag)"] = try assertBand("Settings active")
        }

        let distinct = Set(heights.values.map { ($0 * 2).rounded() / 2 })
        XCTAssertEqual(distinct.count, 1, "one band height in every state and size: \(heights)")
    }

    /// The fixture fills the Recent list; that is what makes the launcher
    /// taller than a 900 x 652 window's pane, which the test above checks
    /// directly (the last row starts below the viewport, and the wheel
    /// scrolls).
    func testTheFixtureFillsTheRecentList() {
        XCTAssertEqual(LauncherView.recentProjects(model).count, 5, "five recent projects")
    }
}
