import SwiftUI
import TempleUI

/// Xcode app-target entry point (U6).
///
/// Mirrors the SwiftPM `Temple` executable's thin `@main` (Sources/Temple/
/// TempleApp.swift) — all app logic lives in the testable `TempleUI` library.
/// This duplicate exists only so the `.app` bundle has an entry point the Xcode
/// target compiles; it links the `TempleUI` product rather than the SwiftPM
/// executable (executables can't be linked into an app target). The terminal is
/// stubbed until Track T swaps the factory (one line, inside TempleUI).
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
