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
    public init(rolloutPath: String, sessionID: String, firstPrompt: String?, startedAt: Date, directory: String,
                promptKnown: Bool = true) {
        self.rolloutPath = rolloutPath; self.sessionID = sessionID; self.firstPrompt = firstPrompt
        self.startedAt = startedAt; self.directory = directory; self.promptKnown = promptKnown
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

/// A session Temple started on a host, as "Sessions on <host>" lists it.
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
    func markTabClosed(_ handle: String) async throws
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
    /// Whether a master answers on Temple's socket for this host now.
    func hasLiveMaster() async -> Bool
    func manualStopCommand(handle: String) -> String
    /// The tracked sessions, each checked on its own server; `checked`:
    /// whether the host answered at all.
    func trackedSessions() async -> (sessions: [RemoteTrackedSession], checked: Bool)
    func keep(_ handle: String) async
    /// At launch: nil when the host did not answer, else how many flagged
    /// sessions are still left running there.
    func contactLeftRunning() async -> Int?
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
    /// The user's yes: claimed under the same uniqueness as a verified id.
    func confirm(_ handle: String, suggestion: RemoteSuggestion) async -> RemoteIdentity
    /// "Not this one": never offered again for this run.
    func decline(_ handle: String, rolloutPath: String) async throws
    /// The core join refused the id: the run is pending again.
    func releaseClaim(_ handle: String, sessionID: String) async throws
    func markJoined(_ handle: String) async throws
    /// Claims whose core join never happened, with their folders.
    func unjoinedClaims() async -> [(handle: String, sessionID: String, directory: String?)]
    func pendingRuns() async -> [RemotePendingRun]
    /// A pending run's tab closed: no chip at the next launch.
    func closePendingTab(_ handle: String) async throws
    /// Discard of a pending run.
    func dismissRun(_ handle: String) async throws
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
    /// Whether the agent was working when its client ended (the quit stops
    /// only an agent last seen idle).
    public var lastSeenWorking = false
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
    /// This launch attached a client to the run (a restored chip never
    /// opened has not): only then does the quit stop it when idle.
    var attachedThisLaunch = false
    /// Core refused the id this run's check found: Try again is offered.
    public var identityRefused = false

    public init(phase: Phase) { self.phase = phase }

    /// The run may still be on the host: a close stops it there.
    var mayBeRunning: Bool {
        switch phase {
        case .connected, .checking, .disconnected, .unknown, .stopping, .stopFailed: handle != nil
        case .opening, .failedToStart, .exitedEarly, .needsDecision, .endedPending: false
        }
    }
}

/// What remote tabs say, in one place (copy from the design, no "run").
public enum RemoteCopy {
    public static func disconnected(_ host: String) -> String {
        "Disconnected from \(host). Open the session again to reconnect."
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

    public static func couldNotPrepare(_ host: String, reason: String) -> String {
        "Temple couldn't reconnect to \(host): \(sentence(reason))"
    }

    public static func cannotEnter(_ directory: String, host: String) -> String {
        "Temple couldn't enter the folder \(directory) on \(host)."
    }

    public static func stillWorking(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) is still working on \(host)."
    }

    /// The working prompt's message line, as local's has one (the title
    /// names the host).
    public static let stillWorkingMessage = "Detach leaves it running; Stop ends it."

    /// A host's name as a sentence shows it: each hyphen non-breaking
    /// (U+2011), so the name wraps whole, never at "-". Display only: never
    /// a name Temple connects to, stores or compares.
    public static func displayHost(_ host: String) -> String {
        host.replacingOccurrences(of: "-", with: "\u{2011}")
    }

    /// "Sessions on <host>": the sheet's title and the button that opens it.
    public static func sessionsOn(_ host: String) -> String { "Sessions on \(host)" }

    /// The menu item that opens it (a host project heading's context menu).
    public static func sessionsOnMenuItem(_ host: String) -> String { "Sessions on \(host)\u{2026}" }

    /// A tracked session's state in "Sessions on <host>", in the app's words
    /// (nothing local says "attached"), a state and never an imperative.
    /// `openHere`: this Temple has a live tab of the run ("In a tab").
    /// Another client attached (a terminal, another Temple) is still
    /// "Running": tmux's attachment count can't tell them apart.
    public static func trackedState(_ state: RemoteTrackedSession.State, openHere: Bool) -> String {
        switch state {
        case .present: openHere ? "In a tab" : "Running"
        case .unknown: "Unknown"
        }
    }

    /// The tmux session behind a tracked one, for someone who will ssh in:
    /// a tooltip, not a line.
    public static func trackedHandleHelp(_ handle: String) -> String { "tmux session temple-\(handle)" }

    /// The folder sheet's field label (the sheet's title names the host).
    public static let folderFieldLabel = "Folder"

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

    public static func notSetUp(_ host: String) -> String {
        "Host \(host) is not set up. Add it in Settings to open this session."
    }

    public static func couldNotStop(_ host: String, agent: Agent, reason: String) -> String {
        "Temple couldn't stop \(agent.displayName) on \(host): \(trimmed(reason)). It may still be running; see Sessions on \(host)."
    }

    /// The notice when a close left a session running: the sheet's line
    /// for the same reason, and where to stop it.
    public static func leftRunning(_ host: String, agent: Agent, reason: RemoteLeftRunningReason, detail: String?) -> String {
        switch reason {
        case .hostDidNotAnswer, .anotherClientAttached:
            leftRunningLine(host, reason: reason) + " Stop it under Sessions on \(host)."
        case .stopNotAcknowledged, .quitDeadline:
            couldNotStop(host, agent: agent, reason: detail ?? "the host didn't confirm the stop")
        }
    }

    /// The line under a left-running session in "Sessions on <host>".
    public static func leftRunningLine(_ host: String, reason: RemoteLeftRunningReason) -> String {
        switch reason {
        case .hostDidNotAnswer: "Left running: \(host) didn't answer when you closed it."
        case .anotherClientAttached: "Left running: another terminal is attached to it."
        case .stopNotAcknowledged: "Left running: \(host) didn't confirm the stop."
        case .quitDeadline: "Left running: \(host) didn't answer before Temple quit."
        }
    }

    public static func leftRunningCount(_ count: Int, host: String) -> String {
        count == 1 ? "1 session left running on \(host)" : "\(count) sessions left running on \(host)"
    }

    public static func workingCLIRefusal(_ host: String) -> String {
        "Its agent is working on \(host). Pass --force to detach, or stop it in Temple."
    }

    public static func quitLine(_ hosts: [String]) -> String {
        "Sessions working on \(list(hosts)) keep running; Temple will reconnect to them."
    }

    public static func noFolder(_ path: String, host: String) -> String { "No folder \(path) on \(host)." }

    public static func couldNotCheck(_ reason: String) -> String {
        "Temple couldn't check these sessions: \(sentence(reason))"
    }

    public static let noTrackedSessions = "No sessions started from Temple."

    public static func unrecorded(_ host: String, detail: String) -> String {
        "Temple couldn't save what happened to this session on \(host): \(sentence(detail))"
    }

    public static let unconfirmedConversation =
        "This session was stopped before it had a conversation on its host, so there is nothing to resume."

    public static let uncheckedConversation =
        "Temple couldn't check whether this session has a conversation to resume on its host."

    public static func stillConnecting(_ host: String) -> String { "Still connecting to \(host)…" }

    public static func exitedImmediately(_ host: String, agent: Agent) -> String {
        "\(agent.displayName) exited immediately on \(host)."
    }

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

    /// The question about one candidate: never a fact.
    public static func suggestionQuestion(_ suggestion: RemoteSuggestion, now: Date = Date()) -> String {
        let prompt = suggestion.firstPrompt.map { "\u{201C}\($0)\u{201D}" }
            ?? (suggestion.promptKnown ? "No prompt yet" : "First prompt unreadable")
        let folder = URL(fileURLWithPath: suggestion.directory).lastPathComponent
        return "Is this the session? \(prompt), started \(startTime(suggestion.startedAt, now: now)) in \(folder)."
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

    /// A run whose id another session started from Temple already holds.
    public static let couldNotTell = "Temple couldn't tell which Codex session this is."

    /// Under the question: how Temple can tell by itself (Fable, round 1).
    public static let noDaemonHint = "With --no-daemon in Codex's arguments (Settings), Temple identifies the session on its own."

    /// What Discard does, for its help tag.
    public static func discardHelp(archives: Bool) -> String {
        archives
            ? "Archives this session, since you named, pinned or colored it. You can restore it from History."
            : "Removes this session from Temple."
    }

    public static func discardPendingHelp(_ host: String) -> String {
        "Temple stops tracking this session. Its transcript, if it has one, stays on \(host)."
    }

    public static func findNote(_ host: String) -> String {
        "Searching what this tab has shown since it connected to \(host)."
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
