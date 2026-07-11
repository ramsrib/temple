import SwiftUI

/// Per-session activity state (Item E). Surfaced as an activity dot on the tab
/// chip and — only for sessions with an open tab — the sidebar row.
///
/// The state machine (in `OpenSessionsModel`) keys off observable signals:
/// spawn → `.running`; a bell / OSC notification means the agent stopped working
/// (finished or awaiting input) → `.idle` when you're watching it, else
/// `.needsAttention`; the user pressing Return in the surface → `.running`;
/// process exit → `.exited` / auto-close. A settle fallback decays a booted-but-
/// quiet session to `.idle`.
public enum ActivityState: Sendable, Equatable {
    /// Agent actively working / output flowing (freshly spawned, or the user
    /// just submitted input).
    case running
    /// Open but not working — sitting at its prompt. Shows a neutral dot so an
    /// open tab is still marked as such.
    case idle
    /// Agent finished or is waiting for input while the tab is in the background
    /// (bell / OSC notification).
    case needsAttention
    /// The process exited but the tab was kept so its output stays readable
    /// (early launch failures — see `OpenSessionsModel` exit handling).
    case exited(status: Int32)

    var dotColor: Color {
        switch self {
        case .running: return .green                     // actually working
        case .idle: return Color.secondary.opacity(0.7)  // open, at rest (neutral gray)
        case .needsAttention: return .orange             // wants you
        case .exited: return .red                        // process gone
        }
    }

    /// Every state draws a dot now — `.idle` marks an open-but-resting tab
    /// (distinct from *no* dot, which means the session has no open tab).
    var showsDot: Bool { true }
}
