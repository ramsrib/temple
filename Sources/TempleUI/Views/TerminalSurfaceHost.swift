import SwiftUI
import TempleTerminalAPI

/// Hosts a `TerminalSurface`'s NSView in SwiftUI. The surface is already spawned
/// by `OpenSessionsModel` (lazy, on activation); this view only mounts it.
struct TerminalSurfaceHost: NSViewRepresentable {
    let surface: TerminalSurface

    func makeNSView(context: Context) -> NSView {
        surface.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
