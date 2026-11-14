import XCTest
import AppKit
import SwiftUI
import TempleTerminalAPI
@testable import TempleTerminal

/// A window zoom hands the terminal one size, the final one, instead of one
/// per animation frame: each size reflows the grid and resizes the pty, and
/// Claude Code redraws its whole screen on every SIGWINCH, so a zoom read as
/// the text being rewritten under the animation. An edge drag still follows
/// the pointer. No surface is started; `onSizePushed` reports what libghostty
/// would have been told. Sorts before `GhosttyRuntimeTests`, whose last test
/// shuts the runtime down.
@MainActor
final class GhosttyAnimatedResizeTests: XCTestCase {
    private func window(containing view: NSView, hosted: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 320),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if hosted {
            window.contentView = NSHostingView(rootView: HStack(spacing: 0) {
                Color.gray.frame(width: 120)
                Hosted(view: view)
            })
        } else {
            view.autoresizingMask = [.width, .height]
            view.frame = window.contentView!.bounds
            window.contentView!.addSubview(view)
        }
        window.orderFront(nil)
        window.layoutIfNeeded()
        return window
    }

    private struct Hosted: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private func assertZoomPushesOnlyTheFinalSize(hosted: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = GhosttySurfaceView(app: GhosttyApp.shared, appearance: .default)
        let window = window(containing: view, hosted: hosted)
        defer { window.close() }
        let before = view.frame.size
        var pushes: [CGSize] = []
        var framesDuringZoom = 0
        view.onSizePushed = { pushes.append($0) }
        let counter = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in framesDuringZoom += 1 }
        view.postsFrameChangedNotifications = true
        defer { NotificationCenter.default.removeObserver(counter) }

        window.performZoom(nil)        // synchronous: returns when the animation has landed
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // the held size goes a turn later

        let after = view.frame.size
        XCTAssertNotEqual(after, before, "the window did not zoom", file: file, line: line)
        // macOS zooms in one step with the screen locked or the display
        // asleep (measured): no animation, nothing to hold, nothing proved.
        if framesDuringZoom <= 3 {
            throw XCTSkip("the zoom was not animated (\(framesDuringZoom) sizes): screen locked or display asleep?")
        }
        XCTAssertFalse(pushes.isEmpty, "the final size never reached the surface", file: file, line: line)
        XCTAssertEqual(pushes, [after], "only the landed size may reach the surface, once", file: file, line: line)
    }

    func testAZoomHandsTheTerminalOnlyItsFinalSize() throws {
        try assertZoomPushesOnlyTheFinalSize(hosted: false)
    }

    /// Temple's terminal sits in SwiftUI, which lays the view out once more
    /// after the live resize ends.
    func testAZoomHandsAHostedTerminalOnlyItsFinalSize() throws {
        try assertZoomPushesOnlyTheFinalSize(hosted: true)
    }

    /// Outside a live resize (a sidebar toggle, a window moved by code),
    /// every size still goes straight through.
    func testAnUnanimatedResizeGoesStraightThrough() {
        let view = GhosttySurfaceView(app: GhosttyApp.shared, appearance: .default)
        let window = window(containing: view, hosted: false)
        defer { window.close() }
        var pushes: [CGSize] = []
        view.onSizePushed = { pushes.append($0) }
        window.setFrame(NSRect(x: 80, y: 80, width: 700, height: 420), display: true, animate: false)
        XCTAssertEqual(pushes.last, view.frame.size)
        XCTAssertEqual(pushes.count, 1)
    }

    private func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testOnlyASingleClickDragFollowsThePointer() {
        let left = 1
        XCTAssertTrue(GhosttySurfaceView.pointerDrivesResize(mouse(.leftMouseDown, clicks: 1), pressedButtons: left),
                      "an edge drag reflows live")
        XCTAssertTrue(GhosttySurfaceView.pointerDrivesResize(mouse(.leftMouseDragged, clicks: 1), pressedButtons: left))
        XCTAssertFalse(GhosttySurfaceView.pointerDrivesResize(mouse(.leftMouseDown, clicks: 2), pressedButtons: left),
                       "a title-bar double-click zooms; a double-clicked edge expands to the screen")
        XCTAssertFalse(GhosttySurfaceView.pointerDrivesResize(mouse(.leftMouseUp, clicks: 1), pressedButtons: 0),
                       "a window button or menu item acts with the button up")
        XCTAssertFalse(GhosttySurfaceView.pointerDrivesResize(nil, pressedButtons: 0), "a key or code")
        XCTAssertFalse(GhosttySurfaceView.pointerDrivesResize(mouse(.leftMouseDown, clicks: 1), pressedButtons: 0),
                       "a stale event with no button held")
    }
}
