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
        .windowStyle(.hiddenTitleBar)
        // Unified toolbar: the tab chips live as toolbar items in the native
        // title-bar band, so the empty band keeps native double-click-to-zoom
        // and window-drag (Item A/B).
        .windowToolbarStyle(.unified)
    }
}
