import SwiftUI
import AppKit

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

/// A small colored activity dot (running / needs-attention). Hidden when idle.
struct ActivityDot: View {
    let state: ActivityState
    var size: CGFloat = 6
    var body: some View {
        Circle()
            .fill(state.dotColor)
            .frame(width: size, height: size)
            .opacity(state.showsDot ? 1 : 0)
    }
}
