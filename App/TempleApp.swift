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
    @StateObject private var model: AppModel

    init() {
        // In the bundle, resources resolve to Contents/Resources/ghostty; the
        // dev-checkout fallback covers running the binary straight from
        // DerivedData during development.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repo root
        GhosttyResources.configure(devCheckoutRoot: repoRoot)
        // Agents spawned in Temple must see the user's real PATH (agent hooks
        // and tools break under launchd's minimal GUI environment).
        LoginShellEnvironment.adoptLoginShellPATH()
        _model = StateObject(wrappedValue: AppModel(surfaceFactory: GhosttyTerminalSurfaceFactory()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    appDelegate.model = model
                    model.start()
                }
        }
        .commands { TempleCommands(model: model) }
        .windowStyle(.hiddenTitleBar)
        // Unified toolbar: tab chips + sidebar toggle live in the native
        // title-bar band, keeping native double-click-to-zoom / drag (Item A/B).
        .windowToolbarStyle(.unified)
    }
}
