/// Who may take the window's keyboard while a floating panel (⌘K, the ⌘N
/// picker, the ⌘/ card) is up: nobody but the panel.
///
/// The app holds the keyboard for the panel from the call that presents it
/// (`hold`) until the call that puts the last panel away (`release`). In
/// between, a terminal asking for focus (tab activation, a deferred claim),
/// or another field (History's search) does not get it. Each hold and
/// release starts a new epoch, and a focus request is a ticket for the epoch
/// it was made in: a claim that was waiting when a panel opened, or that
/// outlived one, cannot take the keyboard back afterwards.
@MainActor
public enum OverlayKeyboard {
    /// A panel holds the keyboard.
    public private(set) static var isHeld = false
    /// Bumped by every hold and release.
    public private(set) static var epoch = 0
    /// Someone asked for the keyboard (took a ticket) since the last
    /// hold or release: the panel's dismissal then leaves focus to them.
    public private(set) static var requestedSinceChange = false

    public static func hold() { change(held: true) }
    public static func release() { change(held: false) }

    private static func change(held: Bool) {
        isHeld = held
        epoch += 1
        requestedSinceChange = false
    }

    /// A request to take the keyboard: nil while a panel holds it (the
    /// request is refused), else a ticket to claim with.
    public static func ticket() -> Int? {
        guard !isHeld else { return nil }
        requestedSinceChange = true
        return epoch
    }

    /// Whether a ticket may still take the keyboard now.
    public static func mayClaim(_ ticket: Int) -> Bool { !isHeld && ticket == epoch }
}
