import AppKit

/// App-quit lifecycle (ADR-010, U3): drain every live agent process gracefully
/// before the app exits, via a termination delay. Never orphan an agent; never
/// quit mid-write.
@MainActor
public final class TempleAppDelegate: NSObject, NSApplicationDelegate {
    public weak var model: AppModel?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Temple has its own tab system; macOS window tabbing would stack
        // whole windows in a second tab bar under the chip strip. Opting out
        // also removes View's confusing "Show Tab Bar"/"Show All Tabs" items.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.openSessions.allSurfaces.isEmpty else {
            // No agents to drain, but a just-retitled session may still be
            // inside the title-coalescing window — drainForQuit (which also
            // flushes) never runs on this path.
            model?.overlay.flushPendingTitles()
            return .terminateNow
        }
        model.drainForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
