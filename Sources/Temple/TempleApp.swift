import SwiftUI
import TempleCore

@main
struct TempleApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .task { model.load() }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
