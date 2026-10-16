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
    /// Session ids with a run that is not Ended, as last read (for a row's
    /// menu, which is built synchronously).
    private var liveSessions: Set<String> = []

    init(sessions: RemoteSessions, availability: @escaping (Agent) -> LaunchAvailability,
         extraArgs: @escaping (Agent) -> [String]) {
        self.sessions = sessions; self.check = availability; self.extraArgs = extraArgs
        Task { [weak self] in await self?.refreshLiveSessions() }
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

    private func refreshLiveSessions() async {
        liveSessions = Set(await sessions.runs().filter { !$0.isEnded && $0.dismissedAt == nil }.compactMap(\.sessionID))
    }

    func open(agent: Agent, sessionID: String, resume: Bool, directory: String, resumeAnyway: Bool,
              startNew: Bool, resumeUnconfirmed: Bool) async throws -> RemoteOpenResult {
        let outcome = try await sessions.open(.init(agent: agent, sessionID: sessionID, mode: resume ? .resume : .new,
                                                    directory: directory, extraArguments: extraArgs(agent),
                                                    resumeAnyway: resumeAnyway, startNew: startNew,
                                                    resumeUnconfirmed: resumeUnconfirmed))
        await refreshLiveSessions()
        switch outcome {
        case .needsDecision(let checked):
            return .needsDecision(checked: checked)
        case .plan(let plan):
            // The terminal's working directory is this Mac's home: a remote
            // path never becomes a local cwd.
            return .plan(RemoteOpenPlan(handle: plan.handle, attachment: plan.attachment, creating: plan.creating,
                                        command: TerminalCommand(argv: plan.argv, cwd: NSHomeDirectory()),
                                        displayArgv: plan.agentArgv, evidenceDirectory: plan.evidenceDirectory,
                                        stage: plan.staged ? nil : plan.stage))
        }
    }

    func abandon(_ handle: String) async {
        do { try await sessions.abandon(handle, reason: "not started") } catch {
            TempleUILog.db.error("remote run not abandoned: \(error.localizedDescription, privacy: .public)")
        }
        await refreshLiveSessions()
    }

    func collect(_ handle: String) async -> RemoteLaunchOutcome {
        switch await sessions.collect(handle) {
        case .ok(let directory): .ok(directory: directory)
        case .failedCD(let directory): .failedCD(directory: directory)
        case .failedLaunch(let reason): .failedLaunch(reason)
        case .clientFailed(let line): .clientFailed(line)
        case .nothing: .nothing
        case .transport(let line): .transport(line)
        case .storage(let line): .storage(line)
        }
    }

    func diagnostics(_ handle: String) async -> String? { await sessions.diagnostics(handle) }

    func stage(_ name: String) async -> RemoteStageResult {
        switch await sessions.stage(name) {
        case .staged: .staged
        case .failed(let reason): .failed(reason)
        case .unknown(let reason): .unknown(reason)
        case .none: .none
        }
    }

    func markCreationUnproven(_ handle: String) async -> String? {
        do { return try await sessions.markCreationUnproven(handle) } catch {
            TempleUILog.db.error("remote run not marked unproven: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func discard(sessionID: String) async throws {
        try await sessions.dismiss(sessionID: sessionID)
        await refreshLiveSessions()
    }

    func exitCheck(_ handle: String) async -> RemoteLiveness {
        let liveness = await sessions.exitCheck(handle)
        await refreshLiveSessions()
        switch liveness {
        case .present: return .present
        case .absent: return .absent
        case .unknown(let reason, _): return .unknown(reason: reason)
        }
    }

    func attachment(of handle: String) async -> Int? { await sessions.run(handle)?.attachment }

    func stop(_ handle: String, fromAttachedTab: Bool) async throws -> RemoteStopResult {
        let record = try await sessions.stop(handle, fromAttachedTab: fromAttachedTab)
        await refreshLiveSessions()
        return Self.result(record)
    }

    static func result(_ record: RemoteSessions.StopRecord) -> RemoteStopResult {
        if let error = record.storageError { return .unrecorded(detail: error) }
        switch record.outcome {
        case .killed, .absent: return .stopped
        case .refused: return .leftRunning(.anotherClientAttached, detail: nil)
        case .unconfirmed(let reason, let reached):
            return .leftRunning(reached ? .stopNotAcknowledged : .hostDidNotAnswer, detail: reason)
        }
    }

    func leaveRunning(_ handle: String, reason: RemoteLeftRunningReason) async {
        do {
            try await sessions.leaveRunning(handle, reason: RemoteRun.LeftRunningReason(rawValue: reason.rawValue) ?? .hostDidNotAnswer)
        } catch {
            TempleUILog.db.error("left-running flag not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    func hasLiveRun(sessionID: String) -> Bool { liveSessions.contains(sessionID) }

    func liveRunHandle(sessionID: String) async -> String? { await sessions.liveRun(sessionID: sessionID)?.handle }

    func hasLiveMaster() async -> Bool { await sessions.hasLiveMaster() }

    func manualStopCommand(handle: String) -> String { RemoteSessions.manualStopCommand(handle: handle) }

    func trackedSessions() async -> (sessions: [RemoteTrackedSession], checked: Bool) {
        let answer = await sessions.trackedSessions()
        await refreshLiveSessions()
        return (answer.sessions.map { tracked in
            let state: RemoteTrackedSession.State
            switch tracked.state {
            case .present(let attached): state = .present(attached: attached > 0)
            case .unknown(let reason): state = .unknown(reason)
            }
            return RemoteTrackedSession(handle: tracked.run.handle, sessionID: tracked.run.sessionID, agent: tracked.run.agent,
                                        state: state,
                                        leftRunning: tracked.run.isLeftRunning
                                            ? tracked.run.leftRunningReason.flatMap { RemoteLeftRunningReason(rawValue: $0.rawValue) }
                                            : nil)
        }, answer.reachedHost)
    }

    func keep(_ handle: String) async {
        do { try await sessions.keep(handle) } catch {
            TempleUILog.db.error("left-running flag not cleared: \(error.localizedDescription, privacy: .public)")
        }
    }

    func contactLeftRunning() async -> Int? { await sessions.contactLeftRunning() }

    func noticeLeftRunning() async { try? await sessions.noticeLeftRunning() }

    func checkFolder(_ path: String) async -> RemoteFolderCheck {
        switch await sessions.checkFolder(path) {
        case .exists(let resolved): .exists(resolved: resolved)
        case .missing: .missing
        case .cannotEnter(let line): .cannotEnter(line)
        case .transport(let line): .transport(line)
        }
    }

    func retire() { sessions.retire() }
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
