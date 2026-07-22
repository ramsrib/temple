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
    @StateObject private var model: AppModel

    init() {
        // Un-bundled `swift run` dev path: resources live in the checkout.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Temple
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        GhosttyResources.configure(devCheckoutRoot: repoRoot)
        // Agents spawned in Temple must see the user's real PATH (agent hooks
        // and tools break under launchd's minimal GUI environment).
        LoginShellEnvironment.adoptLoginShellPATH()
        _model = StateObject(wrappedValue: AppModel(surfaceFactory: GhosttyTerminalSurfaceFactory()))

        // `swift run temple` / `make demo` launch an un-bundled binary, which
        // AppKit treats as an accessory: no Dock icon, window opens behind
        // everything. Promote it so the dev/demo path behaves like the .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    appDelegate.model = model
                    model.start()
                    NSApplication.shared.activate()
                }
        }
        .commands { TempleCommands(model: model) }
        .windowStyle(.hiddenTitleBar)
        // Unified toolbar: the tab chips live in the native title-bar band, so
        // the empty band keeps native double-click-to-zoom and window-drag
        // (Item A/B). Full-height (not unifiedCompact — that also shrinks the
        // sidebar header and traffic-light row); the chips grow instead.
        .windowToolbarStyle(.unified)
    }
}
