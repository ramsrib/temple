import AppKit
import XCTest
@testable import TempleUI
import TempleCore

/// Keys typed straight after ⌘K, before the palette's field has the
/// keyboard, are held and sent again through the window's own key path once
/// it has: real key events into a real AppKit field, so editing, dead-key
/// composition and Return behave as if typed after focus.
@MainActor
final class PanelKeyHoldTests: XCTestCase {
    private final class Submit: NSObject {
        var values: [String] = []
        @objc func submit(_ sender: NSTextField) { values.append(sender.stringValue) }
    }

    private var window: NSWindow!
    private var field: NSTextField!
    private let submit = Submit()

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        field = NSTextField(frame: NSRect(x: 10, y: 40, width: 300, height: 22))
        field.target = submit
        field.action = #selector(Submit.submit(_:))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
    }

    override func tearDown() async throws {
        window.close()
    }

    /// The hold, delivering into the test window, replaying when told.
    private func makeHold() -> (PanelKeyHold, runScheduled: () -> Void) {
        let hold = PanelKeyHold()
        var pending: [@MainActor () -> Void] = []
        hold.schedule = { pending.append($0) }
        hold.deliver = { [window] in window!.sendEvent($0) }
        return (hold, { let run = pending; pending = []; run.forEach { $0() } })
    }

    private func key(_ code: UInt16, _ chars: String, ignoring: String? = nil,
                     _ flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)!
    }

    /// A key event as the keyboard sends it (a CGEvent with a keyboard
    /// source): only these carry what the layout needs to compose a dead
    /// key. A synthesized `NSEvent.keyEvent` types its characters literally.
    private func hardwareKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                          virtualKey: code, keyDown: true))
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private var a: NSEvent { key(0, "a") }
    private var b: NSEvent { key(11, "b") }
    private var c: NSEvent { key(8, "c") }
    private var backspace: NSEvent { key(51, "\u{7F}") }
    private var returnKey: NSEvent { key(36, "\r") }

    private var text: String { (window.firstResponder as? NSTextView)?.string ?? field.stringValue }

    func testHeldEditingAndReturnPlayBackInOrder() {
        let (hold, run) = makeHold()
        for event in [a, b, backspace, c, returnKey] {
            XCTAssertTrue(hold.hold(event, panelUp: true))
        }
        XCTAssertEqual(text, "", "nothing reaches a field before the replay")
        hold.fieldFocused()
        run()
        XCTAssertEqual(submit.values, ["ac"], "⌫ edited and Return submitted, as if typed after focus")
        XCTAssertTrue(hold.fieldReady)
        XCTAssertFalse(hold.hold(a, panelUp: true), "keys go straight to the field from here on")
    }

    /// A dead key composes with the next key only through the field's input
    /// system: ⌥E then E is "é", from the key events, not from characters.
    /// (Assumes a layout where ⌥E is the acute dead key, as US and most
    /// Latin layouts have.)
    func testADeadKeyComposesThroughTheReplay() throws {
        // What typing the same keys straight into a field gives here: the
        // replay must give exactly that. A layout without the dead key skips.
        let plain = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 22))
        window.contentView?.addSubview(plain)
        XCTAssertTrue(window.makeFirstResponder(plain))
        let plainEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        plainEditor.inputContext?.activate()
        window.sendEvent(try hardwareKey(14, .maskAlternate))
        window.sendEvent(try hardwareKey(14))
        let typed = plainEditor.string
        plainEditor.inputContext?.deactivate()
        try XCTSkipUnless(typed == "é", "this keyboard layout has no ⌥E dead key (typed \(typed))")
        XCTAssertTrue(window.makeFirstResponder(field))

        let (hold, run) = makeHold()
        // A key window's first responder has the current input context; this
        // offscreen one has to be told.
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.inputContext?.activate()
        defer { editor.inputContext?.deactivate() }
        XCTAssertTrue(hold.hold(try hardwareKey(14, .maskAlternate), panelUp: true))   // ⌥E: dead ´
        XCTAssertTrue(hold.hold(try hardwareKey(14), panelUp: true))                  // E
        XCTAssertEqual(text, "", "nothing composed while held")
        hold.fieldFocused()
        run()
        XCTAssertEqual(text, "é")
    }

    /// Keys that arrive after the field took focus but before the replay
    /// runs are held behind the earlier ones, never ahead of them.
    func testKeysBetweenFocusAndReplayKeepTheirPlace() {
        let (hold, run) = makeHold()
        XCTAssertTrue(hold.hold(a, panelUp: true))
        hold.fieldFocused()
        XCTAssertTrue(hold.hold(b, panelUp: true), "still held until the replay has run")
        hold.fieldFocused()
        run()
        XCTAssertEqual(text, "ab")
    }

    /// A panel dismissed before its field had the keyboard delivers nothing,
    /// to anyone, even if a replay had been scheduled.
    func testNothingLeaksAfterDismissal() {
        let (hold, run) = makeHold()
        var delivered: [NSEvent] = []
        hold.deliver = { delivered.append($0) }
        XCTAssertTrue(hold.hold(a, panelUp: true))
        hold.fieldFocused()
        hold.reset()                      // Esc, or a click on the backdrop
        run()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(hold.held.isEmpty)
        XCTAssertEqual(text, "")
    }

    /// A held Return that closes the panel ends the replay: what was typed
    /// after it goes nowhere.
    func testAReturnThatClosesThePanelStopsTheReplay() {
        let (hold, run) = makeHold()
        var delivered: [UInt16] = []
        hold.deliver = { event in
            delivered.append(event.keyCode)
            if event.keyCode == 36 { hold.reset() }
        }
        for event in [a, returnKey, b] { XCTAssertTrue(hold.hold(event, panelUp: true)) }
        hold.fieldFocused()
        run()
        XCTAssertEqual(delivered, [0, 36])
    }

    func testEscapeChordsKeyUpsAndClosedPanelsAreNeverHeld() {
        let (hold, _) = makeHold()
        XCTAssertFalse(hold.hold(a, panelUp: false), "no panel up")
        XCTAssertFalse(hold.hold(key(53, "\u{1B}"), panelUp: true), "Esc dismisses at once")
        XCTAssertFalse(hold.hold(key(40, "k", .command), panelUp: true), "⌘K toggles at once")
        XCTAssertFalse(hold.hold(key(8, "\u{3}", ignoring: "c", .control), panelUp: true), "⌃ chords pass")
        XCTAssertFalse(hold.hold(key(0, "a", type: .keyUp), panelUp: true), "only key-downs")
        XCTAssertTrue(hold.held.isEmpty)
    }

    /// The app model holds keys only while ⌘K or ⌘N is up, and drops them
    /// whenever either opens or closes.
    func testTheModelScopesHeldKeysToOnePresentation() {
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                             database: try! TempleDB.inMemory(),
                             settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        XCTAssertFalse(model.holdPanelKey(a))
        model.toggleCommandPalette()
        XCTAssertTrue(model.holdPanelKey(a))
        model.toggleCommandPalette()
        XCTAssertTrue(model.panelKeys.held.isEmpty, "closing drops what it held")
        model.toggleNewSessionPicker()
        XCTAssertTrue(model.holdPanelKey(b), "⌘N's field too")
        model.toggleCommandPalette()
        XCTAssertEqual(model.panelKeys.held, [], "another panel starts empty")
        XCTAssertTrue(model.holdPanelKey(c))
    }
}
