import SwiftUI
import TempleCore
import TempleTerminalAPI

/// What a tab represents. Session tabs run an agent process (ADR-010); the
/// Settings tab is the deliberate project-agnostic, process-less exception.
public enum TabKind: Equatable {
    case session
    case settings
}

/// One open tab = one open terminal (UX "A tab is its agent process").
///
/// A tab may exist as an **inert chip** (lazy restore, U2): `surface == nil`
/// until the user clicks it, at which point `OpenSessionsModel` spawns the
/// surface. Codex tabs may be **provisional** (`sessionID == nil`) until the
/// reconciler adopts the real id (U4).
@MainActor
public final class SessionTab: ObservableObject, Identifiable {
    public let id = UUID()
    public let kind: TabKind

    /// The CLI session id. `nil` while a Codex session is provisional (U4).
    @Published public var sessionID: String?
    public let agent: Agent
    /// Fixed by the session's `cwd`; drives per-project tab-bar scoping (U2).
    public let projectPath: String
    @Published public var title: String
    @Published public var activity: ActivityState = .idle

    /// Was the *command* a suspect when this tab died? Frozen at the moment of
    /// death, because the tab shows the argv it launched with — and Settings can
    /// change afterwards. Judging a past failure by present settings makes an old
    /// tab's verdict flip when the user edits an unrelated field: fix your arguments
    /// and a bad-argv failure quietly loses its explanation; break them and a healthy
    /// failure suddenly gets blamed for something that hadn't happened yet.
    @Published public var commandWasSuspect = false
    /// Did this tab die resuming a session id that no transcript on disk
    /// carries? Claude rotates ids INSIDE a live process (/resume continues an
    /// older conversation under its own id; /clear starts a fresh one), so the
    /// id a tab booted with can end the day owning no conversation at all —
    /// and the resume that fails is Temple's, built from its persisted id.
    /// Frozen at death, same reasoning as `commandWasSuspect`.
    @Published public var resumeTargetMissing = false
    @Published public var isProvisional: Bool

    /// The command the surface spawns. `nil` for the Settings tab.
    public let command: TerminalCommand?

    /// Live terminal; `nil` for an inert restored chip or the Settings tab.
    @Published public private(set) var surface: TerminalSurface?

    /// Retains the per-tab delegate so the surface's `weak delegate` stays alive.
    var coordinator: AnyObject?

    public init(kind: TabKind,
                sessionID: String?,
                agent: Agent,
                projectPath: String,
                title: String,
                command: TerminalCommand?,
                isProvisional: Bool = false) {
        self.kind = kind
        self.sessionID = sessionID
        self.agent = agent
        self.projectPath = projectPath
        self.title = title
        self.command = command
        self.isProvisional = isProvisional
    }

    public var isUtility: Bool { kind != .session }
    public var hasSurface: Bool { surface != nil }

    /// When the surface's process was spawned; drives the early-exit grace
    /// window (a process dying right after launch keeps its tab so the error
    /// output stays readable).
    public private(set) var spawnedAt: Date?

    func attach(surface: TerminalSurface) {
        self.surface = surface
        self.spawnedAt = Date()
    }
}
