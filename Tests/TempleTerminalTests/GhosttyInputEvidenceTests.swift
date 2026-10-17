import XCTest
import AppKit
import TempleTerminalAPI
@testable import TempleTerminal

/// Every way input reaches the terminal reports itself (`surfaceDidReceiveInput`),
/// not only a plain Return: keypad Enter, a single key, ⌘V (Ghostty's paste
/// keybind), Esc, and text committed outside a key press (an IME commit, a
/// drop). The Return heuristic (`surfaceDidSubmitInput`) is untouched.
/// No surface is started: the report comes first. Sorts before `GhosttyRuntimeTests`,
/// whose last test shuts the runtime down.
@MainActor
final class GhosttyInputEvidenceTests: XCTestCase {
    private final class Recorder: TerminalSurfaceDelegate {
        var inputs = 0, submits = 0
        func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {}
        func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {}
        func surfaceDidRing(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {}
        func surfaceDidSubmitInput(_ surface: TerminalSurface) { submits += 1 }
        func surfaceDidReceiveInput(_ surface: TerminalSurface) { inputs += 1 }
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    func testEveryInputPathReportsItself() {
        let surface = GhosttyTerminalSurface(app: GhosttyApp.shared, appearance: .default)
        let recorder = Recorder()
        surface.delegate = recorder
        let view = try! XCTUnwrap(surface.view as? GhosttySurfaceView)
        view.keyDown(with: key(76, "\u{3}"))                 // keypad Enter
        XCTAssertEqual(recorder.inputs, 1); XCTAssertEqual(recorder.submits, 0, "not a plain Return")
        view.keyDown(with: key(16, "y"))                      // a single key answering a prompt
        view.keyDown(with: key(9, "v", .command))             // ⌘V: Ghostty's paste
        view.keyDown(with: key(53, "\u{1b}"))                 // Esc
        XCTAssertEqual(recorder.inputs, 4)
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))  // IME commit / drop
        XCTAssertEqual(recorder.inputs, 5)
        view.keyDown(with: key(36, "\r"))                     // a plain Return is input too
        XCTAssertEqual(recorder.inputs, 6)
    }

    private func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Mouse input counts when the program has mouse reporting on (it
    /// reaches the pty: a click can answer a prompt), and a focus click, a
    /// selection drag or a move does not when it hasn't.
    func testMouseInputCountsOnlyWhenTheProgramCapturesIt() {
        let surface = GhosttyTerminalSurface(app: GhosttyApp.shared, appearance: .default)
        let recorder = Recorder()
        surface.delegate = recorder
        let view = try! XCTUnwrap(surface.view as? GhosttySurfaceView)
        var captured = false
        view.mouseReachesProgram = { captured }
        view.mouseDown(with: mouse(.leftMouseDown))       // a focus click
        view.mouseUp(with: mouse(.leftMouseUp))
        view.mouseDragged(with: mouse(.leftMouseDragged))  // a selection
        view.mouseMoved(with: mouse(.mouseMoved))
        XCTAssertEqual(recorder.inputs, 0, "Temple's own mouse handling is not input")
        captured = true
        view.mouseDown(with: mouse(.leftMouseDown))        // answering a prompt
        view.mouseUp(with: mouse(.leftMouseUp))
        view.rightMouseDown(with: mouse(.rightMouseDown))
        view.otherMouseUp(with: mouse(.otherMouseUp))
        view.mouseDragged(with: mouse(.leftMouseDragged))
        XCTAssertEqual(recorder.inputs, 5)
        view.mouseMoved(with: mouse(.mouseMoved))
        XCTAssertEqual(recorder.inputs, 5, "a move is not a click, a release, a drag or a scroll")
        let scroll = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                              wheel1: -3, wheel2: 0, wheel3: 0)!)!
        view.scrollWheel(with: scroll)
        XCTAssertEqual(recorder.inputs, 6, "a scroll the program captures")
        captured = false
        view.scrollWheel(with: scroll)
        XCTAssertEqual(recorder.inputs, 6, "a scroll through Temple's own scrollback")
        XCTAssertEqual(recorder.submits, 0)
    }

    /// A middle-click with the mouse not captured pastes (libghostty asks
    /// for the clipboard): the click itself is not input, the paste is,
    /// at the one place every paste is handed over.
    func testAnUncapturedMiddleClickPasteIsInputWhereThePasteIsDelivered() {
        let surface = GhosttyTerminalSurface(app: GhosttyApp.shared, appearance: .default)
        let recorder = Recorder()
        surface.delegate = recorder
        let view = try! XCTUnwrap(surface.view as? GhosttySurfaceView)
        view.mouseReachesProgram = { false }
        view.otherMouseDown(with: mouse(.otherMouseDown))
        view.otherMouseUp(with: mouse(.otherMouseUp))
        XCTAssertEqual(recorder.inputs, 0, "the click itself reaches no program")
        // What libghostty's clipboard request then does (onReadClipboard).
        view.deliverClipboard("pasted prompt", state: nil, confirmed: false)
        XCTAssertEqual(recorder.inputs, 1)
        // A confirmed (unsafe) paste is delivered the same way.
        view.deliverClipboard("rm -rf x\n", state: nil, confirmed: true)
        XCTAssertEqual(recorder.inputs, 2)
    }

    /// libghostty titles a terminal with its pwd, byte for byte, when the
    /// program sets an empty title (tmux does, while the pane is untitled)
    /// or reports a pwd before any title: that is this Mac's launch folder
    /// (for a tab on a host, the home its ssh runs in). It reaches Temple as
    /// a stand-in title (activity, not display). Exactly the pwd's bytes:
    /// another trailing slash or another Unicode spelling is the program's.
    func testATitleThatIsExactlyThePwdIsAStandIn() {
        final class Titles: TerminalSurfaceDelegate {
            var shown: [String] = [], standIns: [String] = []
            func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {}
            func surface(_ surface: TerminalSurface, didUpdateTitle title: String) { shown.append(title) }
            func surface(_ surface: TerminalSurface, didUpdateStandInTitle title: String) { standIns.append(title) }
            func surfaceDidRing(_ surface: TerminalSurface) {}
            func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {}
        }
        let surface = GhosttyTerminalSurface(app: GhosttyApp.shared, appearance: .default)
        let recorder = Titles()
        surface.delegate = recorder
        let view = try! XCTUnwrap(surface.view as? GhosttySurfaceView)
        let nfc = "/Users/caf\u{E9}", nfd = "/Users/cafe\u{301}"
        view.terminalPwd = nfc
        view.handleTitle(nfc)               // tmux's empty title, as libghostty reports it
        view.handleTitle(nfc + "/")         // another trailing slash: the program's
        view.handleTitle(nfd)               // another spelling (equal as Swift Strings): the program's
        view.handleTitle("Agent title")
        view.handlePwd("/Users/me/project") // OSC 7, then a title before any: the pwd
        view.handleTitle("/Users/me/project")
        view.handleTitle(nfc)               // no longer the pwd: the program's
        view.handlePwd("")
        view.handleTitle("/Users/me/project")
        XCTAssertEqual(recorder.standIns.map { Array($0.utf8) }, [Array(nfc.utf8), Array("/Users/me/project".utf8)])
        XCTAssertEqual(recorder.shown.map { Array($0.utf8) },
                       [nfc + "/", nfd, "Agent title", nfc, "/Users/me/project"].map { Array($0.utf8) })
        XCTAssertFalse(GhosttySurfaceView.isStandIn("x", pwd: nil))
    }
}
