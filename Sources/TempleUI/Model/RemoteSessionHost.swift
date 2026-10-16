import Foundation
import TempleCore
import TempleTerminalAPI

// The app's view of a host whose agents run under a keep-alive there
// (docs/designs/remote-ssh.md sections 3 to 5). `TempleUI` names no type
// of `TempleRemoteHost` outside `Hosts/RemoteHost.swift`; the launcher
// there conforms to this protocol, so `OpenSessionsModel` drives a remote
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
    public init(handle: String, attachment: Int, creating: Bool, command: TerminalCommand, displayArgv: [String]) {
        self.handle = handle; self.attachment = attachment; self.creating = creating
        self.command = command; self.displayArgv = displayArgv
    }
}

/// What a creation's records said, once persisted.
public enum RemoteLaunchOutcome: Equatable {
    case ok(directory: String)
    case failedCD(directory: String)
    case clientFailed(String)
    case nothing
    case transport(String)
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
}

/// A session on the host's private server, as "Sessions on <host>" lists it.
public struct RemoteListedSession: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let attached: Bool
    /// The run Temple has under this name, if any ("Not in Temple" otherwise).
    public let handle: String?
    public let sessionID: String?
    public let leftRunning: RemoteLeftRunningReason?
    public init(name: String, attached: Bool, handle: String?, sessionID: String?, leftRunning: RemoteLeftRunningReason?) {
        self.name = name; self.attached = attached; self.handle = handle; self.sessionID = sessionID
        self.leftRunning = leftRunning
    }
}

public enum RemoteSessionListing: Equatable {
    case sessions([RemoteListedSession])
    /// No server at Temple's socket: nothing listed, nothing proven gone.
    case noServer
    case failed(String)
}

/// The folder sheet's advisory check.
public enum RemoteFolderCheck: Equatable {
    case exists(resolved: String)
    case missing
    case cannotEnter(String)
    case transport(String)
}

/// A live run of a session, as a row's menu needs it.
public struct RemoteRunSummary: Equatable {
    public let handle: String
    public let leftRunning: Bool
}

@MainActor
public protocol RemoteSessionHost: HostLauncher {
    var hostName: String { get }
    /// Decides attach or create, recovers an uncollected record first, and
    /// writes the run before returning. Throws (refusing the open) when the
    /// run store cannot be read or written.
    func open(agent: Agent, sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool) async throws -> RemoteOpenPlan
    /// An open that was planned but never spawned.
    func abandon(_ handle: String)
    func collect(_ handle: String) async -> RemoteLaunchOutcome
    func markCreationUnproven(_ handle: String)
    func exitCheck(_ handle: String) async -> RemoteLiveness
    /// The run's current attachment; asynchronous results for another are dropped.
    func attachment(of handle: String) -> Int?
    func stop(_ handle: String, fromAttachedTab: Bool) async -> RemoteStopResult
    func leaveRunning(_ handle: String, reason: RemoteLeftRunningReason)
    func liveRun(sessionID: String) -> RemoteRunSummary?
    /// Whether a master answers on Temple's socket for this host now.
    func hasLiveMaster() async -> Bool
    func manualStopCommand(handle: String) -> String
    func listSessions() async -> RemoteSessionListing
    func stopListed(_ name: String) async -> RemoteStopResult
    func keep(_ handle: String)
    func unnoticedLeftRunningCount() -> Int
    func noticeLeftRunning()
    func checkFolder(_ path: String) async -> RemoteFolderCheck
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
    }
    public var phase: Phase
    public var handle: String?
    public var attachment: Int = 0
    public var creating = false
    /// This Open already turned an attach that found nothing into a resume.
    public var resumedAfterAbsence = false
    /// Identifies one open, so a late answer for an earlier one is dropped.
    var openToken = UUID()

    public init(phase: Phase) { self.phase = phase }

    /// The run may still be on the host: a close stops it there.
    var mayBeRunning: Bool {
        switch phase {
        case .connected, .checking, .disconnected, .unknown, .stopping, .stopFailed: handle != nil
        case .opening, .failedToStart, .exitedEarly: false
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
            "Left running: someone else is attached to it. Stop it under Sessions on \(host)."
        case .stopNotAcknowledged, .quitDeadline:
            couldNotStop(host, agent: agent, reason: detail ?? "the host didn't confirm the stop")
        }
    }

    /// The line under a left-running session in "Sessions on <host>".
    public static func leftRunningLine(_ host: String, reason: RemoteLeftRunningReason) -> String {
        switch reason {
        case .hostDidNotAnswer: "Left running: \(host) didn't answer when you closed it."
        case .anotherClientAttached: "Left running: someone else is attached to it."
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
