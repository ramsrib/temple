import SwiftUI

/// Per-session attention state (UX "Notifications & attention"). Surfaced as an
/// activity dot on the tab chip and the sidebar row.
public enum ActivityState: Sendable, Equatable {
    /// Agent working / output flowing (a freshly-spawned surface).
    case running
    /// Nothing happening; no attention needed.
    case idle
    /// Agent finished or is waiting for input (bell / OSC notification).
    case needsAttention
    /// The process exited but the tab was kept so its output stays readable
    /// (early launch failures — see `OpenSessionsModel` exit handling).
    case exited(status: Int32)

    var dotColor: Color {
        switch self {
        case .running: return .green
        case .idle: return .secondary.opacity(0.5)
        case .needsAttention: return .orange
        case .exited: return .red
        }
    }

    /// Whether to draw a dot at all (idle is quiet).
    var showsDot: Bool { self != .idle }
}
