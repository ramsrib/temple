import Foundation
import TempleCore
import TempleTerminalAPI

// The app's view of a host whose agents run under a keep-alive there
// (docs/designs/remote-ssh.md sections 3 to 5). `TempleUI` names no type
// of `TempleRemoteHost` outside `Hosts/RemoteHost.swift`; the launcher
// there conforms to this protocol, so `RemoteTabController` drives a remote
// tab's open, exit, close and quit through it and nothing else.

/// Why a session on a host was left running (mirrors the run row).
public enum RemoteLeftRunningReason: String, Sendable, Equatable {
    case hostDidNotAnswer = "host did not answer"
    case stopNotAcknowledged = "stop not acknowledged"
    case anotherClientAttached = "another client attached"
    case quitDeadline = "quit deadline"
    /// Its tab was connected when Temple quit: a quit leaves every agent on
    /// a host running. Said once, at the next launch ("from before you
    /// quit"), and never as a left-running line in Running sessions.
    case detachedAtQuit = "detached at quit"
}

/// What an Open decided: the command for the tab, and the run it serves.
public struct RemoteOpenPlan: Equatable {
    public let handle: String
    public let attachment: Int
    /// A creation (`new-session`), rather than an attach.
    public let creating: Bool
    public let command: TerminalCommand
    /// The agent's own argv, for a failure header (never the wrapper).
    public let displayArgv: [String]
    /// An attach to a run whose creation evidence is persisted: its folder,
    /// replayed into the row and tab (`applyLaunchDirectory`).
    public let evidenceDirectory: String?
    /// The staged launch the tab's command waits for, when it could not be
    /// staged before the spawn (no master yet): staged once the tab's own
    /// ssh has authenticated (`RemoteSessionHost.stage`). Nil when it is
    /// already in place.
    public let stage: String?
    public init(handle: String, attachment: Int, creating: Bool, command: TerminalCommand, displayArgv: [String],
                evidenceDirectory: String? = nil, stage: String? = nil) {
        self.handle = handle; self.attachment = attachment; self.creating = creating
        self.command = command; self.displayArgv = displayArgv; self.evidenceDirectory = evidenceDirectory
        self.stage = stage
    }
}

/// What staging a connecting tab's launch came to.
public enum RemoteStageResult: Equatable {
    case staged
    /// Nothing was put in place, so nothing ran (a creation is recorded as
    /// failed); why.
    case failed(String)
    /// No answer; the tab's own exit decides.
    case unknown(String)
    /// Refused (nothing in place), but the creation's failure could not be
    /// written; the tab's end records it. Why.
    case unrecorded(String)
    /// Nothing to stage.
    case none
}

public enum RemoteOpenResult: Equatable {
    case plan(RemoteOpenPlan)
    /// The session was stopped with its conversation unconfirmed and no
    /// transcript found for it (`checked`), or none Temple could check: the
    /// tab offers Start a new session and Discard (and Resume, unchecked).
    case needsDecision(checked: Bool)
}

/// What a creation's records said, once persisted.
public enum RemoteLaunchOutcome: Equatable {
    case ok(directory: String)
    case failedCD(directory: String)
    /// No agent ran (the launch couldn't be prepared, or the pane wasn't
    /// told its config root); why.
    case failedLaunch(String)
    case clientFailed(String)
    case nothing
    case transport(String)
    /// The host's answer could not be written here; nothing follows from it.
    case storage(String)
}

/// The liveness contract's three answers.
public enum RemoteLiveness: Equatable {
    case present
    /// Positively absent: the run is Ended (written by the host side).
    case absent
    case unknown(reason: String)
}

/// One decoded stop, as the app needs it.
public enum RemoteStopResult: Equatable {
    /// Killed, or found already gone: the run is Ended.
    case stopped
    /// Left running, with the reason; `detail` is what failed (ssh's or
    /// tmux's words) when there is one.
    case leftRunning(RemoteLeftRunningReason, detail: String?)
    /// The outcome could not be written; `detail` says why.
    case unrecorded(detail: String)
}

/// What opening (or starting) a new Codex session on a host decided: its
/// id is Codex's to mint, so the run starts pending (phase 1b).
public enum RemotePendingOpenResult: Equatable {
    case plan(RemoteOpenPlan)
    /// The run ended before Temple learned its id.
    case ended
    /// The run has an id now (another Temple learned it): that session,
    /// and the folder its pane ran in.
    case identified(String, directory: String?)
}

/// One identity check (or a confirmed suggestion), as the app needs it.
public enum RemoteIdentity: Equatable {
    /// Claimed for the run (verified by its process tree, or the user's
    /// yes): the id, and the folder its pane ran in.
    case adopted(String, directory: String?)
    /// The run already has this id.
    case known(String, directory: String?)
    /// Another session started from Temple on this host holds that id.
    case taken
    /// Nothing proven. `lasting`: it never will be for this run (no
    /// `/proc`, a shared Codex server writes the transcript); `ended`: its
    /// process is gone. Either way the suggestions take over.
    case inconclusive(String, lasting: Bool, ended: Bool)
    /// The claim could not be written: nothing adopted.
    case storage(String)
}

/// A rollout that may be a pending run's session, offered as a question.
/// Identified and compared by the path's bytes: two spellings the host
/// keeps apart (precomposed and decomposed) are two suggestions, though
/// Swift calls the strings equal.
public struct RemoteSuggestion: Equatable, Identifiable {
    public var id: [UInt8] { Array(rolloutPath.utf8) }
    public let rolloutPath: String
    public let sessionID: String
    public let firstPrompt: String?
    public let startedAt: Date
    public let directory: String
    /// False when the prompt could not be read: shown as unknown, never
    /// as "no prompt".
    public let promptKnown: Bool
    /// How far the host's clock was ahead of this Mac's when the lookup
    /// asked (negative: behind); nil when unknown. Display only.
    public let hostClockOffset: TimeInterval?
    public init(rolloutPath: String, sessionID: String, firstPrompt: String?, startedAt: Date, directory: String,
                promptKnown: Bool = true, hostClockOffset: TimeInterval? = nil) {
        self.rolloutPath = rolloutPath; self.sessionID = sessionID; self.firstPrompt = firstPrompt
        self.startedAt = startedAt; self.directory = directory; self.promptKnown = promptKnown
        self.hostClockOffset = hostClockOffset
    }

    public static func == (lhs: RemoteSuggestion, rhs: RemoteSuggestion) -> Bool {
        lhs.id == rhs.id && Array(lhs.sessionID.utf8) == Array(rhs.sessionID.utf8)
            && lhs.firstPrompt == rhs.firstPrompt && lhs.startedAt == rhs.startedAt
            && Array(lhs.directory.utf8) == Array(rhs.directory.utf8) && lhs.promptKnown == rhs.promptKnown
    }
}

public enum RemoteSuggestions: Equatable {
    case candidates([RemoteSuggestion])
    case unavailable(String)
}

/// A pending Codex run restored as a chip at launch.
public struct RemotePendingRun: Equatable {
    public let handle: String
    /// Its folder: the pane's, or the one asked for.
    public let directory: String
    public let ended: Bool
    /// Its id, for a run claimed after its tab set was saved.
    public let sessionID: String?
    /// Something was typed into its tab (or it is from before Temple kept
    /// that, which counts the same).
    public let typed: Bool
    /// Its claim reached core.
    public let joined: Bool
    public init(handle: String, directory: String, ended: Bool, sessionID: String? = nil, typed: Bool = false,
                joined: Bool = false) {
        self.handle = handle; self.directory = directory; self.ended = ended
        self.sessionID = sessionID; self.typed = typed; self.joined = joined
    }
}

/// A session Temple started on a host, as "Running sessions on <host>" lists it.
/// Only tracked runs are ever listed; nothing is discovered.
public struct RemoteTrackedSession: Equatable, Identifiable {
    public enum State: Equatable {
        case present(attached: Bool)
        /// Temple couldn't check it; why.
        case unknown(String)
    }
    public var id: String { handle }
    public let handle: String
    public let sessionID: String?
    public let agent: Agent
    public let state: State
    public let leftRunning: RemoteLeftRunningReason?
    /// Its folder, for opening a pending Codex session from the sheet.
    public let directory: String?
    public init(handle: String, sessionID: String?, agent: Agent, state: State, leftRunning: RemoteLeftRunningReason?,
                directory: String? = nil) {
        self.handle = handle; self.sessionID = sessionID; self.agent = agent; self.state = state
        self.leftRunning = leftRunning; self.directory = directory
    }
}

/// The folder sheet's advisory check.
public enum RemoteFolderCheck: Equatable {
    case exists(resolved: String)
    case missing
    case cannotEnter(String)
    case transport(String)
}

/// `remote-state.sqlite` itself, for the writes that must not depend on a
/// host's registry entry or launcher (round 4): a run handed over to
/// `open_tabs` is marked so by its handle, whatever has become of its host
/// since. One store on this Mac, held by the obligation that needs it.
@MainActor
public protocol RemoteRunLedger: AnyObject {
    /// Marks the run handed over, only while it still holds `sessionID`
    /// (the claim the hand-over was owed for).
    func markTabClosed(_ handle: String, sessionID: String) async throws
}

@MainActor
public protocol RemoteSessionHost: HostLauncher {
    var hostName: String { get }
    /// Decides attach or create (one transaction), recovers an uncollected
    /// record first, and writes the run before returning. Throws (refusing
    /// the open) when the run store cannot be read or written.
    func open(agent: Agent, sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool,
              startNew: Bool, resumeUnconfirmed: Bool) async throws -> RemoteOpenResult
    /// An open that was planned but never spawned.
    func abandon(_ handle: String) async
    func collect(_ handle: String) async -> RemoteLaunchOutcome
    /// What the pane showed (ANSI and all), for an agent that ended at once.
    func diagnostics(_ handle: String) async -> String?
    /// Nil, or why the creation was recorded as failed instead (its launch
    /// never reached the host).
    func markCreationUnproven(_ handle: String) async -> String?
    /// Stages a connecting tab's launch once the master answers.
    func stage(_ name: String) async -> RemoteStageResult
    /// Discard: the session's runs are never attached to or resumed again.
    func discard(sessionID: String) async throws
    func exitCheck(_ handle: String) async -> RemoteLiveness
    /// The run's current attachment; asynchronous results for another are dropped.
    func attachment(of handle: String) async -> Int?
    /// Throws `CancellationError` only when cancelled before any answer.
    func stop(_ handle: String, fromAttachedTab: Bool) async throws -> RemoteStopResult
    func leaveRunning(_ handle: String, reason: RemoteLeftRunningReason) async
    /// Whether the session has a run that is not Ended (as last read).
    func hasLiveRun(sessionID: String) -> Bool
    /// The session's live run's handle, read now.
    func liveRunHandle(sessionID: String) async -> String?
    func manualStopCommand(handle: String) -> String
    /// The tracked sessions, each checked on its own server; `checked`:
    /// whether the host answered at all.
    func trackedSessions() async -> (sessions: [RemoteTrackedSession], checked: Bool)
    func keep(_ handle: String) async
    /// At launch: the flagged, unnoticed sessions the host proved still
    /// running there, by handle: those a close left running, and those
    /// whose tab was connected when Temple quit. Nil when the host did not
    /// answer.
    func contactLeftRunning() async -> (closed: [String], quit: [String])?
    func noticeLeftRunning() async
    func checkFolder(_ path: String) async -> RemoteFolderCheck
    /// The host was removed or edited: nothing queries it again.
    func retire()

    // Codex identity (phase 1b)

    /// A new Codex session (`handle` nil), written before anything spawns,
    /// or a pending one reopened by its handle (attach-only while it runs).
    func openPending(handle: String?, directory: String) async throws -> RemotePendingOpenResult
    /// The automatic check; claims before it answers `.adopted`.
    func identify(_ handle: String) async -> RemoteIdentity
    /// The candidates to ask about; never adopts.
    func suggestions(_ handle: String) async -> RemoteSuggestions
    /// The user's yes (or Temple's, `automatic`, for a lone candidate):
    /// claimed under the same uniqueness as a verified id; an automatic
    /// one only while it is still the only candidate and the run has no
    /// declined candidate.
    func confirm(_ handle: String, suggestion: RemoteSuggestion, automatic: Bool) async -> RemoteIdentity
    /// "Not this one": never offered again for this run.
    func decline(_ handle: String, rolloutPath: String) async throws
    /// The core join refused the id: the run is pending again.
    func releaseClaim(_ handle: String, sessionID: String) async throws
    /// Not this one, on a link Temple made on its own: in one write, the
    /// claim on `sessionID` is released, `rolloutPath` declined for the
    /// run, and the run made restorable by its handle again.
    func unlink(_ handle: String, sessionID: String, rolloutPath: String) async throws
    func markJoined(_ handle: String) async throws
    /// Claims whose core join never happened, with their folders.
    func unjoinedClaims() async -> [(handle: String, sessionID: String, directory: String?)]
    func pendingRuns() async -> [RemotePendingRun]
    /// A pending run's tab closed: no chip at the next launch.
    func closePendingTab(_ handle: String) async throws
    /// Discard of a pending run.
    func dismissRun(_ handle: String) async throws
    /// Discard of a session Temple linked on its own, after its run's
    /// confirmed stop: that run alone, and only while no other run of the
    /// session is live or newer (checked in one transaction). Whether it was.
    func dismissStoppedRun(_ handle: String, sessionID: String) async throws -> Bool
    /// Something was typed into the run's tab.
    func recordInput(_ handle: String) async throws
    /// The run store itself, for an obligation to hold (nil when it can't
    /// be opened).
    func runLedger() -> RemoteRunLedger?
}

/// A remote tab's side of its run (memory only; the run row is durable).
public struct RemoteTabState: Equatable {
    public enum Phase: Equatable {
        /// The open is deciding (and may be recovering a record).
        case opening
        /// The tab's ssh client is running.
        case connected
        /// The client ended; the final collection and exit check are running.
        case checking
        /// The client ended and the session is still there.
        case disconnected
        /// The client ended and Temple can't tell whether the agent runs.
        case unknown(reason: String)
        /// The agent ended seconds after it was started: the tab stays, so
        /// what it printed can be read (as for a local tab).
        case exitedEarly
        /// The pane could not enter its folder; no agent ran.
        case failedToStart(directory: String)
        /// Stop was chosen; the one-command stop is running.
        case stopping
        /// Stop was chosen and could not be confirmed.
        case stopFailed(String)
        /// The session was stopped with no transcript found for it on the
        /// host (`checked`), or Temple couldn't check: Start a new session or
        /// Discard (and Resume, unchecked); never a blind resume.
        case needsDecision(checked: Bool)
        /// A new Codex session ended before Temple learned its id: the
        /// suggestions (if any), Start a new session and Discard. A yes
        /// closes the tab, as a local exit does; the row is the way back.
        case endedPending
    }
    public var phase: Phase
    public var handle: String?
    public var attachment: Int = 0
    public var creating = false
    /// This Open already turned an attach that found nothing into a resume.
    public var resumedAfterAbsence = false
    /// What the pane showed, for an agent that ended at once: the last
    /// lines, plain text.
    public var diagnostics: [String] = []
    /// A sign of life arrived for this open (the pane's record, a title).
    public var evidenceSeen = false
    /// The owned operation staging this open's launch after the spawn.
    public var stageOperation: UUID?
    /// No sign of life within the startup deadline: the header says so.
    public var stillConnecting = false
    /// Identifies one open, so a late answer for an earlier one is dropped.
    var openToken = UUID()
    /// A pending Codex run's candidates, asked about in the tab.
    public var suggestions: [RemoteSuggestion] = []
    /// A line under the question: why Temple couldn't tell, or core's
    /// reason for refusing the id.
    public var identityNote: String?
    /// The suggestion whose yes is being written.
    public var confirming: [UInt8]?
    /// The owned identity schedule of this open.
    var identityOperation: UUID?
    /// Core refused the id this run's check found: Try again is offered.
    public var identityRefused = false
    /// Temple said yes on its own to the lone candidate in this connection:
    /// `identityNote` says so, and Not this one undoes it.
    public var linkedOnItsOwn = false
    /// The candidate that link was to (what Not this one declines).
    public var linkedSuggestion: RemoteSuggestion?
    /// Not this one's write is out: the button waits for it.
    public var unlinking = false
    /// Not this one committed: "couldn't tell" shows until the question's
    /// candidates arrive.
    public var unlinkFallback = false

    public init(phase: Phase) { self.phase = phase }

    /// The run may still be on the host: a close stops it there.
    var mayBeRunning: Bool {
        switch phase {
        case .connected, .checking, .disconnected, .unknown, .stopping, .stopFailed: handle != nil
        case .opening, .failedToStart, .exitedEarly, .needsDecision, .endedPending: false
        }
    }
}

/// What the remote surfaces say, in one place (copy from the design, no
/// "run"; the cold-read round's decisions, docs/designs/remote-ssh.md).
/// Every label says what it does; where one does not fit, the layout gives.
/// Prose names the products (Claude Code, Codex); a command's name appears
/// only as what was looked for.
public enum RemoteCopy {
    // MARK: Tab bands

    public static func disconnected(_ host: String) -> String {
        "Disconnected from \(host). The session is still running there."
    }

    public static func unknown(_ host: String, agent: Agent, reason: String) -> String {
        "Disconnected from \(host). Temple can't tell whether \(agent.displayName) is still running there: \(sentence(reason))"
    }

    public static func failedToStart(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) failed to start on \(host)."
    }

    public static func launchFailed(_ host: String, reason: String) -> String {
        "Temple couldn't start this session on \(host): \(sentence(reason))"
    }

    /// A reattach whose launch could not be staged: the sidebar's notice,
    /// naming the session.
    public static func couldNotReconnect(_ session: String, host: String, reason: String) -> String {
        "Temple couldn't reconnect \(session) to \(host): \(sentence(reason))"
    }

    public static func cannotEnter(_ directory: String, host: String) -> String {
        "Temple couldn't enter the folder \(directory) on \(host)."
    }

    /// B1: the link that ends this tab's connection attempt.
    public static let cancelConnecting = "Cancel connecting"
    public static let cancelConnectingHelp =
        "Stops only this tab's connection attempt. An agent that already started on the host keeps running."

    /// B3's answers: each opens a confirmation first.
    public static let resumeAnywayButton = "Resume anyway\u{2026}"
    public static let startNewPendingButton = "Start a new session\u{2026}"

    /// B4, B5, B12: a fresh agent in this tab, same folder.
    public static let startNewHere = "Start a new session here"
    /// B5: resume without the transcript check.
    public static let tryToResume = "Try to resume"
    public static func tryToResumeHelp(_ agent: Agent) -> String {
        "If there is nothing to resume, \(agent.displayName) exits and this band says so."
    }

    // MARK: Working agents (X1, S12, the quit, O1, O3)

    /// The close prompt's title, for a working agent on a host (working:
    /// busy with a task; only a working agent is asked about).
    public static func stillWorking(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) is working on \(host)."
    }

    /// The close prompt's message.
    public static func stillWorkingMessage(_ host: String) -> String {
        "Detach leaves it running on \(host); Stop ends it."
    }

    /// The close prompt for a tab reattached a moment ago, before anything
    /// has said whether its agent is working: never a claim Temple can't
    /// back.
    public static func mayStillBeWorking(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) may still be working on \(host)."
    }

    public static func mayStillBeWorkingMessage(_ host: String) -> String {
        "Temple reattached to it a moment ago and can't tell yet. Detach leaves it running on \(host); Stop ends it."
    }

    /// Stopping a working agent from Running sessions or a row's menu asks
    /// first; an agent waiting for input stops at once.
    public static func stopWorkingTitle(_ host: String, agent: Agent, uncertain: Bool = false) -> String {
        uncertain ? "\(agent.displayName) may still be working on \(host). Stop it?"
            : "\(agent.displayName) is working on \(host). Stop it?"
    }

    /// Said only when the session has a tab open here.
    public static let stopWorkingMessage = "Its tab closes."

    /// The quit prompt, when a host has a connected tab: this Mac's working
    /// agents are what a quit interrupts. (With no host the prompt reads as
    /// it always did.)
    public static func quitTitle(workingCount: Int) -> String {
        workingCount == 1 ? "An agent on this Mac is still working."
            : "\(workingCount) agents on this Mac are still working."
    }

    public static func quitMessage(workingCount: Int) -> String {
        workingCount == 1
            ? "Quitting interrupts it; its session reopens next launch, but what it is doing right now stops here."
            : "Quitting interrupts them; their sessions reopen next launch, but what they are doing right now stops here."
    }

    /// The quit prompt's last paragraph: every session on those hosts keeps
    /// running, working or waiting.
    public static func quitLine(_ hosts: [String]) -> String {
        "Sessions on \(list(hosts)) keep running; their tabs reconnect when you open them next launch."
    }

    /// The command line's refusal to close a working tab on a host.
    public static func workingCLIRefusal(_ host: String) -> String {
        "Its agent is working on \(host). Pass --force to detach it (it keeps running), or stop it in Temple."
    }

    // MARK: Closing and detaching (P4, P6, the File menu, the tab's ×)

    /// Closes a tab on a host and leaves its agent running there.
    public static func detachMenuItem(_ host: String) -> String { "Detach from \(host) (keeps running)" }

    /// "Close tab" on a tab on a host: what it does to the agent.
    public static let closeHostTabMenuItem = "Close tab (stops the agent if it is waiting for input)"

    /// The × of a tab on a host.
    public static func closeHostTabHelp(_ host: String, agent: Agent) -> String {
        "Close tab. Stops \(agent.displayName) on \(host) if it is waiting for input; asks first if it is working."
    }

    /// A row whose agent still runs on its host can't be archived (as
    /// "Close tabs to archive").
    public static func stopToArchive(_ host: String) -> String { "Stop it on \(host) to archive" }

    /// A host's name as a sentence shows it: each hyphen non-breaking
    /// (U+2011), so the name wraps whole, never at "-". Display only: never
    /// a name Temple connects to, stores or compares.
    public static func displayHost(_ host: String) -> String {
        host.replacingOccurrences(of: "-", with: "\u{2011}")
    }

    // MARK: Running sessions on <host>

    /// The sheet's title. One name everywhere: the Hosts card, the project
    /// heading's menu, a tab's band and the sidebar's notice all open it by
    /// these words (`sessionsOnMenuItem`).
    public static func sessionsOn(_ host: String) -> String { "Running sessions on \(host)" }

    /// The link, button or menu item that opens it.
    public static func sessionsOnMenuItem(_ host: String) -> String { "Running sessions on \(host)\u{2026}" }

    /// A tracked session's state, a state and never an imperative:
    /// running (alive on the host), running in a tab here, or unknown.
    /// Another client attached (a terminal, another Temple) is still
    /// "Running": tmux's attachment count can't tell them apart.
    public static func trackedState(_ state: RemoteTrackedSession.State, openHere: Bool) -> String {
        switch state {
        case .present: openHere ? "Running in a tab" : "Running"
        case .unknown: "Status unknown"
        }
    }

    /// The tmux session behind a tracked one, for someone who will ssh in:
    /// a tooltip, not a line.
    public static func trackedHandleHelp(_ handle: String) -> String { "tmux session temple-\(handle)" }

    public static let openTracked = "Open"
    /// Open, for a run Temple can't open (no folder on record): what to do.
    public static func cannotOpenTracked(_ handle: String) -> String {
        "Temple can't open this session: it has no folder on record. Stop it here, "
            + "or attach from a terminal on the host with tmux -L temple attach -t temple-\(handle)."
    }
    public static let openTrackedHelp = "Opens a tab attached to this running session."
    public static let showTab = "Show tab"
    public static func stopTrackedHelp(_ host: String) -> String {
        "Ends the agent on \(host). Its sidebar row stays, so you can resume it later."
    }
    /// Only on a row with a left-running note: clears the note.
    public static let dismissNote = "Dismiss"
    public static let dismissNoteHelp = "Clears this note. The session keeps running either way."

    public static func couldNotCheck(_ reason: String) -> String {
        "Temple couldn't check these sessions: \(sentence(reason))"
    }

    public static let tryAgain = "Try again"

    public static let noTrackedSessions = "No running sessions started from Temple."

    /// The line under a left-running session in Running sessions: why it
    /// was left running (it explains; the sheet is already open).
    public static func leftRunningLine(_ host: String, reason: RemoteLeftRunningReason) -> String {
        switch reason {
        case .hostDidNotAnswer: "Left running: \(host) didn't answer when you closed it."
        case .anotherClientAttached: "Left running: another terminal is attached to it."
        case .stopNotAcknowledged: "Left running: \(host) didn't confirm the stop."
        case .quitDeadline: "Left running: \(host) didn't answer before Temple quit."
        case .detachedAtQuit: ""
        }
    }

    /// A Stop from the sheet that failed (S9), in the row it is about.
    public static func notStoppedLine(_ reason: RemoteLeftRunningReason, detail: String?) -> String {
        switch reason {
        case .anotherClientAttached: "Not stopped: another terminal is attached to it."
        default: "Not stopped: \(trimmed(detail ?? "the host didn't confirm the stop")). It may still be running."
        }
    }

    /// What a failed stop says where the session is already in view (S9,
    /// a tab's band, the Remove alert's outcome); nil when it stopped.
    public static func stopFailure(_ result: RemoteStopResult, host: String, agent: Agent, title: String? = nil) -> String? {
        switch result {
        case .stopped: nil
        case .leftRunning(let reason, let detail):
            title.map { "\u{201C}\($0)\u{201D}: " + notStoppedLine(reason, detail: detail) } ?? notStoppedLine(reason, detail: detail)
        case .unrecorded(let detail): unrecorded(host, detail: detail, session: title.map { "\u{201C}\($0)\u{201D}" })
        }
    }

    // MARK: Failed stops and records (B6, P5)

    /// A tab whose Stop failed (B6): the sentence; the band's button opens
    /// Running sessions.
    public static func couldNotStop(_ host: String, agent: Agent, reason: String) -> String {
        "Temple couldn't stop \(agent.displayName) on \(host): \(trimmed(reason)). It may still be running."
    }

    /// How every line about a stop that may not have happened ends.
    public static let mayStillBeRunning = "It may still be running."

    /// B6 when another terminal held the session.
    public static let notStoppedAttached = "Not stopped: another terminal is attached to it. It may still be running."

    /// A session's name in a notice: its title in quotes, or what it is.
    public static func sessionName(title: String?, agent: Agent, directory: String) -> String {
        if let title, !title.isEmpty, title != agent.newSessionTitle { return "\u{201C}\(title)\u{201D}" }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return "the new \(agent.displayName) session in \(folder.isEmpty ? directory : folder)"
    }

    /// The sidebar's notice when a close left a session running, naming it.
    public static func leftRunning(_ host: String, session: String, reason: RemoteLeftRunningReason, detail: String?) -> String {
        switch reason {
        case .hostDidNotAnswer:
            "\(capitalized(session)) wasn't stopped: \(host) didn't answer when you closed its tab. It may still be running."
        case .anotherClientAttached:
            "\(capitalized(session)) wasn't stopped: another terminal is attached to it. It may still be running."
        case .stopNotAcknowledged, .quitDeadline, .detachedAtQuit:
            "Temple couldn't stop \(session) on \(host): \(trimmed(detail ?? "the host didn't confirm the stop")). It may still be running."
        }
    }

    /// Temple's own record could not be written. `session`: the session's
    /// name as a notice gives it; nil where the session is in view ("this
    /// session", in a band or the sheet).
    public static func unrecorded(_ host: String, detail: String, session: String? = nil) -> String {
        if let session {
            return "Temple couldn't save its record of \(session) on \(host) (\(trimmed(detail))), "
                + "so what it shows for that session may be out of date."
        }
        return "Temple couldn't save its record of this session on \(host) (\(trimmed(detail))), "
            + "so what it shows for this session may be out of date."
    }

    /// The launch-time notice: sessions a close left running (flagged).
    public static func leftRunningCount(_ count: Int, host: String) -> String {
        count == 1 ? "A session you closed is still running on \(host)."
            : "\(count) sessions you closed are still running on \(host)."
    }

    /// The launch-time notice: sessions whose tabs were connected when
    /// Temple quit, still running and not open in a tab.
    public static func quitCount(_ count: Int, host: String) -> String {
        count == 1 ? "A session from before you quit is running on \(host)."
            : "\(count) sessions from before you quit are running on \(host)."
    }

    // MARK: Entry points and the folder sheet

    /// The start page's row for a host: the default agent's name.
    public static func newSessionOn(_ host: String, agent: Agent) -> String {
        "New \(agent.displayName) session on \(host)\u{2026}"
    }

    /// The folder sheet's title; the host follows it in mono.
    public static func folderSheetTitle(_ agent: Agent) -> String { "New \(agent.displayName) session" }

    /// The folder sheet's field label (the sheet's title names the host).
    public static let folderFieldLabel = "Folder"
    public static let recentFoldersCaption = "Recent folders on this host. Click one to start there."
    public static let startWithoutChecking = "Start without checking"
    public static let startWithoutCheckingHelp =
        "Starts the session without checking the folder; if the folder is missing, the tab says so."

    public static func noFolder(_ path: String, host: String) -> String { "No folder \(path) on \(host)." }

    // MARK: Settings, Hosts

    public static let hostsLabel = "Added hosts"
    public static let hostsEmpty = "No hosts yet."
    public static let goneFromConfig =
        "No longer in ~/.ssh/config: ssh may not reach it by this name. Add it back to the file, or remove the host."
    public static let openSSHConfig = "Open ~/.ssh/config"
    public static let removeHost = "Remove"
    public static func removeHostHelp(fromConfig: Bool) -> String {
        fromConfig ? "Removes it from Temple. ~/.ssh/config is not changed." : "Removes it from Temple."
    }

    /// Remove, with Temple-started sessions still running there.
    public static func removalTitle(_ count: Int, host: String) -> String {
        count == 1 ? "A session is still running on \(host)." : "\(count) sessions are still running on \(host)."
    }

    public static func removalMessage(_ count: Int, fromConfig: Bool) -> String {
        let message = count == 1
            ? "Removing the host leaves it running there, and Temple can't list or stop it until the host is added again."
            : "Removing the host leaves them running there, and Temple can't list or stop them until the host is added again."
        return fromConfig ? message + " ~/.ssh/config is not changed." : message
    }

    public static func removalLeave(_ count: Int) -> String {
        count == 1 ? "Remove, leave it running" : "Remove, leave them running"
    }

    public static func removalStop(_ count: Int) -> String {
        count == 1 ? "Stop it and remove" : "Stop them and remove"
    }

    /// A Stop them and remove that could not stop everything: the host
    /// stays.
    public static func notRemoved(_ host: String) -> String { "\(host) was not removed:" }

    /// How Temple tells a new Codex tab's session apart: by Codex's
    /// arguments (`--no-daemon`, Codex's "run without the shared
    /// background server").
    public static func noDaemonHint(enabled: Bool) -> String {
        enabled
            ? "Codex's arguments include --no-daemon, so Temple can tell which session a new Codex tab on a host is without asking you."
            : "Add --no-daemon to Codex's arguments above and Temple won't have to ask you which session a new Codex tab on a host is: "
                + "Codex then runs each session in its own process instead of a shared background server, which is what lets Temple tell them apart."
    }

    /// The host form.
    public static let hostFormAddTitle = "Add host by address"
    public static let hostFormNameNote =
        "Temple uses this name as the host's ssh name too. It can't be changed later; address, user and port can."
    public static let hostFormUserPlaceholder = "Optional (ssh's default)"
    public static let hostFormEditHint =
        "Saving disconnects this host's open tabs; their agents keep running. Use Reconnect in each."

    /// The Add host sheet (Settings, Hosts): one field, the config's unused
    /// aliases under it, the form for an address behind a link.
    public static let addHostTitle = "Add host"
    public static let addHostFieldLabel = "Host"
    public static let addHostPlaceholder = "alias from ~/.ssh/config, or user@address"
    public static let addHostListCaption = "Click a host to add it at once."
    /// An alias whose blocks set neither User nor HostName.
    public static let addHostNoDestination = "no User or HostName set"
    /// The rows not shown yet, as the sidebar says it ("Show 3 more").
    public static func addHostShowMore(_ hidden: Int) -> String { "Show \(hidden) more" }
    public static let addHostUnreadable = "Enter an alias from ~/.ssh/config, or user@address with an optional :port."
    public static let addHostNoConfigHosts = "No hosts in ~/.ssh/config."
    public static let addHostAllInUse = "Every host in ~/.ssh/config is already added."
    public static func addHostAlreadyInUse(_ name: String) -> String { "\(name) is already added." }
    public static let addHostNotInConfig = "Not in ~/.ssh/config?"
    public static let addHostEnterDetails = "Add host by address\u{2026}"
    public static let addHostEditConfig = openSSHConfig
    /// The default button: Add for an alias (or nothing typed), the form
    /// for an address.
    public static let addHostAdd = "Add"
    public static let addHostByAddress = "Add host by address\u{2026}"
    /// Return or Add waits for the config's read.
    public static let addHostReadingConfig = "Reading ~/.ssh/config\u{2026}"

    /// Resume anyway's confirmation (a sheet): a short title, why, and the
    /// command that stops the original on the host, apart, to copy.
    public static let resumeAnywayTitle = "Resume anyway?"

    public static func resumeAnyway(_ host: String) -> String {
        "Temple can't reach this session on \(host) and can't tell whether it is still running. "
            + "If it is, it keeps running."
    }

    /// The hint under either confirmation: how to stop the original there.
    public static func stopHint(_ host: String) -> String { "To stop the original on \(host), run:" }

    /// Start a new session for a new Codex session Temple can't reach.
    public static let startNewPendingTitle = "Start a new session?"

    public static func startNewPending(_ host: String) -> String {
        "Temple can't tell whether Codex is still running on \(host). "
            + "If it is, it keeps running, and a new session starts beside it."
    }

    /// B9: a tab on a host Temple doesn't have.
    public static func notSetUp(_ host: String) -> String {
        "\(host) is not in Temple's hosts, so this session can't open. Add the host in Settings."
    }

    public static let openSettings = "Open Settings"

    /// A tab still open for a host just removed from Temple, at once (not
    /// only when it is opened again).
    public static func hostRemoved(_ host: String) -> String {
        "\(host) was removed from Temple. Its agent may still be running there; add the host again to reconnect."
    }

    public static let unconfirmedConversation =
        "This session was stopped before it had a conversation on its host, so there is nothing to resume."

    public static func uncheckedConversation(_ host: String) -> String {
        "Temple couldn't check whether this session has a conversation to resume on \(host)."
    }

    public static func stillConnecting(_ host: String) -> String { "Still connecting to \(host)…" }

    public static func exitedImmediately(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) exited immediately on \(host)."
    }

    /// O1, the shortcuts panel's note when a host is added.
    public static let scrollingNote =
        "In a session on a host, scrolling up shows the terminal's scrollback; the first key you type returns to the prompt. "
            + "A host agent is working while it is busy with a task and waiting otherwise; "
            + "closing its tab while it waits stops it, and Detach in the tab's menu leaves it running."

    /// What the pane printed, for a header: escape sequences and carriage
    /// returns removed, the last few lines that say something.
    public static func diagnosticLines(_ raw: String, limit: Int = 8) -> [String] {
        var text = String.UnicodeScalarView()
        var scalars = Array(raw.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if scalar == "\u{1b}" {
                guard let next = scalars.popFirst() else { break }
                if next == "[" {
                    // CSI: parameters, then a final byte in @...~.
                    while let byte = scalars.popFirst(), !(0x40...0x7e).contains(byte.value) {}
                } else if next == "]" || next == "P" || next == "_" || next == "^" {
                    // OSC and other strings: to BEL or ST.
                    while let byte = scalars.popFirst() {
                        if byte == "\u{07}" { break }
                        if byte == "\u{1b}", scalars.first == "\\" { scalars.removeFirst(); break }
                    }
                }
                continue
            }
            if scalar == "\r" { continue }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
            text.append(scalar)
        }
        let lines = String(text).split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(lines.suffix(limit))
    }

    // Codex identity (phase 1b)

    public static func codexEndedPending(_ host: String) -> String {
        "Codex ended on \(host) before Temple learned which session this was."
    }

    /// The ended band's one sentence, the question after the fact: the
    /// candidate's first prompt and when it started. Never a fact.
    public static func codexEndedQuestion(_ host: String, suggestion: RemoteSuggestion, now: Date = Date()) -> String {
        let subject = suggestion.firstPrompt.map { "\u{201C}\($0)\u{201D}" }
            ?? (suggestion.promptKnown ? "the one with no prompt yet" : "the one whose first prompt couldn't be read")
        return codexEndedPending(host) + " Is it \(subject) (\(startStamp(suggestion.startedAt, now: now)))?"
    }

    /// Where an ended session's terminal was: tmux's exit leaves the
    /// client's screen blank, and the pane's last screen is not kept. A
    /// fact, not a failure: there is nothing to try again.
    public static func endedScreenNotKept(_ host: String, agent: Agent) -> String {
        "\(agent.displayName)'s last screen on \(host) isn't kept after it ends."
    }

    /// Above the candidates: why Temple asks at all.
    public static let codexQuestionLeadIn = "Codex picks its own session id, so Temple can't tell which session this tab is."

    /// The question about one candidate: never a fact. The folder is the
    /// candidate's full path. When the tab's open time and the host's clock
    /// offset are both known, the start (on the host's clock) is moved to
    /// this Mac's and said relative to the open ("4 s after this tab
    /// opened"), which tells apart candidates whose prompts read the same;
    /// otherwise (or a start before it, or an hour after) the clock time.
    public static func suggestionQuestion(_ suggestion: RemoteSuggestion, tabOpenedAt: Date? = nil,
                                          now: Date = Date()) -> String {
        let prompt = suggestion.firstPrompt.map { "\u{201C}\($0)\u{201D}" }
            ?? (suggestion.promptKnown ? "No prompt yet" : "First prompt unreadable")
        var relative: String?
        if let tabOpenedAt, let offset = suggestion.hostClockOffset {
            relative = afterOpen(suggestion.startedAt.addingTimeInterval(-offset), openedAt: tabOpenedAt)
        }
        let when = relative ?? startTime(suggestion.startedAt, now: now)
        return "Is this the session? \(prompt), started in \(suggestion.directory) \(when)."
    }

    /// "as this tab opened", "4 s after this tab opened", "1 min after this
    /// tab opened"; nil for
    /// a start before the open (beyond a few seconds of clock difference)
    /// or an hour or more after it.
    static func afterOpen(_ start: Date, openedAt: Date) -> String? {
        let delta = start.timeIntervalSince(openedAt)
        guard delta > -5, delta < 3600 else { return nil }
        let seconds = max(0, Int(delta.rounded()))
        if seconds == 0 { return "as this tab opened" }
        if seconds < 60 { return "\(seconds) s after this tab opened" }
        return "\(Int((Double(seconds) / 60).rounded())) min after this tab opened"
    }

    static func startTime(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "at " + formatter.string(from: date)
        }
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "on " + formatter.string(from: date)
    }

    /// A start time on its own: the time today, else the date and time.
    static func startStamp(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static let suggestionYes = "Yes, that's it"
    public static let suggestionNo = "Not this one"

    /// The note a tab shows when Temple said yes on its own to the lone
    /// candidate: why (the only one); "Not this one" beside it undoes the
    /// link, and the agent keeps running.
    public static func linkedOnItsOwn(_ suggestion: RemoteSuggestion, now: Date = Date()) -> String {
        if let prompt = suggestion.firstPrompt {
            return "Linked this tab to \u{201C}\(prompt)\u{201D}, the only Codex session started in this folder since the tab opened."
        }
        return "Linked this tab to the Codex session started \(startTime(suggestion.startedAt, now: now)), "
            + "the only one started in this folder since the tab opened."
    }

    /// Temple asked and has nothing left to ask about (every candidate
    /// declined, or the one it would claim is another session's): the tab
    /// keeps working, unidentified, with Try again.
    public static let couldNotTell = "Temple couldn't tell which Codex session this is. "
        + "The tab keeps working; it gets a sidebar row once Temple can tell."

    /// "Discard" said which, per row (one meaning: a session that is not
    /// running; nothing is stopped): removed, or archived when the row is
    /// the user's (named, pinned, colored) or has a transcript.
    public static func discardLabel(archives: Bool) -> String { archives ? "Archive session" : "Remove from Temple" }

    public static func discardHelp(archives: Bool) -> String {
        archives
            ? "Archives this session, since it is named, pinned, colored or has a transcript; restore it from History. "
                + "Nothing is running on the host to stop."
            : "Removes this session from Temple. Nothing is running on the host to stop."
    }

    public static func findNote(_ host: String) -> String {
        "Searching what this tab has shown since it connected to \(host)."
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func trimmed(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while line.hasSuffix(".") { line.removeLast() }
        return line
    }

    static func sentence(_ text: String) -> String { trimmed(text) + "." }
}

/// Where a host's projects keep their archive mask and their part of the
/// manual order: the remote store, never `project_state`.
@MainActor
public protocol RemoteProjectStatePersisting: AnyObject {
    func projectStates() -> [(key: ProjectKey, archived: Bool, position: Int?)]
    func setArchived(_ archived: Bool, key: ProjectKey)
    func setOrder(_ keys: [(key: ProjectKey, position: Int)])
}
