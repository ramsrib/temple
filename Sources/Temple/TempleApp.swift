import SwiftUI
import TempleUI

/// Thin entry point. All app logic lives in the testable `TempleUI` library.
/// The terminal is stubbed until Track T swaps the factory (one line).
@main
struct TempleApp: App {
    @NSApplicationDelegateAdaptor(TempleAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

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
    }
}
