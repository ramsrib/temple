import SwiftUI
import TempleUI
import TempleCore
import TempleTerminal

/// Thin entry point. All app logic lives in the testable `TempleUI` library.
/// This is the PLAN.md "fuse": the app runs the production libghostty
/// terminal; tests and previews keep using the stub factory.
@main
struct TempleApp: App {
    @NSApplicationDelegateAdaptor(TempleAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var startup: AppStartup

    init() {
        // Un-bundled `swift run` dev path: resources live in the checkout.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Temple
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        // Agents spawned in Temple must see the user's real PATH (agent hooks
        // and tools break under launchd's minimal GUI environment).
        // The usage meter's file trail (ADR-022). Only the app turns it on:
        // tests and tools that reuse the model must never write one. The
        // bundled app's entry point (App/TempleApp.swift) has the same line —
        // see AGENTS.md, "Two entry points".
        _startup = StateObject(wrappedValue: AppStartup { database in
            GhosttyResources.configure(devCheckoutRoot: repoRoot)
            LoginShellEnvironment.adoptLoginShellPATH()
            UsageLog.fileURL = UsageLog.defaultFileURL
            return AppModel(surfaceFactory: GhosttyTerminalSurfaceFactory(), database: database)
        })

        // `swift run temple` / `make demo` launch an un-bundled binary, which
        // AppKit treats as an accessory: no Dock icon, window opens behind
        // everything. Promote it so the dev/demo path behaves like the .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        let action = openWindow
        let _ = appDelegate.openInitialWindow = { action(id: TempleAppDelegate.mainWindowID) }
        WindowGroup("Temple", id: TempleAppDelegate.mainWindowID) {
            if let model = startup.model {
                RootView()
                    .environmentObject(model)
                    .frame(minWidth: 900, minHeight: 600)
                    .task {
                        appDelegate.model = model
                        model.start()
                        // A snapshot run (TEMPLE_SNAPSHOT_DIR) must not take focus:
                        // the hook captures this window alone even when covered,
                        // and an activated demo window caught keystrokes meant for
                        // whatever the user was typing in (it opened a session).
                        if ProcessInfo.processInfo.environment["TEMPLE_SNAPSHOT_DIR"] == nil {
                            NSApplication.shared.activate()
                        }
                    }
            } else {
                StartupFailureView(message: startup.failureMessage ?? "Unable to open Temple.")
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .commands {
            if let model = startup.model { TempleCommands(model: model) }
        }
        .windowStyle(.hiddenTitleBar)
        // Unified toolbar: the tab chips live in the native title-bar band, so
        // the empty band keeps native double-click-to-zoom and window-drag
        // (Item A/B). Full-height (not unifiedCompact — that also shrinks the
        // sidebar header and traffic-light row); the chips grow instead.
        .windowToolbarStyle(.unified)
    }
}
