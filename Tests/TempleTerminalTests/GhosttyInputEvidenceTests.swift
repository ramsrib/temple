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
}
