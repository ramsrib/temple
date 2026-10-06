import AppKit
import XCTest
@testable import TempleUI

/// ⌘Z after a History Restore must reach the window's undo stack while the
/// search field has the keyboard. SwiftUI's field editor keeps a stack of its
/// own, which Edit ▸ Undo asks first; `FieldEditorUndo` empties that one and
/// never the window's. (That an empty field-editor stack lets ⌘Z through to
/// the window is AppKit's behaviour, measured by hand; see the type's doc.)
@MainActor
final class FieldEditorUndoTests: XCTestCase {
    /// A text view with an undo manager of its own, as SwiftUI's field editor has.
    private final class PrivateUndoTextView: NSTextView {
        let ownUndo = UndoManager()
        override var undoManager: UndoManager? { ownUndo }
    }

    /// A text view whose undo goes to the window's stack, as AppKit's own
    /// field editor's does.
    private final class SharedUndoTextView: NSTextView {
        override var undoManager: UndoManager? { window?.undoManager }
    }

    private final class Target {}

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func register(_ manager: UndoManager, _ target: Target) {
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { _ in }
        manager.endUndoGrouping()
    }

    func testForgetsTheFocusedFieldsOwnStackAndKeepsTheWindows() throws {
        let window = window()
        let field = PrivateUndoTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let target = Target()
        let windowUndo = try XCTUnwrap(window.undoManager)
        register(field.ownUndo, target)      // the query typed and cleared
        register(windowUndo, target)         // the Restore
        XCTAssertTrue(field.ownUndo.canUndo)

        XCTAssertTrue(FieldEditorUndo.forget(in: window))
        XCTAssertFalse(field.ownUndo.canUndo, "the field's text undo is gone")
        XCTAssertTrue(windowUndo.canUndo, "the Restore is still on the window's stack")
    }

    /// A text view that shares the window's stack has nothing of its own to
    /// forget: emptying it would throw away the Restore too.
    func testNeverEmptiesTheWindowsStack() throws {
        let window = window()
        let field = SharedUndoTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let windowUndo = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(field.undoManager === windowUndo)
        let target = Target()
        register(windowUndo, target)

        XCTAssertFalse(FieldEditorUndo.forget(in: window))
        XCTAssertTrue(windowUndo.canUndo)
    }

    func testDoesNothingWithoutAFocusedField() {
        let window = window()
        XCTAssertFalse(FieldEditorUndo.forget(in: window))
        XCTAssertFalse(FieldEditorUndo.forget(in: nil))
    }
}
