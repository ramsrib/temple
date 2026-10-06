import SwiftUI
import AppKit
import TempleCore

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @MainActor
    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Ask for a folder to work in. This is how a project Temple has never seen gets
/// in: the sidebar only knows projects the agents have already run in, so every
/// other entry point can offer nothing but what already exists.
@MainActor
/// The panel browses this Mac, so the folder is a local project.
func chooseProjectFolder(_ then: (ProjectKey) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a project folder to start a session in"
    if panel.runModal() == .OK, let url = panel.url {
        then(ProjectKey(host: .local, path: url.path))
    }
}

/// Moving keyboard focus INTO a SwiftUI text field while a terminal is up.
///
/// A live terminal is a raw AppKit `NSView` holding the window's first
/// responder, and SwiftUI's `@FocusState` will not take the responder from it —
/// so ⌘K / ⌘F would open the field but leave every keystroke going to the agent.
/// Resign the terminal first, then set the focus binding on the next runloop
/// turn, once SwiftUI can install its field editor.
enum FieldFocus {
    @MainActor
    static func claim(_ focus: @escaping @MainActor () -> Void) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !(window?.firstResponder is NSTextView) {  // field editor == already a text field
            window?.makeFirstResponder(nil)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated(focus) }
    }
}

/// ⌘Z asks the focused field's own undo stack before the window's.
///
/// SwiftUI's text field editor keeps an undo manager of its own, not the
/// window's, and while it can undo, Edit ▸ Undo goes to it. So with History's
/// search field holding the keyboard, ⌘Z after a Restore brought back a query
/// typed and cleared earlier instead of undoing the Restore the page had just
/// offered to undo (measured on macOS 27: with the field editor's stack empty,
/// the same ⌘Z reaches the window's). A field that ends editing drops its
/// stack anyway, so a field without the keyboard has nothing to forget.
enum FieldEditorUndo {
    /// Empties the focused field editor's own undo stack, never the window's.
    /// Returns whether there was one to empty.
    @MainActor
    @discardableResult
    static func forget(in window: NSWindow?) -> Bool {
        guard let window, let editor = window.firstResponder as? NSTextView,
              let own = editor.undoManager, own !== window.undoManager else { return false }
        own.removeAllActions()
        return true
    }

    /// Empties `control`'s own undo stack, and nothing else: only when the
    /// control is editing and its editor is its window's first responder.
    @MainActor
    @discardableResult
    static func forget(editing control: NSControl?) -> Bool {
        guard let control, let window = control.window, let editor = control.currentEditor(),
              window.firstResponder === editor else { return false }
        return forget(in: window)
    }
}

/// A small colored activity dot: running / idle / needs-attention / exited.
/// The dot that pulses is the one asking for you: an agent waiting on input
/// in a tab you are not looking at. Running needs nothing from you, so it
/// holds still — six working agents should not mean twelve breathing dots.
/// The pulse is the system symbol effect, not a repeatForever animation:
/// that one is a single transaction any ancestor's `withAnimation` (a
/// disclosure toggle, ⌘B) could interrupt and leave parked mid-breath.
struct ActivityDot: View {
    let state: ActivityState
    var size: CGFloat = 6

    var body: some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(state.dotColor)
            .symbolEffect(.pulse, options: .repeating, isActive: state == .needsAttention)
            .opacity(state.showsDot ? 1 : 0)
    }
}
