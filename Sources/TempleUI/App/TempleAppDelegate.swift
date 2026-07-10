import AppKit

/// App-quit lifecycle (ADR-010, U3): drain every live agent process gracefully
/// before the app exits, via a termination delay. Never orphan an agent; never
/// quit mid-write.
@MainActor
public final class TempleAppDelegate: NSObject, NSApplicationDelegate {
    public weak var model: AppModel?

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.openSessions.allSurfaces.isEmpty else { return .terminateNow }
        model.drainForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
