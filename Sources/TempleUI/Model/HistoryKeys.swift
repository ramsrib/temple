import AppKit

/// Which text field, if any, has the keyboard while the History tab is active.
public enum HistoryKeyFocus: Equatable, Sendable {
    /// No text field: the list itself.
    case none
    /// History's own search field. Its editing keys are its own (⌘A, ⌘C,
    /// ⌘X, ⌘V, ⌘Z, ⌘⌫, ⇧ with an arrow); the keys a one-line field has no use
    /// for (↑ ↓ without ⇧, Return, Esc, Tab) and History's own ⌘I, ⌘R and ⌘F
    /// still drive the page, so typing then Return opens the first match.
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
    /// ⌘⌫: archive the selection, when every row of it can be.
    case archiveSelection
    case refresh
    case focusSearch
    /// Tab from History's search field: the keyboard goes to the list, where
    /// ⌘A, ⌘C, ⌘⌫ and ⇧-arrows act on rows.
    case focusList
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
    /// One rule decides between a text field and the list: while a text
    /// field has the keyboard, every key that edits or selects text is the
    /// field's, whatever History has selected (⌘A in the search field
    /// selects the typed text, never the rows). The list's ⌘A, ⌘C, ⌘⌫ and
    /// ⇧-arrows act on rows only when no field has the keyboard: after a
    /// click on a row, or Tab from the search field.
    ///
    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers`.
    static func route(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags,
                      focus: HistoryKeyFocus, sheetAttached: Bool) -> HistoryKeyRoute {
        if sheetAttached { return .toSheet }
        // Another field has the keyboard: none of History's keys are taken
        // from it. ⌘F and ⌘R still reach History through their menu items.
        if focus == .foreignField { return .general }
        let editing = focus == .historySearch

        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { return .general }
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        switch keyCode {
        case 125, 126:   // ↓ ↑ (⇧ extends, ⌥ jumps a day, ⌘ to the end)
            // ⇧ with an arrow selects text in a field.
            if editing && shift { return .general }
            let down = keyCode == 125
            if cmd { return .history(.moveToEnd(top: !down, extend: shift)) }
            if option { return .history(.moveByDay(forward: down, extend: shift)) }
            return .history(.moveCursor(by: down ? 1 : -1, extend: shift))
        case 36, 76:     // return / enter
            return cmd ? .general : .history(.open)
        case 53:         // esc: clear search → the chip → selection → previous tab
            return .history(.escape)
        case 48 where editing && flags.isEmpty:   // tab: from the search to the list
            return .history(.focusList)
        case 51 where cmd && !option && !shift:   // ⌘⌫: the field's delete, else archive
            return editing ? .general : .history(.archiveSelection)
        default:
            break
        }

        guard cmd, !option else { return .general }
        switch characters.lowercased() {
        case "a": return editing ? .general : .history(.selectAll)
        case "c": return editing ? .general : .history(.copyResumeCommands)
        case "i": return .history(.importSelection)
        case "r": return .history(.refresh)
        case "f": return .history(.focusSearch)
        default: return .general
        }
    }

    /// What a key did, for the router: handled, nothing (the key goes on),
    /// leave History, or put text on the pasteboard.
    enum Effect: Equatable {
        case handled, notHandled, leave
        case copy(String)
    }

    /// A History key's command, carried out. The selection commands go to
    /// the model unconditionally (`HistoryModel.issue`): whether one applies
    /// is the model's to decide when it runs, against the page it targets.
    @MainActor
    static func perform(_ command: HistoryKeyCommand, on history: HistoryModel, undoManager: UndoManager?) -> Effect {
        switch command {
        case .moveCursor(let delta, let extend):
            history.issue(.moveCursor(by: delta, extend: extend))
        case .moveToEnd(let top, let extend):
            history.issue(.moveToEnd(top: top, extend: extend))
        case .moveByDay(let forward, let extend):
            history.issue(.moveByDay(forward: forward, extend: extend))
        case .open:
            history.issue(.open, undoManager: undoManager)
        case .archiveSelection:
            history.issue(.archiveSelection, undoManager: undoManager)
        case .selectAll:
            history.issue(.selectAll)
        case .importSelection:
            history.issue(.importSelection)
        case .escape:
            return history.escape() == .leave ? .leave : .handled
        case .refresh:
            history.refresh()
        case .focusSearch:
            history.requestSearchFocus()
        case .focusList:
            history.requestListFocus()
        case .copyResumeCommands:
            let rows = history.selectedRows
            guard !rows.isEmpty else { return .notHandled }
            return .copy(rows.map { $0.resumeArgv.joined(separator: " ") }.joined(separator: "\n"))
        }
        return .handled
    }
}
