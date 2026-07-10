import Foundation
import TempleTerminalAPI

/// Owns the graceful lifecycle of agent processes (ADR-010, U3).
///
/// Written entirely against `TerminalSurface`, so it is exercised by
/// `FakeTerminalSurface` in tests (graceful / slow / hung exits) and by the
/// ghostty surface after the fuse. Tab removal itself is the delegate's job
/// (`.exited` → `OpenSessionsModel.autoClose`); this type only drives the
/// *close* direction: polite exit, bounded wait, force-kill stragglers.
@MainActor
public final class SessionRuntimeController {
    private let gracefulTimeout: TimeInterval

    public init(gracefulTimeout: TimeInterval = 3.0) {
        self.gracefulTimeout = gracefulTimeout
    }

    private static func isRunning(_ surface: TerminalSurface) -> Bool {
        if case .running = surface.processState { return true }
        return false
    }

    /// Close one surface: `requestGracefulExit()`, wait up to the timeout, then
    /// `terminate()` if it is still alive. The eventual `.exited` delegate
    /// callback is what removes the tab.
    public func close(_ surface: TerminalSurface) {
        guard Self.isRunning(surface) else { return }
        surface.requestGracefulExit()
        let timeout = gracefulTimeout
        Task { [weak surface] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let surface, Self.isRunning(surface) else { return }
            surface.terminate()
        }
    }

    /// App-quit drain (ADR-010): gracefully end every live surface, wait, force
    /// the stragglers, then call `completion` (wire to `.terminateLater`).
    public func drainAll(_ surfaces: [TerminalSurface], completion: @escaping () -> Void) {
        let running = surfaces.filter(Self.isRunning)
        guard !running.isEmpty else { completion(); return }
        for surface in running { surface.requestGracefulExit() }
        let timeout = gracefulTimeout
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            for surface in running where Self.isRunning(surface) { surface.terminate() }
            completion()
        }
    }
}
