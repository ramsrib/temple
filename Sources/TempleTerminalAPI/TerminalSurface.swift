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
}

@MainActor
public protocol TerminalSurfaceFactory {
    /// Born with current Settings/theme.
    func makeSurface(appearance: TerminalAppearance) -> TerminalSurface
}
