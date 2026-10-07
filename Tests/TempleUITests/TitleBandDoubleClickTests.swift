import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// A double-click on any empty part of the title band performs the system
/// title-bar action exactly once, over the sidebar and over the detail
/// pane, with no tab open, with History, with Settings, at several sidebar
/// widths and window sizes, and after the window was zoomed and then
/// resized by hand. Controls in the band keep their clicks.
///
/// A real titled window with the app's split view (RootView's, minus its
/// launch side effects), the real tab strip and toolbar, and events through
/// `NSApp.sendEvent`, so the window's own title-bar handling runs too: a
/// count of 2 would mean it zoomed as well. AppKit alone zooms only where a
/// private, lazily rebuilt drag region says so; with no tab open that
/// region left out the whole sidebar (see TitleBandDoubleClick).
@MainActor
final class TitleBandDoubleClickTests: XCTestCase {
    final class RecordingWindow: NSWindow {
        var zooms = 0
        var miniaturizes = 0
        override func zoom(_ sender: Any?) { zooms += 1; super.zoom(sender) }
        // Recorded, never performed: a minimized test window is gone for
        // the rest of the run.
        override func miniaturize(_ sender: Any?) { miniaturizes += 1 }
        override func performMiniaturize(_ sender: Any?) { miniaturizes += 1 }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.01 }
    }

    private var model: AppModel!
    private var window: RecordingWindow!
    private var savedArguments: [String: Any]?

    override func setUp() async throws {
        // The action follows the system setting; pin it to zoom for this
        // process only (the argument domain is in memory and outranks the
        // global one). AppKit's own path ignores it, as it should.
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments ?? [:]
        arguments["AppleActionOnDoubleClick"] = "Maximize"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                         engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                         database: try TempleDB.inMemory(),
                         settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.history.catalog = { AsyncStream { $0.finish() } }
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
        // What `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unified)` make.
        window = RecordingWindow(contentRect: NSRect(x: 80, y: 80, width: 1328, height: 785),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1328, height: 785))
        // On screen for AppKit's title-bar handling, invisible to whoever is
        // at the machine.
        window.alphaValue = 0
        window.orderFront(nil)
        pump(1.0)
    }

    override func tearDown() async throws {
        window.close()
        if let savedArguments {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        } else {
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
    }

    // MARK: Helpers

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private var frameView: NSView { window.contentView!.superview! }

    private var split: NSSplitView {
        descendants(of: frameView).compactMap { $0 as? NSSplitView }.first { $0.arrangedSubviews.count >= 2 }!
    }

    private var divider: CGFloat {
        split.convert(NSPoint(x: split.arrangedSubviews[0].frame.maxX, y: 0), to: nil).x
    }

    private var bandMidY: CGFloat {
        (window.contentLayoutRect.maxY + window.frame.height) / 2
    }

    /// Down/up twice at one point, through the application as real input
    /// is, each up queued before its down so a tracking loop finds it.
    private func doubleClick(at point: NSPoint, clicks: Int = 2) {
        let start = ProcessInfo.processInfo.systemUptime
        for count in 1...clicks {
            let time = start + Double(count) * 0.05
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                          timestamp: time, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: count * 2, clickCount: count, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                        timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
                                        eventNumber: count * 2 + 1, clickCount: count, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            while let queued = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
        pump()
    }

    /// Zooms caused by one double-click at `point` (window coordinates).
    private func zooms(at point: NSPoint, clicks: Int = 2) -> Int {
        let before = window.zooms
        doubleClick(at: point, clicks: clicks)
        return window.zooms - before
    }

    /// The strip's hosting views (switcher, chips row, `+`, cues) in window
    /// coordinates; the parts of the band that are not empty on the detail side.
    private var stripControls: [NSRect] {
        descendants(of: frameView)
            .filter { $0 is TitleBandControl && !$0.isHidden && $0.frame.width > 0 }
            .map { $0.convert($0.bounds, to: nil) }
            .filter { $0.maxY > window.contentLayoutRect.maxY }
    }

    /// Points on the band that nothing claims: over the sidebar between the
    /// traffic lights and the rail's buttons (which sit just left of the
    /// divider, under 100 pt wide), and over the detail pane clear of the
    /// strip's controls.
    /// x only: a zoom changes the window's height, and with it where the
    /// band is in window coordinates, so y is taken at each click.
    private func emptyXs() -> [CGFloat] {
        let lights = window.standardWindowButton(.zoomButton)!
        let lightsEnd = lights.convert(lights.bounds, to: nil).maxX
        var xs = Array(stride(from: lightsEnd + 16, through: divider - 100, by: 30))
        let controls = stripControls.map { $0.insetBy(dx: -10, dy: 0) }
        xs += stride(from: divider + 12, through: window.frame.width - 12, by: 70)
            .filter { x in !controls.contains { $0.minX <= x && x <= $0.maxX } }
        return xs
    }

    private func label(_ state: String, _ point: NSPoint) -> String {
        "\(state): window \(window.frame.size), sidebar \(split.arrangedSubviews[0].frame.width), x=\(Int(point.x)) "
            + "hit \(TitleBandDiagnostics.chain(from: TitleBand.hit(at: point, in: window)))"
    }

    private func assertEveryEmptyPointZoomsOnce(_ state: String, file: StaticString = #filePath, line: UInt = #line) {
        let xs = emptyXs()
        XCTAssertTrue(xs.contains { $0 < divider }, "\(state): no sidebar points", file: file, line: line)
        XCTAssertTrue(xs.contains { $0 > divider }, "\(state): no detail points", file: file, line: line)
        for x in xs {
            let point = NSPoint(x: x, y: bandMidY)
            XCTAssertEqual(zooms(at: point), 1, label(state, point), file: file, line: line)
        }
    }

    private func setSidebar(_ width: CGFloat) {
        split.setPosition(width, ofDividerAt: 0)
        pump(0.3)
    }

    private func setSize(_ size: NSSize) {
        window.setContentSize(size)
        pump(0.3)
    }

    // MARK: Tests

    func testTheOwnerIsInstalledOnTheWindow() {
        XCTAssertTrue(TitleBandDoubleClick.isInstalled(on: window))
    }

    func testEmptyBandZoomsOnceWithNoTabOpen() {
        for width: CGFloat in [240, 280, 360] {
            setSidebar(width)
            for size in [NSSize(width: 1328, height: 785), NSSize(width: 901, height: 923)] {
                setSize(size)
                assertEveryEmptyPointZoomsOnce("launcher")
            }
        }
    }

    func testEmptyBandZoomsOnceWithHistoryAndSettings() {
        model.openSessions.openHistory()
        pump(0.5)
        for width: CGFloat in [240, 360] {
            setSidebar(width)
            for size in [NSSize(width: 901, height: 923), NSSize(width: 1328, height: 785)] {
                setSize(size)
                assertEveryEmptyPointZoomsOnce("history")
            }
        }
        model.openSessions.openSettings()
        pump(0.5)
        setSidebar(280)
        assertEveryEmptyPointZoomsOnce("settings")
    }

    /// The owner's report: zoom by double-click, then resize the window by
    /// hand and drag the sidebar; the band must still answer.
    func testEmptyBandStillZoomsAfterAZoomAndAHandResize() throws {
        let start = NSPoint(x: divider + 200, y: bandMidY)
        XCTAssertEqual(zooms(at: start), 1, "zoom")
        pump(0.3)
        XCTAssertTrue(window.isZoomed)
        setSize(NSSize(width: 1037, height: 691))
        setSidebar(331)
        XCTAssertFalse(window.isZoomed)
        assertEveryEmptyPointZoomsOnce("after resize")
        model.openSessions.openHistory()
        pump(0.5)
        setSize(NSSize(width: 1213, height: 802))
        setSidebar(255)
        assertEveryEmptyPointZoomsOnce("history after resize")
    }

    func testControlsInTheBandKeepTheirClicks() throws {
        model.openSessions.openHistory()
        pump(0.5)
        // The minimize light (close and zoom would end or move the test).
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let light = minimize.convert(NSPoint(x: minimize.bounds.midX, y: minimize.bounds.midY), to: nil)
        XCTAssertEqual(zooms(at: light), 0, "minimize light")

        // The rail's buttons, just left of the divider: a toolbar item.
        let rail = NSPoint(x: divider - 20, y: bandMidY)
        let railHit = try XCTUnwrap(TitleBand.hit(at: rail, in: window))
        XCTAssertFalse(TitleBand.isEmpty(railHit), TitleBandDiagnostics.chain(from: railHit))
        XCTAssertEqual(zooms(at: rail), 0, "rail buttons")

        // The split divider, which runs up through the band. Classified,
        // not clicked: its drag loop outlives synthesized events, as a
        // chip's gestures do.
        let dividerPoint = NSPoint(x: divider + split.dividerThickness / 2, y: bandMidY)
        let dividerHit = TitleBand.hit(at: dividerPoint, in: window)
        XCTAssertFalse(TitleBand.isEmpty(dividerHit), TitleBandDiagnostics.chain(from: dividerHit))

        // The History chip, the strip's first chip.
        let chips = stripControls.filter { $0.minX > divider }
        XCTAssertFalse(chips.isEmpty, "the strip shows its controls")
        for chip in chips {
            let center = NSPoint(x: chip.midX, y: min(chip.midY, bandMidY))
            guard let hit = TitleBand.hit(at: center, in: window) else { continue }
            XCTAssertFalse(TitleBand.isEmpty(hit), "strip control at \(chip): \(TitleBandDiagnostics.chain(from: hit))")
        }
    }

    func testATripleClickZoomsOnce() {
        let point = NSPoint(x: divider - 120, y: bandMidY)
        XCTAssertEqual(zooms(at: point, clicks: 3), 1)
    }

    func testBelowTheBandIsNotTheOwnersBusiness() {
        let point = NSPoint(x: divider + 300, y: window.contentLayoutRect.maxY - 40)
        XCTAssertEqual(zooms(at: point), 0)
    }

    func testTheSystemSettingDecidesTheAction() {
        let suite = Fixture.uniqueDefaults()
        let before = (window.zooms, window.miniaturizes)
        suite.set("Minimize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: window, defaults: suite), "minimize")
        suite.set("None", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: window, defaults: suite), "none (system setting)")
        XCTAssertEqual(window.zooms, before.0)
        XCTAssertEqual(window.miniaturizes, before.1 + 1)
        suite.removeObject(forKey: "AppleActionOnDoubleClick")
        suite.set(true, forKey: "AppleMiniaturizeOnDoubleClick")
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: window, defaults: suite), "minimize")
        suite.set(false, forKey: "AppleMiniaturizeOnDoubleClick")
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: window, defaults: suite), "zoom")
        XCTAssertEqual(window.zooms, before.0 + 1)
    }

    /// TEMPLE_DEBUG_TITLEBAR's report reads the window without acting on it
    /// (including AppKit's private gate, looked up by name), and is off
    /// unless the variable is set.
    func testTheDiagnosticReadsTheWindowWithoutActing() {
        XCTAssertFalse(TitleBandDiagnostics.isEnabled, "inert without TEMPLE_DEBUG_TITLEBAR=1")
        let point = NSPoint(x: divider - 120, y: bandMidY)
        let frame = window.frame
        let report = TitleBandDiagnostics.Report(window: window, point: point, hit: TitleBand.hit(at: point, in: window))
        report.log(outcome: "test")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.zooms, 0)
        XCTAssertTrue(["yes", "no", "?"].contains(report.appKitWouldZoom))
        XCTAssertEqual(report.sidebarWidth, String(format: "%.0f", split.arrangedSubviews[0].frame.width))
        XCTAssertTrue(report.chain.contains("<"), report.chain)
    }
}
