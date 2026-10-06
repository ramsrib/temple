import AppKit
import SwiftUI
import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

/// One owner for the keyboard while ⌘K, the ⌘N picker or the ⌘/ card is
/// up: the presenting call hands it to an inert responder, the panel's field
/// takes it on mount, nothing else may take it meanwhile, and putting the
/// panel away gives it back by intent. A real window, real key events, the
/// app model's own presentation calls.
@MainActor
final class OverlayFocusTests: XCTestCase {
    /// Stands in for a live terminal: takes the keyboard, records keys.
    private final class Terminal: NSView {
        var keys: [UInt16] = []
        var becameResponder = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
        override func becomeFirstResponder() -> Bool { becameResponder += 1; return true }
    }

    private var model: AppModel!
    private var window: NSWindow!
    private var inert: OverlayInertResponder!
    private var terminal: Terminal!
    private var historyField: NSTextField!

    override func setUp() async throws {
        model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                         engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                         database: try TempleDB.inMemory(),
                         settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        inert = OverlayInertResponder(frame: content.bounds)
        terminal = Terminal(frame: NSRect(x: 10, y: 10, width: 300, height: 100))
        historyField = NSTextField(frame: NSRect(x: 10, y: 360, width: 300, height: 22))
        [inert, terminal, historyField].forEach { content.addSubview($0!) }
        model.overlayFocus.attach(inert: inert)
    }

    override func tearDown() async throws {
        model.commandPalettePresented = false
        model.newSessionPickerPresented = false
        model.shortcutsPresented = false
        if OverlayKeyboard.isHeld { OverlayKeyboard.release() }
        window.makeFirstResponder(nil)
        window.close()
    }

    /// A panel's view as it mounts: a hosting view with its search field,
    /// handed over the way PanelHost does.
    @discardableResult
    private func mountPanel() -> NSTextField {
        let host = NSView(frame: NSRect(x: 320, y: 200, width: 260, height: 60))
        let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        host.addSubview(field)
        window.contentView?.addSubview(host)
        PanelHandOver().update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        return field
    }

    private func stubTerminal() -> StubTerminalSurface {
        let surface = StubTerminalSurface()
        surface.view.frame = NSRect(x: 10, y: 120, width: 200, height: 100)
        window.contentView?.addSubview(surface.view)
        return surface
    }

    private func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Plain keys, Return and the chords a terminal turns into input.
    private var gapKeys: [NSEvent] {
        [key(0, "a"), key(36, "\r"), key(51, "\u{7F}", .command),
         key(123, "\u{F702}", [.command, .numericPad, .function]),
         key(3, "F", [.command, .shift]), key(8, "\u{3}", .control)]
    }

    private func text(_ field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    func testKeysBeforeThePanelFieldMountsNeverReachATerminal() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleCommandPalette()
        XCTAssertTrue(window.firstResponder === inert, "the presenting call took the keyboard")
        gapKeys.forEach(window.sendEvent)
        XCTAssertEqual(terminal.keys, [])
    }

    func testKeysBeforeThePanelFieldMountsNeverReachHistorysField() {
        XCTAssertTrue(window.makeFirstResponder(historyField))
        model.toggleShortcuts()               // the ⌘/ card never mounts a field
        gapKeys.forEach(window.sendEvent)
        XCTAssertEqual(text(historyField), "")
        XCTAssertTrue(window.firstResponder === inert)
    }

    func testThePanelFieldTakesTheKeyboardOnMountAndTypesNormally() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleCommandPalette()
        let field = mountPanel()
        XCTAssertTrue(field.currentEditor() != nil && window.firstResponder === field.currentEditor())
        [key(0, "a"), key(11, "b"), key(51, "\u{7F}"), key(8, "c")].forEach(window.sendEvent)
        XCTAssertEqual(text(field), "ac")
        XCTAssertEqual(terminal.keys, [])
    }

    /// Tab activation, a find bar closing, a deferred claim: none takes the
    /// keyboard while a panel is up, and a claim made before it opened is void.
    func testATerminalCannotTakeTheKeyboardWhileAPanelIsUp() {
        let surface = stubTerminal()
        let earlier = OverlayKeyboard.ticket()
        model.toggleCommandPalette()
        let field = mountPanel()
        surface.focus()
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the panel keeps the keyboard")
        XCTAssertNil(OverlayKeyboard.ticket(), "every request is refused while it is up")
        model.toggleCommandPalette()
        XCTAssertFalse(OverlayKeyboard.mayClaim(try! XCTUnwrap(earlier), in: window), "a claim from before the panel is void after it")
    }

    func testGoingFromThePaletteToThePickerNeverFocusesTheTerminal() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let before = terminal.becameResponder
        model.toggleCommandPalette()
        mountPanel()
        model.toggleNewSessionPicker()        // the palette goes, the picker comes
        XCTAssertTrue(window.firstResponder === inert)
        turn()
        let picker = mountPanel()
        XCTAssertTrue(window.firstResponder === picker.currentEditor())
        turn()
        XCTAssertEqual(terminal.becameResponder, before, "not even for a moment")
        model.newSessionPickerPresented = false
        turn()
        XCTAssertTrue(window.firstResponder === terminal, "the last panel gone, the terminal has it back")
    }

    func testPuttingThePanelAwayGivesTheKeyboardBackToTheFieldThatHadIt() {
        XCTAssertTrue(window.makeFirstResponder(historyField))
        (window.firstResponder as? NSTextView)?.insertText("deploy", replacementRange: NSRange(location: NSNotFound, length: 0))
        model.toggleCommandPalette()
        mountPanel()
        model.toggleCommandPalette()
        turn()
        let editor = window.firstResponder as? NSTextView
        XCTAssertTrue(editor != nil && editor === historyField.currentEditor(), "History's field has it again")
        XCTAssertEqual(editor?.selectedRange(), NSRange(location: 6, length: 0), "caret at the end, not all selected")
    }

    /// The panel's action focused something (a session it opened): that
    /// wins over giving the keyboard back.
    func testAFocusThePanelsActionAskedForWinsOverTheRestore() {
        let surface = stubTerminal()
        XCTAssertTrue(window.makeFirstResponder(historyField))
        model.toggleCommandPalette()
        mountPanel()
        model.commandPalettePresented = false   // as openPaletteResult does, then…
        surface.focus()                         // …it focuses the session it opened
        turn()
        XCTAssertTrue(window.firstResponder === surface.view)
    }

    /// ⌘O's modal chooser opens with no panel holding the keyboard.
    func testTheFolderChooserOpensWithTheKeyboardReleased() {
        model.toggleCommandPalette()
        XCTAssertTrue(OverlayKeyboard.isHeld)
        var heldWhenShown: Bool?
        model.presentFolderChooser = { _ in heldWhenShown = OverlayKeyboard.isHeld }
        model.openProjectFolder()
        XCTAssertEqual(heldWhenShown, false)
    }

    /// AppKit itself cannot hand a terminal the keyboard while a panel holds
    /// it: not a direct makeFirstResponder (a click queued before the
    /// backdrop), not the window becoming key again.
    func testATerminalRefusesTheKeyboardAtTheResponderWhileHeld() {
        let surface = stubTerminal()
        model.toggleShortcuts()
        XCTAssertFalse(surface.view.acceptsFirstResponder)
        XCTAssertFalse(window.makeFirstResponder(surface.view))
        XCTAssertTrue(window.firstResponder === inert)
        window.resignKey()
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === inert, "reactivation keeps the panel's hold")

        model.shortcutsPresented = false
        model.toggleCommandPalette()
        let field = mountPanel()
        window.makeFirstResponder(surface.view)   // the field lets go; the terminal refuses
        XCTAssertFalse(window.firstResponder === surface.view)
        turn()
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the panel's field is seated again")
        window.resignKey()
        window.becomeKey()
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "and reactivation keeps it")
    }

    /// Closed and reopened inside one update, SwiftUI keeps the panel's
    /// host: the new presentation is handed over to it too, and its field
    /// takes the keyboard again instead of leaving it with the inert one.
    func testAClosedAndReopenedPanelWithAReusedHostTakesTheKeyboardAgain() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let before = terminal.becameResponder
        model.toggleCommandPalette()
        let host = NSView(frame: NSRect(x: 320, y: 200, width: 260, height: 60))
        let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        host.addSubview(field)
        window.contentView?.addSubview(host)
        let handOver = PanelHandOver()
        handOver.update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        XCTAssertTrue(window.firstResponder === field.currentEditor())

        model.commandPalettePresented = false
        model.commandPalettePresented = true      // same turn: SwiftUI keeps the host
        XCTAssertTrue(window.firstResponder === inert)
        handOver.update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the reused host's field has it again")
        turn()
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the close's restore stood down")
        XCTAssertEqual(terminal.becameResponder, before)
    }

    /// Something took the keyboard directly between the panel going and the
    /// restore (a click on a field): the restore does not take it back.
    func testTheRestoreLeavesAFocusTakenDirectlyAfterDismissal() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleCommandPalette()
        mountPanel()
        model.toggleCommandPalette()
        XCTAssertTrue(window.makeFirstResponder(historyField))
        turn()
        XCTAssertTrue(window.firstResponder === historyField.currentEditor())
    }

    /// ⌘N starts its session before the picker goes: the new terminal's
    /// focus request, refused while the picker held the keyboard, is made
    /// again when it goes, and wins over giving the keyboard back.
    func testThePickersNewSessionGetsTheKeyboardAfterThePickerGoes() {
        let surface = stubTerminal()
        XCTAssertTrue(window.makeFirstResponder(historyField))
        model.toggleNewSessionPicker()
        mountPanel()
        surface.focus()                           // newSession → activate, while held
        XCTAssertFalse(window.firstResponder === surface.view)
        model.newSessionPickerPresented = false   // then the picker goes
        turn()
        XCTAssertTrue(window.firstResponder === surface.view, "the new session, not the sidebar's field")
    }

    /// A text field that refuses the keyboard the first `refusals` times.
    private final class ShyField: NSTextField {
        var refusals = 1
        override func becomeFirstResponder() -> Bool {
            if refusals > 0 { refusals -= 1; return false }
            return super.becomeFirstResponder()
        }
    }

    /// A real panel host whose field SwiftUI builds late: long after the
    /// panel appeared, a layout of the host is what lets the field claim.
    func testAFieldThatMountsLateStillTakesTheKeyboard() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleCommandPalette()
        let host = PanelHostingView(rootView: AnyView(Color.clear))
        host.frame = NSRect(x: 320, y: 200, width: 260, height: 60)
        let handOver = PanelHandOver()
        host.whenReady = { [weak host] in if let host { handOver.ready(host) } }
        window.contentView?.addSubview(host)
        handOver.update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(window.firstResponder === inert, "no field yet")
        let field = NSTextField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        host.addSubview(field)
        host.needsLayout = true
        window.layoutIfNeeded()
        turn()
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the late field took it on layout")
    }

    /// The field refuses the first hand-off: the presentation is not marked
    /// claimed, the inert responder keeps the keyboard, and the next
    /// readiness moment succeeds.
    func testARefusedHandOffIsTriedAgain() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleCommandPalette()
        let host = NSView(frame: NSRect(x: 320, y: 200, width: 260, height: 60))
        let field = ShyField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        host.addSubview(field)
        window.contentView?.addSubview(host)
        let handOver = PanelHandOver()
        handOver.update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        XCTAssertTrue(window.firstResponder === inert, "refused: the inert responder still has it")
        handOver.ready(host)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
        XCTAssertEqual(terminal.keys, [])
    }

    /// A click into the panel's field takes the keyboard from the inert
    /// responder even when no hand-off has worked yet.
    func testAClickIntoThePanelFieldAlwaysWorks() throws {
        model.toggleCommandPalette()
        let host = NSView(frame: NSRect(x: 320, y: 200, width: 260, height: 60))
        let field = ShyField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        host.addSubview(field)
        window.contentView?.addSubview(host)
        PanelHandOver().update(host, token: model.overlayFocus.token, focus: model.overlayFocus)
        XCTAssertTrue(window.firstResponder === inert)
        XCTAssertFalse(window.makeFirstResponder(field), "not handed by anyone: refused")

        func mouseDown(at point: NSPoint) throws -> NSEvent {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            // Taken off the queue as the run loop does, so it is the app's
            // current event while the click is handled.
            NSApp.postEvent(event, atStart: true)
            return try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                                                 inMode: .default, dequeue: true))
        }
        // A click outside the panel (on what is under it) does not get it.
        _ = try mouseDown(at: terminal.convert(NSPoint(x: 5, y: 5), to: nil))
        XCTAssertFalse(window.makeFirstResponder(field))
        // A click on the field: what NSTextField's mouseDown does next.
        _ = try mouseDown(at: field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the click put the keyboard in the field")
    }

    /// A focus request kept through the picker is made again when it goes,
    /// and its claim runs a turn later, as Ghostty's does. If the user put
    /// the keyboard in a field themselves in between, the claim stands down.
    func testAReplayedTerminalClaimDoesNotTakeAFieldFocusedSinceDismissal() {
        let surface = stubTerminal()
        surface.claimsAsynchronously = true
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleNewSessionPicker()
        mountPanel()
        surface.focus()                           // kept while the picker holds the keyboard
        model.newSessionPickerPresented = false   // made again: its claim is now queued
        XCTAssertTrue(window.makeFirstResponder(historyField))
        turn()
        XCTAssertTrue(window.firstResponder === historyField.currentEditor(), "the field keeps it")
    }

    /// With nobody else in between, the replayed claim lands.
    func testAReplayedTerminalClaimLandsWhenNothingElseTookTheKeyboard() {
        let surface = stubTerminal()
        surface.claimsAsynchronously = true
        XCTAssertTrue(window.makeFirstResponder(terminal))
        model.toggleNewSessionPicker()
        mountPanel()
        surface.focus()
        model.newSessionPickerPresented = false
        turn()
        XCTAssertTrue(window.firstResponder === surface.view)
    }
}
