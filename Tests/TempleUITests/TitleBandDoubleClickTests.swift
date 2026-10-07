import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore

/// A double-click on any empty part of the title band performs the system
/// title-bar action exactly once, over the sidebar and over the detail
/// pane, with no tab open, with History, with Settings, at several sidebar
/// widths and window sizes, and after the window was zoomed and then
/// resized by hand. Controls in the band keep their clicks, and a gesture
/// begun anywhere but empty band (a backdrop its first click dismissed,
/// another window) never becomes a title-bar action.
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
        /// Reports full screen without entering it: a real full-screen
        /// window takes a Space of its own on the screen of whoever is at
        /// the machine.
        var reportsFullScreen = false
        override var styleMask: NSWindow.StyleMask {
            get { reportsFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
        override func zoom(_ sender: Any?) { zooms += 1; super.zoom(sender) }
        // Recorded, never performed: a minimized test window is gone for
        // the rest of the run.
        override func miniaturize(_ sender: Any?) { miniaturizes += 1 }
        override func performMiniaturize(_ sender: Any?) { miniaturizes += 1 }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.01 }
    }

    /// A band control of ours that records the clicks it gets; `onMouseDown`
    /// lets it stand in for a panel's backdrop, which goes on its first.
    /// An NSControl, because AppKit hands band clicks to a plain NSView
    /// only where its lazily rebuilt drag region says so (measured: the
    /// same view got them in one test and not in the next), and the test
    /// is of the owner, not of that cache. It takes a click that would
    /// otherwise only activate the (never key) test window.
    final class RecordingBandControl: NSControl, TitleBandControl {
        var clickCounts: [Int] = []
        var onMouseDown: () -> Void = {}
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            clickCounts.append(event.clickCount)
            onMouseDown()
        }
    }

    final class ActionCounter: NSObject {
        var count = 0
        @objc func fire(_ sender: Any?) { count += 1 }
    }

    /// Records the system actions instead of performing them, with the
    /// private Fill selector present or absent at will.
    final class ActionRecordingWindow: NSWindow {
        var fillAvailable = true
        var actions: [String] = []
        override func performZoom(_ sender: Any?) { actions.append("zoom") }
        override func performMiniaturize(_ sender: Any?) { actions.append("minimize") }
        @objc(_zoomFill:) func recordFill(_ sender: Any?) { actions.append("fill") }
        override func responds(to selector: Selector!) -> Bool {
            if selector == Selector(("_zoomFill:")) { return fillAvailable }
            return super.responds(to: selector)
        }
    }

    private var model: AppModel!
    private var window: RecordingWindow!
    private var savedArguments: [String: Any]?
    private var extraWindows: [NSWindow] = []

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
        for extra in extraWindows {
            if let sheet = extra.sheetParent { sheet.endSheet(extra) }
            extra.close()
        }
        extraWindows = []
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

    /// A mouse-down built for handing straight to the owner, bypassing
    /// AppKit's dispatch.
    private func mouseDown(at point: NSPoint, clickCount: Int, time: TimeInterval,
                           in target: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                           timestamp: time, windowNumber: (target ?? window).windowNumber, context: nil,
                           eventNumber: clickCount, clickCount: clickCount, pressure: 1)!
    }

    /// What the owner says to each click of a double-click at `point`, the
    /// first in `firstIn` (default: the test window), the second in the
    /// test window.
    private func ownerVerdicts(at point: NSPoint, firstIn: NSWindow? = nil) throws -> [Bool] {
        let owner = try XCTUnwrap(TitleBandDoubleClick.owner(of: window))
        let start = ProcessInfo.processInfo.systemUptime
        return [owner.swallows(mouseDown(at: point, clickCount: 1, time: start, in: firstIn)),
                owner.swallows(mouseDown(at: point, clickCount: 2, time: start + 0.1))]
    }

    /// A small window of the test's own, invisible like the main one.
    private func extraWindow() -> NSWindow {
        let extra = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 400, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        extra.isReleasedWhenClosed = false
        extra.alphaValue = 0
        extraWindows.append(extra)
        return extra
    }

    /// Puts `view` over everything in the window's frame, band included.
    private func addOnTop(_ view: NSView) {
        frameView.addSubview(view, positioned: .above, relativeTo: nil)
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
        // The minimize light (close and zoom would end or move the test):
        // both clicks reach it, so it minimizes (recorded) twice.
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let light = minimize.convert(NSPoint(x: minimize.bounds.midX, y: minimize.bounds.midY), to: nil)
        let minimizesBefore = window.miniaturizes
        XCTAssertEqual(zooms(at: light), 0, "minimize light")
        XCTAssertEqual(window.miniaturizes - minimizesBefore, 2, "minimize light got both clicks")

        // An AppKit button in the band: its action fires on each click.
        let counter = ActionCounter()
        let button = NSButton(title: "B", target: counter, action: #selector(ActionCounter.fire(_:)))
        button.frame = NSRect(x: divider + 300, y: bandMidY - 10, width: 40, height: 20)
        addOnTop(button)
        let buttonPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(TitleBand.hit(at: buttonPoint, in: window) === button)
        XCTAssertEqual(zooms(at: buttonPoint), 0, "button")
        XCTAssertEqual(counter.count, 2, "the button's action fired for both clicks")
        button.removeFromSuperview()

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

    /// A first click on a panel's backdrop in the band dismisses the panel
    /// and exposes empty band under the second: that double-click is the
    /// backdrop's, and must not zoom (nor let AppKit zoom).
    func testAGestureBegunOnABackdropNeverBecomesATitleBarAction() throws {
        let point = NSPoint(x: divider + 200, y: bandMidY)
        XCTAssertTrue(TitleBand.isEmpty(TitleBand.hit(at: point, in: window)))
        let backdrop = RecordingBandControl(frame: frameView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.onMouseDown = { [weak backdrop] in backdrop?.removeFromSuperview() }
        addOnTop(backdrop)
        XCTAssertTrue(TitleBand.hit(at: point, in: window) === backdrop)

        XCTAssertEqual(zooms(at: point), 0, "the backdrop's double-click zoomed")
        XCTAssertEqual(window.miniaturizes, 0)
        XCTAssertEqual(backdrop.clickCounts, [1], "dismissed on the first click")
        XCTAssertNil(backdrop.superview)

        // The band, now uncovered, answers a gesture of its own.
        XCTAssertEqual(zooms(at: NSPoint(x: point.x, y: bandMidY)), 1)
    }

    func testAGestureBegunInAnotherWindowIsNotTheOwners() throws {
        let other = extraWindow()
        other.orderFront(nil)
        pump()
        let point = NSPoint(x: divider + 200, y: bandMidY)
        let before = window.zooms
        // Clicks in the other window pass through, at any count.
        let owner = try XCTUnwrap(TitleBandDoubleClick.owner(of: window))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(owner.swallows(mouseDown(at: point, clickCount: 1, time: start, in: other)))
        XCTAssertFalse(owner.swallows(mouseDown(at: point, clickCount: 2, time: start + 0.1, in: other)))
        // A count of 2 here after a first click there: swallowed, not acted on.
        XCTAssertEqual(try ownerVerdicts(at: point, firstIn: other), [false, true])
        XCTAssertEqual(window.zooms, before)
        // The same double-click wholly in this window acts.
        XCTAssertEqual(try ownerVerdicts(at: NSPoint(x: point.x, y: bandMidY)), [false, true])
        XCTAssertEqual(window.zooms, before + 1)
    }

    func testTheOwnerStandsAsideWhileASheetIsAttached() throws {
        let sheet = extraWindow()
        window.beginSheet(sheet) { _ in }
        pump(0.5)
        XCTAssertNotNil(window.attachedSheet)
        let point = NSPoint(x: divider + 200, y: bandMidY)
        let before = window.zooms
        XCTAssertEqual(try ownerVerdicts(at: point), [false, false], "the parent's band, sheet up")
        // Nor are the sheet's own clicks the owner's.
        let owner = try XCTUnwrap(TitleBandDoubleClick.owner(of: window))
        let start = ProcessInfo.processInfo.systemUptime
        let sheetPoint = NSPoint(x: 100, y: sheet.frame.height - 10)
        XCTAssertFalse(owner.swallows(mouseDown(at: sheetPoint, clickCount: 1, time: start, in: sheet)))
        XCTAssertFalse(owner.swallows(mouseDown(at: sheetPoint, clickCount: 2, time: start + 0.1, in: sheet)))
        XCTAssertEqual(window.zooms, before)
        window.endSheet(sheet)
        pump(0.5)
        XCTAssertEqual(try ownerVerdicts(at: point), [false, true], "the sheet gone, the band answers")
        XCTAssertEqual(window.zooms, before + 1)
    }

    func testTheOwnerStandsAsideInFullScreen() throws {
        let point = NSPoint(x: divider + 200, y: bandMidY)
        let before = window.zooms
        window.reportsFullScreen = true
        defer { window.reportsFullScreen = false }
        XCTAssertTrue(TitleBand.contains(point, in: window), "still the band, so full screen is what decides")
        XCTAssertTrue(TitleBand.isEmpty(TitleBand.hit(at: point, in: window)))
        XCTAssertEqual(try ownerVerdicts(at: point), [false, false])
        XCTAssertEqual(window.zooms, before)
    }

    func testClosingTheWindowRemovesItsMonitor() {
        final class Ledger { var added: [AnyObject] = []; var removed: [AnyObject] = [] }
        let ledger = Ledger()
        let counting = TitleBandDoubleClick.Monitoring(
            add: { handler in
                let monitor = TitleBandDoubleClick.Monitoring.appKit.add(handler)
                if let monitor { ledger.added.append(monitor as AnyObject) }
                return monitor
            },
            remove: { monitor in
                ledger.removed.append(monitor as AnyObject)
                TitleBandDoubleClick.Monitoring.appKit.remove(monitor)
            })
        let bare = extraWindow()
        TitleBandDoubleClick.install(on: bare, diagnostics: false, monitoring: counting)
        TitleBandDoubleClick.install(on: bare, diagnostics: false, monitoring: counting)
        XCTAssertTrue(TitleBandDoubleClick.isInstalled(on: bare))
        XCTAssertEqual(ledger.added.count, 1, "idempotent per window")
        XCTAssertTrue(ledger.removed.isEmpty)

        bare.close()
        pump()
        XCTAssertFalse(TitleBandDoubleClick.isInstalled(on: bare))
        XCTAssertEqual(ledger.removed.count, 1)
        XCTAssertTrue(ledger.removed.first === ledger.added.first, "the monitor it added is the one removed")
        XCTAssertTrue(TitleBandDoubleClick.isInstalled(on: window), "the other window keeps its owner")
    }

    func testABandControlGetsBothClicks() throws {
        // One of our band controls: it gets the first click and the second.
        let control = RecordingBandControl(frame: NSRect(x: divider + 300, y: bandMidY - 10, width: 40, height: 20))
        addOnTop(control)
        let controlPoint = NSPoint(x: control.frame.midX, y: control.frame.midY)
        XCTAssertTrue(TitleBand.hit(at: controlPoint, in: window) === control)
        XCTAssertEqual(zooms(at: controlPoint), 0, "band control")
        XCTAssertEqual(control.clickCounts, [1, 2])
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

    /// "Fill" performs the Window menu's Fill where the window answers its
    /// private selector, and zooms where it doesn't. Recorded on a window
    /// of the test's own; the setting comes from an in-memory suite.
    func testFillIsPerformedWhereAvailableAndOtherwiseZooms() {
        let suite = Fixture.uniqueDefaults()
        suite.set("Fill", forKey: "AppleActionOnDoubleClick")
        let fillable = ActionRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                             styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        fillable.isReleasedWhenClosed = false
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: fillable, defaults: suite), "fill")
        XCTAssertEqual(fillable.actions, ["fill"])

        let unfillable = ActionRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                               styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        unfillable.isReleasedWhenClosed = false
        unfillable.fillAvailable = false
        XCTAssertEqual(TitleBand.performSystemDoubleClickAction(on: unfillable, defaults: suite),
                       "zoom (fill unavailable)")
        XCTAssertEqual(unfillable.actions, ["zoom"])
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
