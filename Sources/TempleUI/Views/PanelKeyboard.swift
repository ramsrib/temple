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

    /// Whether the router keeps a key from what is under the panel: every
    /// key and chord except Esc and the ⌘ shortcuts Temple's key router and
    /// menus answer, or the system's own (⌘Q, ⌘H, ⌘M, ⌘`). An allowlist,
    /// because a terminal turns chords nobody listed into input of its own
    /// (⌘⌫, ⌘← and ⌘→ are ⌃U, ⌃A and ⌃E in Ghostty). Only keys aimed at the
    /// window the panel is in are ever kept: a sheet or modal window of its
    /// own (the folder chooser) is never touched.
    static func swallows(panelUp: Bool, window: NSWindow?, keyCode: UInt16,
                         modifiers: NSEvent.ModifierFlags, characters: String) -> Bool {
        guard panelUp, let host, let window, window === host.window,
              !panelOwnsKeyboard(in: window) else { return false }
        return !passesUnderPanel(keyCode: keyCode, modifiers: modifiers, characters: characters)
    }

    /// The keys that act while a panel lacks the keyboard.
    static func passesUnderPanel(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) -> Bool {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if keyCode == 53 { return true }                                  // Esc dismisses
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        if [33, 30].contains(keyCode) { return true }                     // ⌘⇧[ / ⌘⇧]
        return shortcutCharacters.contains(characters.lowercased())
    }

    /// `charactersIgnoringModifiers` of the ⌘ chords that are commands, not
    /// editing: Temple's (TempleCommands and RootView's router) and the
    /// system's. Not ⌘Z/X/C/V/A, which would edit the field or terminal
    /// under the panel.
    static let shortcutCharacters: Set<String> = [
        "t", "w", "n", "o", "h", "f", "g", "k", "y", "p", "b", "r", "/", ",",
        "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "q", "m", "`",
    ]
}
