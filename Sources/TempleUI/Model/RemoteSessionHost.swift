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
    public init(handle: String, sessionID: String?, agent: Agent, state: State, leftRunning: RemoteLeftRunningReason?) {
        self.handle = handle; self.sessionID = sessionID; self.agent = agent; self.state = state
        self.leftRunning = leftRunning
    }
}

/// The folder sheet's advisory check.
public enum RemoteFolderCheck: Equatable {
    case exists(resolved: String)
    case missing
    case cannotEnter(String)
    case transport(String)
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

    public init(phase: Phase) { self.phase = phase }

    /// The run may still be on the host: a close stops it there.
    var mayBeRunning: Bool {
        switch phase {
        case .connected, .checking, .disconnected, .unknown, .stopping, .stopFailed: handle != nil
        case .opening, .failedToStart, .exitedEarly, .needsDecision: false
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

    public static func resumeAnyway(_ host: String, stopCommand: String) -> String {
        "Temple can't reach this session on \(host) and can't tell whether it is still running. Resume anyway? "
            + "If the original is still running, it keeps running; you can stop it from \(host) with `\(stopCommand)`."
    }

    public static func notSetUp(_ host: String) -> String {
        "Host \(host) is not set up. Add it in Settings to open this session."
    }

    public static func couldNotStop(_ host: String, agent: Agent, reason: String) -> String {
        "Temple couldn't stop \(agent.displayName) on \(host): \(trimmed(reason)). It may still be running; see Sessions on \(host)."
    }

    /// The notice when a close left a session running.
    public static func leftRunning(_ host: String, agent: Agent, reason: RemoteLeftRunningReason, detail: String?) -> String {
        switch reason {
        case .hostDidNotAnswer:
            "Left running: \(host) didn't answer when you closed it. Stop it under Sessions on \(host)."
        case .anotherClientAttached:
            "Left running: another terminal is attached to it. Stop it under Sessions on \(host)."
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

    public static let noTrackedSessions = "No Temple sessions to show."

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

    public static func newCodexWaits(_ host: String) -> String {
        "Temple can't start new Codex sessions on \(host) yet."
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
