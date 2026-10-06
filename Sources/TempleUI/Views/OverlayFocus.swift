import AppKit
import TempleTerminalAPI

/// The one owner of the keyboard while a floating panel is up (⌘K, the ⌘N
/// picker, the ⌘/ card).
///
/// A panel's field can only take the keyboard once SwiftUI has drawn it, a
/// turn or more after the chord, and keys queued behind the chord used to
/// land in whatever had the keyboard before: History's search field, or a
/// live terminal. So in the same call that presents a panel, an inert
/// responder in the window takes the keyboard (it swallows every key that
/// reaches it; menu and router shortcuts act before it is asked), and the
/// panel's field takes it from there when it mounts, once per presentation.
/// While a panel is up nothing else may take it (`OverlayKeyboard`: terminal
/// focus and History's search wait). Going from one panel to another keeps
/// the keyboard in the panels. Putting the last one away gives it back by
/// intent: to whatever the panel's action asked to focus (a session it
/// opened, History it bridged to), else to the control that had it before.
@MainActor
public final class OverlayFocus {
    private weak var inert: NSView?
    /// The panel up now, by name; nil when none.
    private(set) var panel: String?
    /// One per presentation (and per panel-to-panel hand-over).
    private(set) var token = 0
    private var claimedToken = 0
    /// The control or view that had the keyboard before the first panel:
    /// a text control (never the shared field editor), or a terminal view.
    private weak var restoreTarget: NSView?
    /// Hands the keyboard to the active terminal; the app model sets it.
    var focusActiveTerminal: () -> Void = {}

    public init() {}

    /// The inert responder, in the app's window.
    func attach(inert: NSView) { self.inert = inert }

    /// The app model's panel flags changed: `panel` is the one up now.
    func panelChanged(to panel: String?) {
        guard panel != self.panel else { return }
        let previous = self.panel
        self.panel = panel
        token += 1
        // Without a window (a model in a test) there is no keyboard to own.
        guard let inert, let window = inert.window else { return }
        if panel != nil {
            if previous == nil { restoreTarget = Self.owner(of: window.firstResponder, inert: inert) }
            OverlayKeyboard.hold()
            window.makeFirstResponder(inert)
        } else {
            OverlayKeyboard.release()
            let target = restoreTarget
            restoreTarget = nil
            let epoch = OverlayKeyboard.epoch
            // A turn later, so that whatever the panel's action focuses (it
            // runs right after the panel is put away) has asked first.
            DispatchQueue.main.async { [weak self] in self?.restore(target, epoch: epoch) }
        }
    }

    private func restore(_ target: NSView?, epoch: Int) {
        guard OverlayKeyboard.epoch == epoch, !OverlayKeyboard.isHeld,
              !OverlayKeyboard.requestedSinceChange, let window = inert?.window else { return }
        if let target, target.window === window, !target.isHiddenOrHasHiddenAncestor,
           window.makeFirstResponder(target) {
            // A text field selects all when it takes the keyboard; put the
            // caret back at the end, where typing left it.
            if let editor = window.firstResponder as? NSTextView {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        } else {
            focusActiveTerminal()
        }
    }

    /// A panel's hosting view is in the tree: its first text field takes
    /// the keyboard, once for this presentation. SwiftUI builds the field a
    /// layout pass or two later, so it is looked for over a few turns.
    func panelMounted(_ host: NSView) {
        claim(in: host, token: token, attempts: 30)
    }

    private func claim(in host: NSView, token: Int, attempts: Int) {
        guard token == self.token, panel != nil, claimedToken != token else { return }
        if let window = host.window, let field = Self.firstTextField(in: host) {
            claimedToken = token
            window.makeFirstResponder(field)
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, let host else { return }
            self.claim(in: host, token: token, attempts: attempts - 1)
        }
    }

    static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let field = firstTextField(in: sub) { return field } }
        return nil
    }

    /// What to give the keyboard back to: a field editor stands for the
    /// control it edits; the window itself or the inert responder for nothing.
    static func owner(of responder: NSResponder?, inert: NSView) -> NSView? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
            return control
        }
        guard let view = responder as? NSView, view !== inert else { return nil }
        return view
    }
}

/// Holds the keyboard for a panel that has not taken it yet (or has no
/// field, like the ⌘/ card), and swallows every key that reaches it. Key
/// equivalents (the menus) and Temple's key router act before a key gets
/// here, so Esc and the shortcuts still work; nothing else is classified.
class OverlayInertResponder: NSView {
    override var acceptsFirstResponder: Bool { OverlayKeyboard.isHeld }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func doCommand(by selector: Selector) {}
    override func insertText(_ insertString: Any) {}
}
