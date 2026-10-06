import AppKit

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

    /// The responder that holds the keyboard for a panel; the app sets it.
    public static weak var placeholder: NSResponder?
    /// A deferred request is being made again (`release`).
    private static var replaying = false

    public static func hold() { change(held: true) }

    /// The last panel is gone: a request deferred while it was up is made
    /// again now, before anything else can ask.
    public static func release() {
        change(held: false)
        let retry = deferred
        deferred = nil
        replaying = true
        defer { replaying = false }
        retry?()
    }

    private static func change(held: Bool) {
        isHeld = held
        epoch += 1
        requestedSinceChange = false
    }

    /// A request's right to take the keyboard, for the epoch it was made in.
    public struct Ticket: Equatable, Sendable {
        let epoch: Int
        /// Made again on `release` after being kept while a panel was up.
        let replayed: Bool
    }

    /// A request to take the keyboard: a ticket to claim with, or nil while
    /// a panel holds it. A refused request is kept (`retry`, the latest one
    /// wins) and made again on `release`.
    public static func ticket(retry: (@MainActor () -> Void)? = nil) -> Ticket? {
        guard !isHeld else {
            if let retry { deferred = retry }
            return nil
        }
        requestedSinceChange = true
        return Ticket(epoch: epoch, replayed: replaying)
    }

    /// The app's owner of the keyboard puts it back where a panel wants it.
    public static var onAdmissionRefused: (@MainActor () -> Void)?

    /// A terminal refused to become the first responder because a panel
    /// holds the keyboard. AppKit then leaves the window itself as the first
    /// responder; the owner seats the panel again.
    public static func admissionRefused() { onAdmissionRefused?() }

    /// Whether a ticket may still take the keyboard now, in `window`, for
    /// `requester`. A request kept through a panel and made again on its
    /// release is the user's earlier intent, not a fresh one: by the time its
    /// claim runs they may have focused something else themselves, so it
    /// claims only while the keyboard is still with nobody, the window, the
    /// panel's placeholder or the requester.
    public static func mayClaim(_ ticket: Ticket, in window: NSWindow?, by requester: NSResponder? = nil) -> Bool {
        guard !isHeld, ticket.epoch == epoch else { return false }
        guard ticket.replayed else { return true }
        let holder = window?.firstResponder
        return holder == nil || holder === window || holder === placeholder
            || (requester != nil && holder === requester)
    }
}
