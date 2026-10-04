import SwiftUI
import TempleCore
import TempleTerminalAPI

/// What a tab represents. Session tabs run an agent process (ADR-010); the
/// Settings and History tabs are the deliberate project-agnostic, process-less
/// exceptions ("utility" tabs): singletons, never persisted, shown in every
/// project's strip.
public enum TabKind: Hashable {
    case session
    case settings
    case history

    /// The chip's fixed title and symbol for a utility tab; nil for sessions.
    var utilityTitle: String? {
        switch self {
        case .session: nil
        case .settings: "Settings"
        case .history: "History"
        }
    }

    var utilitySymbol: String? {
        switch self {
        case .session: nil
        case .settings: "gearshape"
        case .history: "clock.arrow.circlepath"
        }
    }
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
    @Published public private(set) var agent: Agent
    @Published public private(set) var host: HostID
    public var projectKey: ProjectKey { ProjectKey(host: host, path: projectPath) }
    /// Fixed by the session's `cwd`; drives per-project tab-bar scoping (U2).
    @Published public private(set) var projectPath: String
    @Published public var title: String
    @Published public var activity: ActivityState = .idle

    /// Was the *command* a suspect when this tab died? Frozen at the moment of
    /// death, because the tab shows the argv it launched with — and Settings can
    /// change afterwards. Judging a past failure by present settings makes an old
    /// tab's verdict flip when the user edits an unrelated field: fix your arguments
    /// and a bad-argv failure quietly loses its explanation; break them and a healthy
    /// failure suddenly gets blamed for something that hadn't happened yet.
    @Published public var commandWasSuspect = false
    /// A launcher can fail before there is a terminal to display its error.
    @Published public var launchPreparationError: String?
    /// Did this tab die resuming a session id that no transcript on disk
    /// carries? Claude rotates ids INSIDE a live process (/resume continues an
    /// older conversation under its own id; /clear starts a fresh one), so the
    /// id a tab booted with can end the day owning no conversation at all —
    /// and the resume that fails is Temple's, built from its persisted id.
    /// Frozen at death, same reasoning as `commandWasSuspect`.
    @Published public var resumeTargetMissing = false
    /// Was the row already confirmed transcript-less when this tab spawned?
    /// Then the failure is no mystery: the file is gone, and the header says
    /// so instead of offering /resume or /clear as the likely story. Frozen
    /// at spawn, like the verdicts above.
    @Published public var resumeTargetAbsentAtLaunch = false
    /// The header's line for a resume no transcript carries, split by what
    /// Temple knew before it launched.
    public var resumeTargetMissingMessage: String? {
        guard resumeTargetMissing else { return nil }
        if resumeTargetAbsentAtLaunch {
            let resumer = agent == .claude ? "Claude" : agent.displayName
            return "This session's transcript is no longer on disk, so \(resumer) has nothing to resume. "
                + "Archive it, or import a newer file from History."
        }
        return "No transcript on disk carries this ID. It was deleted or pruned, or the conversation continued "
            + "under a new ID after /resume or /clear — check the sidebar."
    }
    /// The header offers Archive: the row is provably transcript-less.
    public var offersArchiveForMissingTranscript: Bool {
        resumeTargetMissing && resumeTargetAbsentAtLaunch && sessionID != nil
    }
    @Published public var missingWorkingDirectory: String?
    public var missingWorkingDirectoryMessage: String? {
        missingWorkingDirectory.map { "The folder \($0) no longer exists." }
    }
    @Published public var isProvisional: Bool
    /// The user has sent this tab's agent something (Return). A new tab
    /// closed before that started no conversation.
    var inputSubmitted = false
    /// A tab that started a new session and closed before anything was sent.
    var startedNothing: Bool { kind == .session && !isResume && !inputSubmitted && sessionID != nil }

    /// The command the surface spawned; set at spawn, nil before (and for a
    /// utility tab).
    public private(set) var command: TerminalCommand?
    /// The agent's own argv for that spawn: what a failure header shows,
    /// never a launcher's wrapper around it.
    public private(set) var displayArgv: [String]?
    /// What the current launch reports (the folder it entered, or why it
    /// stopped before the agent ran). Owned by this tab: finished on exit,
    /// cancelled on close.
    var launchResult: LaunchResultChannel?
    /// The launcher said the agent never started, and why. Shown regardless
    /// of how long the process lived.
    @Published public var launchFailure: LaunchFailure?

    /// Live terminal; `nil` for an inert restored chip or a utility tab.
    @Published public private(set) var surface: TerminalSurface?

    /// Find-in-terminal (⌘F) state, kept with the tab so a search survives a
    /// tab switch. Wired to the surface on attach.
    public let find = TerminalFindModel()

    /// Retains the per-tab delegate so the surface's `weak delegate` stays alive.
    var coordinator: AnyObject?
    /// Optional join hint, consumed at spawn; it never supplies launch facts.
    var transcriptHint: TranscriptLocator?

    /// Was this tab spawned to RESUME an existing conversation (sidebar open,
    /// relaunch restore) rather than to start a fresh one? Only a resume can
    /// meaningfully fail with "that session id owns no transcript" — a new
    /// tab's freshly minted id is legitimately unknown to the index, and
    /// blaming its unrelated early exit on id rotation would mislead.
    public let isResume: Bool

    public init(kind: TabKind,
                sessionID: String?,
                agent: Agent,
                projectPath: String,
                title: String,
                isProvisional: Bool = false,
                isResume: Bool = false,
                host: HostID = .local) {
        self.kind = kind
        self.sessionID = sessionID
        self.agent = agent
        self.host = host
        self.projectPath = projectPath
        self.title = title
        self.isProvisional = isProvisional
        self.isResume = isResume
    }

    /// What this spawn runs. Once a surface exists, its launch identity stays fixed.
    func setLaunch(_ launch: AgentLaunch) {
        command = launch.command
        displayArgv = launch.displayArgv
        launchResult?.cancel()
        launchResult = launch.result
        launchFailure = nil
    }

    func prepareResume(_ session: Session) {
        guard let agent = session.agent, let directory = session.directory else { return }
        prepareResume(session, agent: agent, directory: directory)
    }

    /// An inert resume chip takes the latest row before its first spawn.
    func prepareResume(_ session: Session, agent: Agent, directory: String) {
        guard surface == nil, isResume else { return }
        self.agent = agent
        self.host = session.host
        self.projectPath = directory
        self.title = session.state.customName ?? session.state.title ?? self.title
    }

    public var isUtility: Bool { kind != .session }
    public var hasSurface: Bool { surface != nil }

    /// When the surface's process was spawned; drives the early-exit grace
    /// window (a process dying right after launch keeps its tab so the error
    /// output stays readable).
    public private(set) var spawnedAt: Date?

    struct LaunchObservation {
        let at: Date
        /// Set only when the launch reported the folder it entered.
        var directory: String?
    }
    /// Retained only after start succeeds; adoption can arrive much later.
    var launchObservation: LaunchObservation?

    func attach(surface: TerminalSurface, at: Date = Date()) {
        self.surface = surface
        self.spawnedAt = at
        find.surface = surface
    }
}

/// A launch that stopped before the agent ran, as its launcher reported it.
public struct LaunchFailure: Equatable, Sendable {
    public let category: LaunchFailureCategory
    public let message: String
}
