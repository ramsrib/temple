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
            guard let surface else { return }
            if Self.isRunning(surface) {
                TempleUILog.lifecycle.error("graceful close timed out after \(timeout)s, escalating to terminate()")
                surface.terminate()
            } else {
                TempleUILog.lifecycle.debug("graceful close completed within \(timeout)s")
            }
        }
    }

    /// App-quit drain (ADR-010): gracefully end every live surface, wait, force
    /// the stragglers, then call `completion` (wire to `.terminateLater`).
    public func drainAll(_ surfaces: [TerminalSurface], completion: @escaping () -> Void) {
        drainAll(graceful: surfaces, detach: [], remote: nil, completion: completion)
    }

    /// The quit's one bounded window (docs/designs/remote-ssh.md section 5):
    ///
    /// - `graceful` (this Mac's agents): the exit request, then `terminate()`
    ///   for whatever is still running at the deadline;
    /// - `detach` (working agents on hosts): `terminate()` at once, with no
    ///   exit input, which would reach the agent through tmux; it keeps
    ///   working there;
    /// - `remote`: the stops it owns (an idle agent's, and any a close
    ///   started) run in parallel inside the same window; those still
    ///   outstanding at the deadline are expired, each recording why.
    ///
    /// `completion` comes when everything has finished or at the deadline,
    /// and always asynchronously, after `.terminateLater` has been returned.
    public func drainAll(graceful surfaces: [TerminalSurface], detach: [TerminalSurface],
                         remote: RemoteOperations?, completion: @escaping () -> Void) {
        for surface in detach where Self.isRunning(surface) { surface.terminate() }
        let running = surfaces.filter(Self.isRunning)
        guard !running.isEmpty || (remote?.stopsOutstanding ?? 0) > 0 else {
            // NEVER synchronously: the caller wires this to
            // `reply(toApplicationShouldTerminate:)`, which AppKit requires to
            // come *after* `.terminateLater` has been returned. Replying first
            // left the app deferred with no reply ever coming — unquittable,
            // window open, ⌘Q and the close button both inert. Reachable with a
            // tab whose agent had already exited.
            DispatchQueue.main.async { completion() }
            return
        }
        for surface in running { surface.requestGracefulExit() }
        let timeout = gracefulTimeout
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !running.contains(where: Self.isRunning), (remote?.stopsOutstanding ?? 0) == 0 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            for surface in running where Self.isRunning(surface) { surface.terminate() }
            remote?.expireStops()
            completion()
        }
    }
}
