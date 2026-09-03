import AppKit

/// The command a surface spawns in its PTY — e.g. `AgentSession.resume`.
public struct TerminalCommand: Sendable, Equatable {
    public var argv: [String]
    public var cwd: String
    public var env: [String: String]

    public init(argv: [String], cwd: String, env: [String: String] = [:]) {
        self.argv = argv
        self.cwd = cwd
        self.env = env
    }
}

public enum TerminalProcessState: Sendable, Equatable {
    case notStarted
    case running(pid: pid_t)
    case exited(status: Int32)
}

/// Settings (U9) + theme (U10) → surface. System theme resolves to light/dark
/// before it reaches a surface.
public struct TerminalAppearance: Sendable, Equatable {
    public enum ColorScheme: Sendable, Equatable {
        case light, dark
    }

    public var fontSize: Double
    public var fontFamily: String?
    public var colorScheme: ColorScheme

    public init(fontSize: Double = 13, fontFamily: String? = nil, colorScheme: ColorScheme = .dark) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.colorScheme = colorScheme
    }

    public static let `default` = TerminalAppearance()
}

@MainActor
public protocol TerminalSurface: AnyObject {
    /// The render-owning subview (ADR-003).
    var view: NSView { get }
    var delegate: TerminalSurfaceDelegate? { get set }
    var processState: TerminalProcessState { get }

    /// Spawn in the surface's PTY.
    func start(_ command: TerminalCommand) throws
    func focus()
    /// Live: font size + light/dark palette (U9/U10).
    func apply(_ appearance: TerminalAppearance)
    /// Polite: exit sequence / SIGTERM.
    func requestGracefulExit()
    /// Escalation: SIGKILL + reap.
    func terminate()

    // Find in the terminal (⌘F). The surface owns matching and highlighting;
    // the host draws the bar and reports the count.
    /// Search the scrollback for `needle`, replacing any current search. An
    /// empty needle clears the highlights.
    func search(_ needle: String)
    /// Move the selected match; no-op without an active search.
    func navigateSearch(_ direction: TerminalSearchDirection)
    /// Tear the search down (highlights and count go with it).
    func endSearch()
}

public enum TerminalSearchDirection: Sendable, Equatable {
    case next, previous
}

/// Searching is optional: a surface that can't (the stub, test doubles) simply
/// does nothing, and the host's bar shows no count.
public extension TerminalSurface {
    func search(_ needle: String) {}
    func navigateSearch(_ direction: TerminalSearchDirection) {}
    func endSearch() {}
}

@MainActor
public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState)
    func surface(_ surface: TerminalSurface, didUpdateTitle title: String)

    // Attention signals → activity dots + native notifications (UX "Notifications").
    /// Terminal bell.
    func surfaceDidRing(_ surface: TerminalSurface)
    /// OSC 9 / OSC 777.
    func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String)

    /// The user submitted input in the surface (pressed Return with no
    /// modifiers) — a strong signal the agent is now working (Item E). Default
    /// no-op so existing conformers need not implement it.
    func surfaceDidSubmitInput(_ surface: TerminalSurface)

    // Search, as seen from the terminal's side. All default to no-ops.
    /// The terminal itself asked for a search (a keybind inside it, e.g. ⌘E
    /// "use selection for find"); `needle` is what it wants searched, if any.
    func surface(_ surface: TerminalSurface, didStartSearch needle: String?)
    /// The terminal ended the search on its own (Esc in a focused terminal).
    func surfaceDidEndSearch(_ surface: TerminalSurface)
    /// Number of matches for the current needle; `nil` while unknown.
    func surface(_ surface: TerminalSurface, didUpdateSearchTotal total: Int?)
    /// Zero-based index of the highlighted match; `nil` when none is selected.
    func surface(_ surface: TerminalSurface, didUpdateSearchSelected selected: Int?)
}

public extension TerminalSurfaceDelegate {
    func surfaceDidSubmitInput(_ surface: TerminalSurface) {}
    func surface(_ surface: TerminalSurface, didStartSearch needle: String?) {}
    func surfaceDidEndSearch(_ surface: TerminalSurface) {}
    func surface(_ surface: TerminalSurface, didUpdateSearchTotal total: Int?) {}
    func surface(_ surface: TerminalSurface, didUpdateSearchSelected selected: Int?) {}
}

@MainActor
public protocol TerminalSurfaceFactory {
    /// Born with current Settings/theme.
    func makeSurface(appearance: TerminalAppearance) -> TerminalSurface
}
