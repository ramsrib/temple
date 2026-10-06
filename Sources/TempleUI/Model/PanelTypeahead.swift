import AppKit

/// The keys typed into a ⌘K / ⌘N panel before its field holds the keyboard.
///
/// Keys queued behind the chord are dispatched before SwiftUI has drawn the
/// panel, so they used to land in whatever had the keyboard: History's
/// search field took "depl" and the palette "oy", and over a terminal the
/// agent got them. The key router hands every plain key of that gap here
/// (`hold`), and once the panel's field is the first responder the original
/// events are sent again, in order, through the app's normal path
/// (`fieldFocused`). So the field's input system sees them as if they were
/// typed after focus: an input method composes, a dead key combines with the
/// next key, ⌫ deletes, ↓ moves the highlight and Return submits.
///
/// Held events belong to one presentation of one panel: opening or closing a
/// panel (`reset`) drops them, so a panel dismissed before its field took the
/// keyboard delivers nothing anywhere, least of all to a terminal beneath.
/// Esc and ⌘ / ⌃ chords are never held; the router acts on them at once.
@MainActor
public final class PanelKeyHold {
    /// How a held event is sent again. The app's own `sendEvent`, so the
    /// event takes the path a fresh key would (the key router included,
    /// which lets it through while `isReplaying`).
    var deliver: (NSEvent) -> Void = { NSApp.sendEvent($0) }
    /// When the replay runs: a turn after the field took focus, outside the
    /// SwiftUI update that reported it.
    var schedule: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    /// The events held so far, oldest first.
    public private(set) var held: [NSEvent] = []
    /// The field has the keyboard and every held event has been sent: keys
    /// go to it directly from here on.
    public private(set) var fieldReady = false
    /// A held event is being sent again right now.
    public private(set) var isReplaying = false
    private var replayScheduled = false
    /// Bumped by `reset`: a replay scheduled for an earlier presentation
    /// sends nothing.
    private var presentation = 0

    public init() {}

    /// A panel opened or closed: whatever was held for the last one is
    /// dropped, undelivered.
    public func reset() {
        presentation += 1
        held = []
        fieldReady = false
        isReplaying = false
        replayScheduled = false
    }

    /// Takes a key the router saw while a panel with a field is up and that
    /// field does not have the keyboard yet. Returns whether it was taken.
    /// Only key-downs without ⌘ or ⌃ are held, and never Esc (key code 53).
    public func hold(_ event: NSEvent, panelUp: Bool) -> Bool {
        guard panelUp, !fieldReady, !isReplaying, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), event.keyCode != 53 else { return false }
        held.append(event)
        return true
    }

    /// The panel's field is the first responder. Keys that arrive before the
    /// replay runs are still held, behind the earlier ones.
    public func fieldFocused() {
        guard !fieldReady, !replayScheduled else { return }
        replayScheduled = true
        let presentation = self.presentation
        schedule { [weak self] in self?.replay(presentation) }
    }

    private func replay(_ presentation: Int) {
        guard presentation == self.presentation else { return }
        isReplaying = true
        // One at a time from the front: a held Return can close the panel,
        // and its reset then empties the rest, which nobody receives.
        while presentation == self.presentation, !held.isEmpty {
            deliver(held.removeFirst())
        }
        guard presentation == self.presentation else { return }
        isReplaying = false
        fieldReady = true
    }
}
