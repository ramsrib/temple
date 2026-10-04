import SwiftUI
import TempleUI
import TempleCore
import TempleTerminal

/// Xcode app-target entry point (U6).
///
/// Mirrors the SwiftPM `Temple` executable's thin `@main` (Sources/Temple/
/// TempleApp.swift) — all app logic lives in the testable `TempleUI` library.
/// This duplicate exists only so the `.app` bundle has an entry point the Xcode
/// target compiles; it links the `TempleUI` + `TempleTerminal` products rather
/// than the SwiftPM executable (executables can't be linked into an app target).
/// Runs the production libghostty terminal (the PLAN.md "fuse").
@main
struct TempleApp: App {
    @NSApplicationDelegateAdaptor(TempleAppDelegate.self) private var appDelegate
    @StateObject private var startup: AppStartup

    init() {
        // In the bundle, resources resolve to Contents/Resources/ghostty; the
        // dev-checkout fallback covers running the binary straight from
        // DerivedData during development.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repo root
        // Agents spawned in Temple must see the user's real PATH (agent hooks
        // and tools break under launchd's minimal GUI environment).
        // The usage meter's file trail (ADR-022). Only the app turns it on:
        // tests and tools that reuse the model must never write one. The
        // SwiftPM entry point (Sources/Temple/TempleApp.swift) has the same
        // line — see AGENTS.md, "Two entry points".
        _startup = StateObject(wrappedValue: AppStartup { database in
            GhosttyResources.configure(devCheckoutRoot: repoRoot)
            LoginShellEnvironment.adoptLoginShellPATH()
            UsageLog.fileURL = UsageLog.defaultFileURL
            return AppModel(surfaceFactory: GhosttyTerminalSurfaceFactory(), database: database)
        })
    }

    var body: some Scene {
        // A stable id keys the saved window frame and sidebar width. Without
        // one, SwiftUI keys them on the content's Swift type name, so any
        // change to the root view's type resets both for every user.
        WindowGroup(id: "main") {
            StartupRootView(startup: startup, appDelegate: appDelegate)
        }
        .commands { StartupCommands(startup: startup) }
        // The window takes its size limits from the content: RootView's
        // 900×600 minimum, or a startup-failure window's fixed size. (The
        // default only honours the minimum, so a failure window opened at the
        // last saved full-size frame.) The other entry point has the same line.
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        // Unified toolbar: tab chips + sidebar toggle live in the native
        // title-bar band, keeping native double-click-to-zoom / drag (Item A/B).
        .windowToolbarStyle(.unified)
    }
}
