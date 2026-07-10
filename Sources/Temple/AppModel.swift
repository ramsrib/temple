import SwiftUI
import TempleCore
import TempleTerminalAPI

@MainActor
final class AppModel: ObservableObject {
    @Published var index = SessionIndex(projects: [])
    @Published var selection: AgentSession.ID?
    @Published var isLoading = true

    /// The terminal implementation — stub until Track T fuses (PLAN.md).
    let surfaceFactory: TerminalSurfaceFactory

    init(surfaceFactory: TerminalSurfaceFactory = StubTerminalSurfaceFactory()) {
        self.surfaceFactory = surfaceFactory
    }

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
