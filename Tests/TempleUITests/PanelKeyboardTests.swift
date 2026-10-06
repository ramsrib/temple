import AppKit
import XCTest
@testable import TempleUI

/// While ⌘K, the ⌘N picker or the ⌘/ card is up, keys reach only the panel:
/// until its field really is the first responder, the key router keeps them
/// from History's search field and from a terminal beneath. Real key events
/// into a real window, routed the way RootView's key monitor routes them.
@MainActor
final class PanelKeyboardTests: XCTestCase {
    /// Stands in for a live terminal: takes the keyboard, records keys.
    private final class Terminal: NSView {
        var keys: [UInt16] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }

    private var window: NSWindow!
    private var historyField: NSTextField!
    private var terminal: Terminal!
    private var panelHost: NSView!
    private var panelField: NSTextField!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        historyField = NSTextField(frame: NSRect(x: 10, y: 260, width: 300, height: 22))
        terminal = Terminal(frame: NSRect(x: 10, y: 10, width: 300, height: 100))
        panelHost = NSView(frame: NSRect(x: 10, y: 150, width: 400, height: 60))
        panelField = NSTextField(frame: NSRect(x: 10, y: 20, width: 300, height: 22))
        panelHost.addSubview(panelField)
        [historyField, terminal, panelHost].forEach { content.addSubview($0!) }
        PanelKeyboard.host = panelHost
    }

    override func tearDown() async throws {
        PanelKeyboard.host = nil
        window.close()
    }

    /// What RootView's key monitor does with a key while a panel is up.
    private func type(_ events: [NSEvent], panelUp: Bool = true) {
        for event in events where !PanelKeyboard.swallows(
            panelUp: panelUp, panelOwnsKeyboard: PanelKeyboard.panelOwnsKeyboard(in: window),
            modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers ?? "") {
            window.sendEvent(event)
        }
    }

    private func key(_ code: UInt16, _ chars: String, ignoring: String? = nil,
                     _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)!
    }

    /// As the keyboard sends it: only these carry what a layout needs to
    /// compose a dead key.
    private func hardwareKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                          virtualKey: code, keyDown: true))
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private var abc: [NSEvent] { [key(0, "a"), key(11, "b"), key(8, "c")] }
    private func text(_ field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    func testKeysBeforeThePanelHasTheKeyboardNeverReachHistorysField() {
        XCTAssertTrue(window.makeFirstResponder(historyField))
        type(abc + [key(36, "\r"), key(51, "\u{7F}"), key(8, "\u{3}", ignoring: "c", .control),
                    key(9, "v", .command), key(6, "z", .command)])
        XCTAssertEqual(text(historyField), "", "nothing typed while ⌘K was coming up landed under it")
        type(abc, panelUp: false)
        XCTAssertEqual(text(historyField), "abc", "with no panel up the field types as ever")
    }

    func testKeysBeforeThePanelHasTheKeyboardNeverReachATerminal() {
        XCTAssertTrue(window.makeFirstResponder(terminal))
        type(abc + [key(36, "\r"), key(8, "\u{3}", ignoring: "c", .control)])
        XCTAssertEqual(terminal.keys, [], "not a key, not ⌃C, not Return")
    }

    func testTheAppsShortcutsAndEscStillGoThrough() {
        func swallowed(_ chars: String, _ flags: NSEvent.ModifierFlags) -> Bool {
            PanelKeyboard.swallows(panelUp: true, panelOwnsKeyboard: false, modifiers: flags, characters: chars)
        }
        XCTAssertFalse(swallowed("k", .command), "⌘K puts the panel away")
        XCTAssertFalse(swallowed("y", .command))
        XCTAssertFalse(swallowed("Y", [.command, .shift]))
        XCTAssertFalse(swallowed(",", .command))
        for edit in ["z", "Z", "x", "c", "v", "a"] {
            XCTAssertTrue(swallowed(edit, .command), "⌘\(edit) would edit what is under the panel")
        }
        XCTAssertFalse(PanelKeyboard.swallows(panelUp: true, panelOwnsKeyboard: true, modifiers: [], characters: "a"))
        // Esc is the router's before this question is asked (it dismisses).
    }

    func testOnceThePanelHasTheKeyboardTypingIsNormal() throws {
        XCTAssertTrue(window.makeFirstResponder(panelField))
        XCTAssertTrue(PanelKeyboard.panelOwnsKeyboard(in: window), "its field editor is inside the panel")
        type([key(0, "a"), key(11, "b"), key(51, "\u{7F}"), key(8, "c")])
        XCTAssertEqual(text(panelField), "ac")
    }

    /// A dead key composes through the panel field's input system like in
    /// any field: ⌥E then E is "é". Skipped on a layout without that key.
    func testADeadKeyComposesInThePanelField() throws {
        XCTAssertTrue(window.makeFirstResponder(historyField))
        let probe = try XCTUnwrap(window.firstResponder as? NSTextView)
        probe.inputContext?.activate()
        PanelKeyboard.host = nil      // no panel: the plain field, as a baseline
        type([try hardwareKey(14, .maskAlternate), try hardwareKey(14)], panelUp: false)
        let baseline = probe.string
        probe.inputContext?.deactivate()
        try XCTSkipUnless(baseline == "é", "this keyboard layout has no ⌥E dead key (typed \(baseline))")
        PanelKeyboard.host = panelHost

        XCTAssertTrue(window.makeFirstResponder(panelField))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.inputContext?.activate()
        defer { editor.inputContext?.deactivate() }
        type([try hardwareKey(14, .maskAlternate), try hardwareKey(14)])
        XCTAssertEqual(text(panelField), "é")
    }

    /// The panel's field loses the keyboard while the panel is still up (a
    /// tab switch moved focus to its terminal): keys stop again, and flow
    /// once the field has it back.
    func testLosingTheKeyboardWhileThePanelIsUpGatesTypingAgain() {
        XCTAssertTrue(window.makeFirstResponder(panelField))
        type([key(0, "a")])
        XCTAssertTrue(window.makeFirstResponder(terminal))
        type([key(11, "b"), key(36, "\r")])
        XCTAssertEqual(terminal.keys, [], "the terminal under the panel gets nothing")
        XCTAssertTrue(window.makeFirstResponder(panelField))
        (window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        type([key(8, "c")])
        XCTAssertEqual(text(panelField), "ac")
    }
}
