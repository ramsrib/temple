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

    /// Overridable in tests: is there still a window the user would be returned
    /// to if they cancelled?
    var hasCancellableWindow: () -> Bool = {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    /// Retains the close interceptors (`NSWindow.delegate` is weak), one per window.
    private var closeInterceptors: [ObjectIdentifier: WindowCloseInterceptor] = [:]

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Temple has its own tab system; macOS window tabbing would stack
        // whole windows in a second tab bar under the chip strip. Opting out
        // also removes View's confusing "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-checked every time a window becomes main rather than installed once:
        // SwiftUI owns the delegate and may re-seat it, and a latch that lost the
        // race would silently restore the close-then-ask behavior below.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                self.interceptClose(of: window)
            }
        }
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
        let interceptor = WindowCloseInterceptor(forwardingTo: window.delegate) { [weak self] in
            self?.approveCloseForQuit() ?? true
        }
        window.delegate = interceptor
        closeInterceptors[ObjectIdentifier(window)] = interceptor
    }

    /// Answered while the window is still on screen, so "no" is simply
    /// "nothing happened". A "yes" lets the window close, which starts the quit
    /// via `applicationShouldTerminateAfterLastWindowClosed` — and is remembered
    /// so the drain below does not ask the same question a second time.
    func approveCloseForQuit() -> Bool {
        guard let model else { return true }
        let working = model.openSessions.workingTabs.count
        guard working > 0 else { return true }
        guard confirmQuit(workingCount: working) else { return false }
        quitAlreadyConfirmed = true
        return true
    }

    /// Set when the close button already asked. Consumed by the next
    /// termination so the user is not asked twice for one gesture.
    private var quitAlreadyConfirmed = false

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
        let working = model.openSessions.workingTabs.count
        let asked = quitAlreadyConfirmed
        quitAlreadyConfirmed = false
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
    private nonisolated(unsafe) let approveClose: () -> Bool

    init(forwardingTo forwardee: NSWindowDelegate?, approveClose: @escaping () -> Bool) {
        self.forwardee = forwardee
        self.approveClose = approveClose
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Answer here rather than kicking off a termination and letting that ask:
        // NSApp.terminate() from inside this callback re-enters, and one click on
        // the close button produced two prompts. Deciding in place keeps it to one
        // question, asked while the window the user would keep is still on screen.
        approveClose()
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return (forwardee as? NSObject)?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { forwardee }
}
