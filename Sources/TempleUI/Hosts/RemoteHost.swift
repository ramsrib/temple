import Foundation
import TempleCore
import TempleRemoteHost
import TempleTerminalAPI

// The one place TempleUI names `TempleRemoteHost` (docs/designs/
// remote-ssh.md section 6; `ModuleBoundaryTests` asserts it). The rest of
// the app reaches a remote host through `HostRegistry`, and the Hosts
// connection manager through the names below. Deleting remote means
// deleting the module, this file, the Hosts views and `RemoteHostsModel`.

typealias RemoteHostRecord = TempleRemoteHost.RemoteHostRecord
typealias RemoteHostList = TempleRemoteHost.RemoteHostList
typealias RemoteHostForm = TempleRemoteHost.RemoteHostForm
typealias HostTestSummary = TempleRemoteHost.HostTestSummary
typealias ConnectionTest = TempleRemoteHost.ConnectionTest
typealias SSHFailure = TempleRemoteHost.SSHFailure
typealias RemoteHostFormField = TempleRemoteHost.RemoteHostForm.Field
typealias ConnectionCheckRow = TempleRemoteHost.ConnectionTest.Row

extension HostRegistry.Entry {
    /// An enabled host's entry, registered whether or not it was tested.
    /// Its source reads nothing yet (enrichment is phase 2); its launcher
    /// runs sessions there under the hidden tmux server.
    @MainActor static func remote(_ record: RemoteHostRecord,
                                  availability: @escaping (Agent) -> LaunchAvailability,
                                  extraArgs: @escaping (Agent) -> [String] = { _ in [] },
                                  stateDirectory: URL = TempleState.directory) -> HostRegistry.Entry {
        let sessions = RemoteSessions(record: record, stateDirectory: stateDirectory,
                                      sshPath: RemoteHostComposition.sshPath,
                                      store: { try RemoteHostComposition.store(in: stateDirectory) },
                                      storeExists: { RemoteHostComposition.storeExists(in: stateDirectory) })
        return HostRegistry.Entry(source: RemoteSessionSource(host: record.host),
                                  launcher: RemoteHostLauncher(sessions: sessions, availability: availability,
                                                               extraArgs: extraArgs))
    }
}

/// A host's launcher: every open, exit, close and stop of a session there,
/// through the host's `RemoteSessions`. `availability` is the last test's
/// proof (`.unavailable` only when a test connected and a CLI or tmux did
/// not run); new Codex sessions wait for phase 1b.
@MainActor
final class RemoteHostLauncher: RemoteSessionHost {
    let sessions: RemoteSessions
    private let check: (Agent) -> LaunchAvailability
    private let extraArgs: (Agent) -> [String]

    init(sessions: RemoteSessions, availability: @escaping (Agent) -> LaunchAvailability,
         extraArgs: @escaping (Agent) -> [String]) {
        self.sessions = sessions; self.check = availability; self.extraArgs = extraArgs
    }

    var host: HostID { sessions.host }
    var hostName: String { sessions.record.name }

    func availability(_ agent: Agent) -> LaunchAvailability {
        if agent == .codex { return .unavailable(reason: RemoteCopy.newCodexWaits(hostName)) }
        return check(agent)
    }

    /// Remote tabs open asynchronously (`open`); this synchronous path is
    /// never taken for them.
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        throw HostLaunchError.preparation("Temple opens sessions on \(hostName) asynchronously.")
    }

    func open(agent: Agent, sessionID: String, resume: Bool, directory: String,
              resumeAnyway: Bool) async throws -> RemoteOpenPlan {
        let plan = try await sessions.open(.init(agent: agent, sessionID: sessionID, mode: resume ? .resume : .new,
                                                 directory: directory, extraArguments: extraArgs(agent),
                                                 resumeAnyway: resumeAnyway))
        // The terminal's working directory is this Mac's home: a remote path
        // never becomes a local cwd.
        return RemoteOpenPlan(handle: plan.handle, attachment: plan.attachment, creating: plan.creating,
                              command: TerminalCommand(argv: plan.argv, cwd: NSHomeDirectory()),
                              displayArgv: plan.agentArgv)
    }

    func abandon(_ handle: String) { sessions.abandon(handle, reason: "not started") }

    func collect(_ handle: String) async -> RemoteLaunchOutcome {
        switch await sessions.collect(handle) {
        case .ok(let directory): .ok(directory: directory)
        case .failedCD(let directory): .failedCD(directory: directory)
        case .clientFailed(let line): .clientFailed(line)
        case .nothing: .nothing
        case .transport(let line): .transport(line)
        }
    }

    func markCreationUnproven(_ handle: String) { sessions.markCreationUnproven(handle) }

    func exitCheck(_ handle: String) async -> RemoteLiveness {
        switch await sessions.exitCheck(handle) {
        case .present: .present
        case .absent: .absent
        case .unknown(let reason, _): .unknown(reason: reason)
        }
    }

    func attachment(of handle: String) -> Int? { sessions.run(handle)?.attachment }

    func stop(_ handle: String, fromAttachedTab: Bool) async -> RemoteStopResult {
        Self.result(await sessions.stop(handle, fromAttachedTab: fromAttachedTab))
    }

    static func result(_ outcome: StopOutcome) -> RemoteStopResult {
        switch outcome {
        case .killed, .absent: .stopped
        case .refused: .leftRunning(.anotherClientAttached, detail: nil)
        case .unconfirmed(let reason, let reached):
            .leftRunning(reached ? .stopNotAcknowledged : .hostDidNotAnswer, detail: reason)
        }
    }

    func leaveRunning(_ handle: String, reason: RemoteLeftRunningReason) {
        sessions.leaveRunning(handle, reason: RemoteRun.LeftRunningReason(rawValue: reason.rawValue) ?? .hostDidNotAnswer)
    }

    func liveRun(sessionID: String) -> RemoteRunSummary? {
        sessions.liveRun(sessionID: sessionID).map { RemoteRunSummary(handle: $0.handle, leftRunning: $0.isLeftRunning) }
    }

    func hasLiveMaster() async -> Bool { await sessions.hasLiveMaster() }

    func manualStopCommand(handle: String) -> String { RemoteSessions.manualStopCommand(handle: handle) }

    func listSessions() async -> RemoteSessionListing {
        switch await sessions.listSessions() {
        case .noServer: return .noServer
        case .failed(let line): return .failed(line)
        case .sessions(let listed):
            return .sessions(listed.map { entry in
                RemoteListedSession(name: entry.name, attached: entry.attached > 0, handle: entry.run?.handle,
                                    sessionID: entry.run?.sessionID,
                                    leftRunning: entry.run.flatMap { run in
                                        run.isLeftRunning ? run.leftRunningReason.flatMap { RemoteLeftRunningReason(rawValue: $0.rawValue) } : nil
                                    })
            })
        }
    }

    func stopListed(_ name: String) async -> RemoteStopResult { Self.result(await sessions.stopListed(name)) }

    func keep(_ handle: String) { sessions.keep(handle) }

    func unnoticedLeftRunningCount() -> Int { sessions.unnoticedLeftRunning().count }

    func noticeLeftRunning() { sessions.noticeLeftRunning() }

    func checkFolder(_ path: String) async -> RemoteFolderCheck {
        switch await sessions.checkFolder(path) {
        case .exists(let resolved): .exists(resolved: resolved)
        case .missing: .missing
        case .cannotEnter(let line): .cannotEnter(line)
        case .transport(let line): .transport(line)
        }
    }
}

/// Remote project masks and order in `remote-state.sqlite`.
@MainActor
final class RemoteProjectStateStore: RemoteProjectStatePersisting {
    private let stateDirectory: URL
    init(stateDirectory: URL) { self.stateDirectory = stateDirectory }

    private var store: RemoteStateStore? { try? RemoteHostComposition.store(in: stateDirectory) }

    /// Reading creates no file: with none yet there is nothing to read.
    func projectStates() -> [(key: ProjectKey, archived: Bool, position: Int?)] {
        guard RemoteHostComposition.storeExists(in: stateDirectory) else { return [] }
        return ((try? store?.projectStates()) ?? []).map { (ProjectKey(host: $0.host, path: $0.path), $0.archived, $0.position) }
    }

    func setArchived(_ archived: Bool, key: ProjectKey) {
        do { try store?.setProjectArchived(archived, host: key.host, path: key.path) } catch {
            TempleUILog.db.error("remote project state not written: \(String(describing: error), privacy: .public)")
        }
    }

    func setOrder(_ keys: [(key: ProjectKey, position: Int)]) {
        // Positions are places in the whole list, not among hosts' alone.
        do { try store?.setProjectOrder(keys.map { ($0.key.host, $0.key.path, $0.position) }) } catch {
            TempleUILog.db.error("remote project order not written: \(String(describing: error), privacy: .public)")
        }
    }
}

enum RemoteHostComposition {
    /// Every process the remote module has started in this process.
    static var processLaunches: Int { RemoteProcessCounter.launches }

    /// `remote-state.sqlite`, one per state directory, opened on first
    /// use: with the feature off, or no session on a host ever opened, no
    /// file is created.
    @MainActor private static var stores: [URL: RemoteStateStore] = [:]
    @MainActor static func storeExists(in directory: URL) -> Bool {
        stores[directory.standardizedFileURL] != nil
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(RemoteStateStore.fileName).path)
    }

    @MainActor static func store(in directory: URL) throws -> RemoteStateStore {
        if let store = stores[directory.standardizedFileURL] { return store }
        let store = try RemoteStateStore(directory: directory)
        stores[directory.standardizedFileURL] = store
        return store
    }

    /// The aliases in the user's `~/.ssh/config`, read-only, one level of
    /// `Include`. Called only by the Hosts connection manager, and only
    /// while the feature is on.
    static func configAliases() -> [String] {
        let ssh = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
        return SSHConfigHosts.load(configURL: ssh.appendingPathComponent("config"), sshDirectory: ssh)
    }

    /// The user's ssh: the login shell's, else the system's.
    static var sshPath: String { LoginShellEnvironment.locate("ssh") ?? "/usr/bin/ssh" }

    /// A Test connection for `record`, over `sshPath` (the user's ssh), with
    /// its master socket under `stateDirectory`. Every check rides that
    /// master and nothing else (`.overMaster`).
    @MainActor
    static func connectionTest(for record: RemoteHostRecord, stateDirectory: URL,
                               sshPath: String = RemoteHostComposition.sshPath) -> ConnectionTest {
        ConnectionTest(record: record, stateDirectory: stateDirectory, sshPath: sshPath,
                       makeExec: { SSHExec(connection: $0, path: $1, purpose: .overMaster) })
    }
}
