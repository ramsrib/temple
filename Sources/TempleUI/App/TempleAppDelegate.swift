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

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Temple has its own tab system; macOS window tabbing would stack
        // whole windows in a second tab bar under the chip strip. Opting out
        // also removes View's confusing "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The window IS the app (single-window, no documents), so closing it quits
    /// rather than leaving a windowless process behind.
    ///
    /// Keeping the app alive was worse than it looks: the agents keep running
    /// with no way to see them, and the moment a new window is created SwiftUI
    /// rebuilds `RootView` — which recreates the terminal surface views, drops
    /// the old ones, and kills every agent attached to them, skipping the
    /// graceful drain below entirely. Routing the red button through the normal
    /// quit path means the agents are drained properly and the tab set is saved,
    /// so relaunching puts the session back (`OpenSessionsModel.restore`).
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
        // Quitting ends every agent, and now the window's close button quits
        // too — one stray click must not silently bin work in progress. Only
        // agents actually mid-task are worth interrupting for; idle sessions
        // resume from disk with nothing lost.
        let working = model.openSessions.workingTabs.count
        if working > 0, !confirmQuit(workingCount: working) {
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
