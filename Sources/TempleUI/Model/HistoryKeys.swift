import AppKit

/// Which text field, if any, has the keyboard while the History tab is active.
public enum HistoryKeyFocus: Equatable, Sendable {
    /// No text field: the list itself.
    case none
    /// History's own search field.
    case historySearch
    /// Any other field — the sidebar search, a chip being renamed. Its keys
    /// are its own: Return commits it, Esc ends it, ⌘A selects its text.
    case foreignField
}

/// What History does with a key.
public enum HistoryKeyCommand: Equatable, Sendable {
    case moveCursor(by: Int, extend: Bool)
    case moveToEnd(top: Bool, extend: Bool)
    case moveByDay(forward: Bool, extend: Bool)
    case open
    case escape
    case selectAll
    case importSelection
    case refresh
    case focusSearch
    case copyResumeCommands
}

public enum HistoryKeyRoute: Equatable, Sendable {
    /// A sheet (the import confirmation, its failure alert) owns the
    /// keyboard: the event goes to it, past every Temple binding — ⌘W, ⌘Y
    /// and ⌘K included, exactly as for the close confirmation.
    case toSheet
    /// Not History's: on to the general bindings, then the responder chain.
    case general
    case history(HistoryKeyCommand)
}

/// The History tab's key map, as a pure decision so it can be tested without
/// an event or a window. RootView's key monitor asks it on every keyDown while
/// History is the active tab.
enum HistoryKeys {
    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers`.
    ///   - searchHasSelection: text is selected in History's search field
    ///     (⌘C then copies that text, not resume commands).
    static func route(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                      focus: HistoryKeyFocus, sheetAttached: Bool,
                      searchHasSelection: Bool = false) -> HistoryKeyRoute {
        if sheetAttached { return .toSheet }
        // Another field has the keyboard: none of History's keys are taken
        // from it. ⌘F and ⌘R still reach History through their menu items.
        if focus == .foreignField { return .general }

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { return .general }
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        switch keyCode {
        case 125, 126:   // ↓ ↑ (⇧ extends, ⌥ jumps a day, ⌘ to the end)
            let down = keyCode == 125
            if cmd { return .history(.moveToEnd(top: !down, extend: shift)) }
            if option { return .history(.moveByDay(forward: down, extend: shift)) }
            return .history(.moveCursor(by: down ? 1 : -1, extend: shift))
        case 36, 76:     // return / enter
            return cmd ? .general : .history(.open)
        case 53:         // esc: clear search → clear selection → previous tab
            return .history(.escape)
        default:
            break
        }

        guard cmd, !option else { return .general }
        switch characters.lowercased() {
        case "a": return .history(.selectAll)
        case "i": return .history(.importSelection)
        case "r": return .history(.refresh)
        case "f": return .history(.focusSearch)
        case "c": return searchHasSelection ? .general : .history(.copyResumeCommands)
        default: return .general
        }
    }
}
