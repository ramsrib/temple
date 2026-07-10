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

@MainActor
final class AppModel: ObservableObject {
    @Published var index = SessionIndex(projects: [])
    @Published var selection: AgentSession.ID?
    @Published var isLoading = true

    var selectedSession: AgentSession? {
        guard let selection else { return nil }
        return index.allSessions.first { $0.id == selection }
    }

    func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let index = SessionIndex.buildDefault()
            await MainActor.run {
                self.index = index
                self.isLoading = false
            }
        }
    }
}
