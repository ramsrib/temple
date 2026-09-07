import AppKit

/// App-quit lifecycle (ADR-010, U3): drain every live agent process gracefully
/// before the app exits, via a termination delay. Never orphan an agent; never
/// quit mid-write.
@MainActor
public final class TempleAppDelegate: NSObject, NSApplicationDelegate {
    public weak var model: AppModel?

    /// Shown instead of the real alert in tests, which must not block on a modal.
    /// Returns true to proceed with the quit.
    var confirmQuitWhileWorking: ((_ workingCount: Int) -> Bool)?


    /// Retains the close interceptors (`NSWindow.delegate` is weak), one per
    /// window, pruned when that window closes. Doubles as the record of which
    /// windows still exist — see `hasCancellableWindow`.
    private var closeInterceptors: [ObjectIdentifier: WindowCloseInterceptor] = [:]

    /// Is there a window the user would be handed back if they cancelled?
    ///
    /// Deliberately about the window's *lifetime*, not whether it is on screen.
    /// The first version asked `isVisible && canBecomeMain`, which is false for a
    /// minimized or ⌘H-hidden app — both perfectly restorable — so quitting from
    /// the Dock with work running skipped the warning and killed the agent in
    /// silence. A window that has posted `willClose` is gone and drops out of the
    /// dictionary; a hidden one has not and stays.
    var hasCancellableWindow: () -> Bool = { true }

    public override init() {
        super.init()
        hasCancellableWindow = { [weak self] in !(self?.closeInterceptors.isEmpty ?? true) }
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Temple has its own tab system; macOS window tabbing would stack
        // whole windows in a second tab bar under the chip strip. Opting out
        // also removes View's confusing "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        WindowSnapshot.installIfRequested()
        // Re-checked on every activation rather than installed once: SwiftUI owns
        // the delegate and may re-seat it, and a latch that lost the race would
        // silently restore the close-then-ask behavior this exists to prevent.
        // (Same reasoning as the titlebar strip's self-healing band claim.)
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    self.interceptClose(of: window)
                }
            }
        }
        // Drop the proxy for a window that has gone, so neither it nor the
        // SwiftUI delegate it retains outlives the window.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                self.closeInterceptors.removeValue(forKey: ObjectIdentifier(window))
            }
        }
        // Those notifications are edge-triggered, so a window that became main
        // before this ran would never be intercepted. Sweep what exists now, and
        // again next turn for the window SwiftUI is still building.
        sweepWindows()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.sweepWindows() }
        }
    }

    private func sweepWindows() {
        for window in NSApp.windows { interceptClose(of: window) }
    }

    /// Route the close button through the quit path *before* the window goes away.
    ///
    /// The close button used to be wired the other way round: AppKit closed the
    /// window, `applicationShouldTerminateAfterLastWindowClosed` then started the
    /// quit, and the "an agent is still working" prompt appeared over nothing.
    /// Cancel could not put the window back — it was already destroyed — and
    /// SwiftUI, having lost the only window of its `WindowGroup`, tore the scene
    /// down and exited anyway. So Cancel lost the work it offered to protect.
    ///
    /// Asking first fixes both halves: the window is still there while the prompt
    /// is up, so Cancel is simply "nothing happened".
    private func interceptClose(of window: NSWindow) {
        // Alerts and panels get a window of their own; only the app's real
        // window is the one whose close means "quit".
        guard window.canBecomeMain, !(window is NSPanel) else { return }
        guard !(window.delegate is WindowCloseInterceptor) else { return }
        let interceptor = WindowCloseInterceptor(forwardingTo: window.delegate) { [weak self] closing in
            self?.approveCloseForQuit(closing) ?? true
        }
        window.delegate = interceptor
        closeInterceptors[ObjectIdentifier(window)] = interceptor
    }

    /// Answered while the window is still on screen, so "no" is simply
    /// "nothing happened". A "yes" lets the window close, which starts the quit
    /// via `applicationShouldTerminateAfterLastWindowClosed` — and is remembered
    /// so the drain below does not ask the same question a second time.
    func approveCloseForQuit(_ window: NSWindow? = nil) -> Bool {
        guard let model else { return true }
        let working = model.openSessions.workingTabs.count
        guard working > 0 else { return true }
        guard confirmQuit(workingCount: working) else { return false }
        approvedCloseWindow = window.map(ObjectIdentifier.init) ?? ObjectIdentifier(self)
        // If this close does not turn into the last-window termination, the
        // approval must not survive to be spent by some later quit.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.approvedCloseWindow = nil }
        }
        return true
    }

    /// The window whose close the user just approved. Scoped and short-lived: a
    /// global "already said yes" flag would be banked by a close that did *not*
    /// end up terminating (a second window), then spent by an unrelated ⌘Q that
    /// skipped its own prompt.
    private var approvedCloseWindow: ObjectIdentifier?

    /// True if this termination is the one an approved close started. Consuming
    /// it is what keeps one gesture to one question.
    private func consumeCloseApproval() -> Bool {
        defer { approvedCloseWindow = nil }
        return approvedCloseWindow != nil
    }

    /// The window IS the app (single-window, no documents), so closing it quits
    /// rather than leaving a windowless process behind — agents running with no
    /// way to see them, and killed without a drain the moment a new window is
    /// created and SwiftUI rebuilds their surface views.
    ///
    /// With the close button intercepted this is a backstop for a window that
    /// closes some other way, not the normal route out.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.openSessions.allSurfaces.isEmpty else {
            // No agents to drain, but a just-retitled session may still be
            // inside the title-coalescing window — drainForQuit (which also
            // flushes) never runs on this path.
            model?.overlay.flushPendingTitles()
            return .terminateNow
        }
        // Quitting ends every agent, and the window's close button quits too —
        // one stray click must not silently bin work in progress. Only agents
        // actually mid-task are worth interrupting for; idle sessions resume
        // from disk with nothing lost.
        //
        // Never ask once the window is already gone: Cancel would have nothing
        // to return the user to, which is the bug this whole path exists to
        // avoid. Better to drain and go than to offer a choice we can't honor.
        // Always ask while work is running unless the close already did. The
        // predicate that used to sit here ("is a window still visible?") skipped
        // the prompt for a minimized or ⌘H-hidden app — states the user can
        // return to perfectly well — and killed the agent without a word.
        let working = model.openSessions.workingTabs.count
        let asked = consumeCloseApproval()
        if working > 0, !asked, hasCancellableWindow(), !confirmQuit(workingCount: working) {
            return .terminateCancel
        }
        model.drainForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(workingCount: Int) -> Bool {
        if let confirmQuitWhileWorking { return confirmQuitWhileWorking(workingCount) }
        let alert = NSAlert()
        alert.messageText = workingCount == 1
            ? "An agent is still working."
            : "\(workingCount) agents are still working."
        alert.informativeText = "Quitting interrupts them. Their sessions reopen next launch, "
            + "but whatever they are doing right now stops here."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Stands in front of SwiftUI's own window delegate to answer one question —
/// "may this window close?" — with "no, quit instead". Everything else is
/// forwarded untouched, so SwiftUI keeps whatever behavior it installed.
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    /// Held strongly: `NSWindow.delegate` is weak, so it may be the only
    /// reference keeping SwiftUI's delegate alive — replacing it must not free it.
    ///
    /// `nonisolated(unsafe)` because conforming to `NSWindowDelegate` infers
    /// `@MainActor` on the class, while the `NSObject` forwarding overrides below
    /// are not isolated. It is a `let`, and AppKit only touches it on the main
    /// thread, so there is nothing to race.
    private nonisolated(unsafe) let forwardee: NSWindowDelegate?
    /// Returns true to let the window close (and so quit), false to do nothing.
    private nonisolated(unsafe) let approveClose: (NSWindow) -> Bool

    init(forwardingTo forwardee: NSWindowDelegate?, approveClose: @escaping (NSWindow) -> Bool) {
        self.forwardee = forwardee
        self.approveClose = approveClose
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Answer here rather than kicking off a termination and letting that ask:
        // NSApp.terminate() from inside this callback re-enters, and one click on
        // the close button produced two prompts. Deciding in place keeps it to one
        // question, asked while the window the user would keep is still on screen.
        approveClose(sender)
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return (forwardee as? NSObject)?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { forwardee }
}
