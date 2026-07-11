import AppKit
import Foundation
import GhosttyKit
import TempleTerminalAPI

/// Production `TerminalSurface` backed by libghostty (ADR-003).
///
/// Adapts `GhosttySurfaceView` + the `GhosttyApp` runtime to the
/// `TempleTerminalAPI` protocol. This is the fuse: swapping
/// `StubTerminalSurfaceFactory` for `GhosttyTerminalSurfaceFactory` in the app is
/// a one-line change (see `GhosttyTerminalSurfaceFactory`).
@MainActor
public final class GhosttyTerminalSurface: TerminalSurface {
    private let ghosttyView: GhosttySurfaceView
    private var appearance: TerminalAppearance

    public var view: NSView { ghosttyView }
    public weak var delegate: TerminalSurfaceDelegate?

    public private(set) var processState: TerminalProcessState = .notStarted {
        didSet {
            guard processState != oldValue else { return }
            delegate?.surface(self, didChangeState: processState)
        }
    }

    public init(app: GhosttyApp? = nil, appearance: TerminalAppearance = .default) {
        self.appearance = appearance
        self.ghosttyView = GhosttySurfaceView(app: app ?? .shared, appearance: appearance)
        wireCallbacks()
    }

    private func wireCallbacks() {
        ghosttyView.onTitle = { [weak self] title in
            guard let self else { return }
            self.delegate?.surface(self, didUpdateTitle: title)
        }
        ghosttyView.onBell = { [weak self] in
            guard let self else { return }
            self.delegate?.surfaceDidRing(self)
        }
        ghosttyView.onNotification = { [weak self] title, body in
            guard let self else { return }
            self.delegate?.surface(self, didPostNotification: title, body: body)
        }
        ghosttyView.onSubmitInput = { [weak self] in
            guard let self else { return }
            self.delegate?.surfaceDidSubmitInput(self)
        }
        ghosttyView.onChildExited = { [weak self] code in
            self?.markExited(status: code)
        }
        ghosttyView.onCloseRequest = { [weak self] _ in
            // libghostty wants the surface closed (process gone, or an in-terminal
            // close). A Temple session tab is 1:1 with a live agent (ADR-010), so
            // either way the surface's lifecycle is over: report exit.
            self?.markExited(status: 0)
        }
    }

    private func markExited(status: Int32) {
        if case .exited = processState { return }
        processState = .exited(status: status)
    }

    // MARK: TerminalSurface

    public func start(_ command: TerminalCommand) throws {
        guard case .notStarted = processState else { return }
        let commandLine = Self.shellCommand(from: command.argv)
        try ghosttyView.startSurface(
            command: commandLine,
            workingDirectory: command.cwd.isEmpty ? nil : command.cwd,
            env: command.env)
        // libghostty owns the PTY and does not expose the child pid, so we report
        // a placeholder pid. Exit is detected via the child-exit / close callbacks.
        processState = .running(pid: 0)
    }

    public func focus() {
        guard let window = ghosttyView.window else {
            // Not yet in a window; focus once it is.
            return
        }
        window.makeFirstResponder(ghosttyView)
    }

    public func apply(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        // Runtime-wide config (font size/family, theme pair) + per-surface
        // light/dark resolution. Idempotent across surfaces.
        GhosttyApp.shared.update(appearance: appearance)
        ghosttyView.apply(appearance)
    }

    /// Polite exit: ask libghostty to close the surface, which closes the PTY and
    /// signals the child (SIGHUP) so it can flush its session file and exit
    /// (ADR-010). libghostty's C API does not expose the child pid, so a direct
    /// SIGTERM is not available; PTY close is the graceful equivalent.
    public func requestGracefulExit() {
        guard case .running = processState, let surface = ghosttyView.surface else { return }
        ghostty_surface_request_close(surface)
    }

    /// Escalation: tear the surface down immediately. Freeing the surface closes
    /// the PTY and reaps the child. (True SIGKILL-by-pid is not exposed by
    /// libghostty; surface teardown is the forceful path.)
    public func terminate() {
        ghosttyView.closeSurface()
        if case .running = processState {
            processState = .exited(status: SIGKILL)
        } else if case .notStarted = processState {
            processState = .exited(status: SIGKILL)
        }
    }

    /// Build a shell command line from argv, quoting each element so paths with
    /// spaces and other metacharacters survive libghostty's shell parsing.
    nonisolated static func shellCommand(from argv: [String]) -> String? {
        ShellQuoting.commandLine(argv)
    }
}

/// Drop-in `TerminalSurfaceFactory` for the fuse. See `GhosttyTerminalSurface`.
public struct GhosttyTerminalSurfaceFactory: TerminalSurfaceFactory {
    public init() {}
    public func makeSurface(appearance: TerminalAppearance) -> TerminalSurface {
        // Seed the runtime config before the first `GhosttyApp.shared` access
        // so the first surface is born matching the app theme.
        GhosttyApp.initialAppearance = appearance
        return GhosttyTerminalSurface(appearance: appearance)
    }
}
