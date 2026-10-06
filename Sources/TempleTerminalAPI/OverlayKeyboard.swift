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

    /// The latest request refused while a panel held the keyboard, to be
    /// made again when the last panel goes: the panel's own action (⌘N
    /// starting a session, ⌘1 activating a tab) asked for it, so it is
    /// where the keyboard goes next.
    private static var deferred: (@MainActor () -> Void)?

    public static func hold() { change(held: true) }

    /// The last panel is gone: a request deferred while it was up is made
    /// again now, before anything else can ask.
    public static func release() {
        change(held: false)
        let retry = deferred
        deferred = nil
        retry?()
    }

    private static func change(held: Bool) {
        isHeld = held
        epoch += 1
        requestedSinceChange = false
    }

    /// A request to take the keyboard: a ticket to claim with, or nil while
    /// a panel holds it. A refused request is kept (`retry`, the latest one
    /// wins) and made again on `release`.
    public static func ticket(retry: (@MainActor () -> Void)? = nil) -> Int? {
        guard !isHeld else {
            if let retry { deferred = retry }
            return nil
        }
        requestedSinceChange = true
        return epoch
    }

    /// The app's owner of the keyboard puts it back where a panel wants it.
    public static var onAdmissionRefused: (@MainActor () -> Void)?

    /// A terminal refused to become the first responder because a panel
    /// holds the keyboard. AppKit then leaves the window itself as the first
    /// responder; the owner seats the panel again.
    public static func admissionRefused() { onAdmissionRefused?() }

    /// Whether a ticket may still take the keyboard now.
    public static func mayClaim(_ ticket: Int) -> Bool { !isHeld && ticket == epoch }
}
