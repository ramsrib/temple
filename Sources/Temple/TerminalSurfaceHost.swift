import SwiftUI
import TempleCore
import TempleTerminalAPI

/// Hosts a `TerminalSurface`'s NSView in SwiftUI and starts its command once.
/// Give it a stable SwiftUI identity (`.id(...)`) per session.
struct TerminalSurfaceHost: NSViewRepresentable {
    let surface: TerminalSurface
    let command: TerminalCommand

    func makeNSView(context: Context) -> NSView {
        if case .notStarted = surface.processState {
            try? surface.start(command)
        }
        return surface.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension TerminalCommand {
    init(resuming session: AgentSession) {
        self.init(argv: session.resume.argv, cwd: session.resume.cwd)
    }
}
