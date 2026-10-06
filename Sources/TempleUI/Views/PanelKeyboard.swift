import AppKit

/// Whether the keyboard is in the floating panel that is up (⌘K, the ⌘N
/// picker, the ⌘/ card), and what the key router does with a key when it
/// is not.
///
/// A panel's field takes the keyboard a turn or two after the panel is
/// asked for: SwiftUI has to draw it first, and keys already queued behind
/// the chord are dispatched before that. They used to land in whatever had
/// the keyboard, History's search field or a live terminal. Until the panel
/// really holds the first responder, the router swallows them instead:
/// keys typed in that gap are lost, never delivered to the wrong place.
/// Esc and the app's ⌘ shortcuts still act. (The ⌘/ card has no field, so
/// for it the gap lasts as long as the card is up.)
@MainActor
enum PanelKeyboard {
    /// The hosting view of the panel that is up; set by the overlay that
    /// draws it.
    static weak var host: NSView?

    /// The window's first responder is inside the panel (for a text field,
    /// its field editor is a subview of the field while it edits).
    static func panelOwnsKeyboard(in window: NSWindow?) -> Bool {
        guard let host, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: host)
    }

    /// Whether the router keeps a key from what is under the panel. Plain
    /// keys and ⌃ chords are kept back, and so are the ⌘ chords that edit
    /// text (undo, redo, cut, copy, paste, select all), which would act on
    /// the field or terminal under the panel. Every other ⌘ chord is the
    /// app's, and goes on.
    static func swallows(panelUp: Bool, panelOwnsKeyboard: Bool,
                         modifiers: NSEvent.ModifierFlags, characters: String) -> Bool {
        guard panelUp, !panelOwnsKeyboard else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return true }
        return ["z", "x", "c", "v", "a"].contains(characters.lowercased())
    }
}
