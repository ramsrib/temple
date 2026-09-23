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

/// Ask for a folder to work in. This is how a project Temple has never seen gets
/// in: the sidebar only knows projects the agents have already run in, so every
/// other entry point can offer nothing but what already exists.
@MainActor
func chooseProjectFolder(_ then: (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a project folder to start a session in"
    if panel.runModal() == .OK, let url = panel.url {
        then(url.path)
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
