import Foundation
import TempleCore

/// One host's sessions: which run an Open attaches to or creates, the
/// launch records, the exit check, the stop, and every durable write that
/// follows them (docs/designs/remote-ssh.md sections 3 to 5). The tab side
/// (headers, prompts, notices) lives in the app; everything the host says,
/// and what Temple concludes from it, is decided and written here.
///
/// The run row is written before anything spawns; a read or write that
/// fails refuses the open, never reads as "no run, mint another". Nothing
/// here kills a session without being asked to by a caller acting for the
/// user, and an unconfirmed stop is never retried.
@MainActor
public final class RemoteSessions {
    public let record: RemoteHostRecord
    public var host: HostID { record.host }

    /// What an Open needs to know about the agent, decided by the app.
    public struct OpenRequest: Sendable, Equatable {
        public enum Mode: Sendable, Equatable { case new, resume }
        public var agent: Agent
        public var sessionID: String
        public var mode: Mode
        /// The folder as the user named it, or the row's.
        public var directory: String
        /// Settings' extra arguments for this agent (they apply here too).
        public var extraArguments: [String]
        /// The user chose Resume anyway: a new run under a new handle,
        /// whatever the latest one's state; the old row is kept.
        public var resumeAnyway: Bool
        public init(agent: Agent, sessionID: String, mode: Mode, directory: String, extraArguments: [String] = [],
                    resumeAnyway: Bool = false) {
            self.agent = agent; self.sessionID = sessionID; self.mode = mode; self.directory = directory
            self.extraArguments = extraArguments; self.resumeAnyway = resumeAnyway
        }
    }

    /// What an Open decided.
    public struct OpenPlan: Sendable, Equatable {
        public var handle: String
        public var attachment: Int
        /// A creation (`new-session`) rather than an attach.
        public var creating: Bool
        /// The local argv: the user's ssh, interactive, `TERM=xterm-256color`.
        public var argv: [String]
        /// The agent's own argv, for a failure header (never the wrapper).
        public var agentArgv: [String]
        /// The record the creation will write, recovered on a later Open
        /// if this one never collects it.
        public var directoryIntent: String
    }

    /// What the launch records said, once persisted.
    public enum Collected: Sendable, Equatable {
        /// The pane ran in this folder (its `pwd -P`).
        case ok(directory: String)
        /// The pane could not enter the folder; no agent ran.
        case failedCD(directory: String)
        /// The tmux client failed; creation is unproven, not disproven.
        case clientFailed(String)
        /// Nothing there (yet).
        case nothing
        case transport(String)
    }

    public enum OpenError: Error, LocalizedError, Equatable {
        case store(String)
        case refused(String)
        public var errorDescription: String? {
            switch self {
            case .store(let reason): "Temple couldn't record this session before starting it: \(reason)"
            case .refused(let reason): reason
            }
        }
    }

    private let storeProvider: () throws -> RemoteStateStore
    /// Whether the store's file exists; reads never create it.
    private let storeExists: () -> Bool
    private var openedStore: RemoteStateStore?
    private let keepAlive: KeepAlive
    private let stateDirectory: URL
    private let sshPath: String
    private let resolve: ([String]) async -> ConnectionTest.Resolution
    private let makeExec: (SSHConnection, String?) -> RemoteExec
    private let masterCheck: ([String]) async -> Bool
    private let now: () -> Date
    private let token: () -> String

    private var connection: SSHConnection?
    /// The remote PATH, memory only; resolved again after a transport failure.
    private var environment: RemoteEnvironment?

    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: String,
                store: @escaping () throws -> RemoteStateStore,
                storeExists: @escaping () -> Bool = { true },
                keepAlive: KeepAlive = TmuxKeepAlive(),
                resolve: @escaping ([String]) async -> ConnectionTest.Resolution = ConnectionTest.sshResolve,
                makeExec: @escaping (SSHConnection, String?) -> RemoteExec = { SSHExec(connection: $0, path: $1) },
                masterCheck: @escaping ([String]) async -> Bool = RemoteSessions.runMasterCheck,
                now: @escaping () -> Date = Date.init,
                token: @escaping () -> String = RemoteQuoting.nonce) {
        precondition(!record.host.isLocal)
        self.record = record
        self.stateDirectory = stateDirectory
        self.sshPath = sshPath
        storeProvider = store
        self.storeExists = storeExists
        self.keepAlive = keepAlive
        self.resolve = resolve
        self.makeExec = makeExec
        self.masterCheck = masterCheck
        self.now = now
        self.token = token
    }

    // MARK: Store

    /// The store, opened on first use: with no remote session ever opened,
    /// no file is created.
    public func store() throws -> RemoteStateStore {
        if let openedStore { return openedStore }
        let store = try storeProvider()
        openedStore = store
        return store
    }

    /// The store for a read: nil, rather than a new empty file, when there
    /// is none yet.
    private func readableStore() -> RemoteStateStore? {
        guard openedStore != nil || storeExists() else { return nil }
        return try? store()
    }

    public func liveRun(sessionID: String) -> RemoteRun? {
        try? readableStore()?.liveRun(host: host, sessionID: sessionID)
    }

    public func run(_ handle: String) -> RemoteRun? { try? readableStore()?.run(handle) }

    public func runs() -> [RemoteRun] { (try? readableStore()?.runs(host: host)) ?? [] }

    // MARK: Connection

    /// The connection, keyed by where `ssh -G` resolves the host (as the
    /// Test connection keys it), its socket directory prepared.
    public func resolvedConnection() async throws -> SSHConnection {
        if let connection { return connection }
        let provisional = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath)
        guard case .resolved(let values) = await resolve(provisional.resolutionArgv) else {
            throw OpenError.refused("ssh couldn't read its configuration for \(record.name).")
        }
        let resolved = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath, resolved: values)
        try resolved.prepareSocketDirectory()
        SocketHygiene.removeIfNothingListens(resolved.controlPath)
        connection = resolved
        return resolved
    }

    /// A query exec with the resolved PATH, resolving it first when Temple
    /// has none (one environment policy, section 2).
    func queryExec() async throws -> RemoteExec {
        let connection = try await resolvedConnection()
        if environment == nil {
            let resolved = await RemoteEnvironment.resolve(using: makeExec(connection, nil))
            if resolved.reachedHost { environment = resolved }
        }
        return makeExec(connection, environment?.path)
    }

    /// A transport failure: the next query resolves the PATH again.
    func transportFailed() { environment = nil }

    /// Whether a master answers on Temple's socket for this host (`ssh -O
    /// check`, local). Quit asks it before stopping anything there.
    public func hasLiveMaster() async -> Bool {
        guard let connection = try? await resolvedConnection() else { return false }
        return await masterCheck(connection.masterCheckArgv)
    }

    public nonisolated static func runMasterCheck(_ argv: [String]) async -> Bool {
        (try? await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: 3))?.status == 0
    }

    // MARK: Open

    /// Decides attach or create from the run's state, recovers an
    /// uncollected record first, and writes the run row before returning
    /// the command. Attach-only for every run that is not Ended: Temple
    /// never creates from a state where the original may still be running.
    public func open(_ request: OpenRequest) async throws -> OpenPlan {
        guard RemoteQuoting.isSafeToken(request.sessionID) else { throw OpenError.refused("This session id can't be sent to a host.") }
        if request.agent == .codex, request.mode == .new {
            throw OpenError.refused("Temple can't start new Codex sessions on \(record.name) yet.")
        }
        let connection = try await resolvedConnection()
        let store: RemoteStateStore
        let live: RemoteRun?
        do {
            store = try self.store()
            live = try store.liveRun(host: host, sessionID: request.sessionID)
        } catch {
            throw OpenError.store(error.localizedDescription)
        }
        if var run = live, !request.resumeAnyway {
            // An `ok` written but never collected is recovered before the attach.
            if run.creation == nil || run.creation == .unproven {
                if case .failedCD = await collect(run.handle) {
                    // Never created: a new run, as the request says.
                    return try await create(request, connection: connection, store: store,
                                            resume: request.mode == .resume)
                }
                run = (try? store.run(run.handle)) ?? run
            }
            guard let attachment = try? store.update(run.handle, { row in
                row.attachment += 1
                // Open clears the left-running flag (state table).
                row.leftRunningAt = nil
                row.leftRunningReason = nil
                row.leftRunningNoticedAt = nil
            })?.attachment else { throw OpenError.store("the run could not be updated") }
            let plan = RemoteLaunchPlan(handle: run.handle, marker: run.recordPath, directory: run.directoryIntent,
                                        agentArgv: [], path: environment?.path, socket: run.socketPath)
            return OpenPlan(handle: run.handle, attachment: attachment, creating: false,
                            argv: localArgv(connection, keepAlive.attachCommand(plan)),
                            agentArgv: agentArgv(run.agent, sessionID: request.sessionID, resume: run.mode == .resume,
                                                 extra: request.extraArguments),
                            directoryIntent: run.directoryIntent)
        }
        // The app says new or resume: it knows whether the tab ever sent
        // the agent anything (a Claude session with no input has no
        // transcript to resume, and keeps its minted id).
        return try await create(request, connection: connection, store: store, resume: request.mode == .resume)
    }

    private func create(_ request: OpenRequest, connection: SSHConnection, store: RemoteStateStore,
                        resume: Bool) async throws -> OpenPlan {
        let handle = token()
        let marker = "r-" + token()
        let argv = agentArgv(request.agent, sessionID: request.sessionID, resume: resume, extra: request.extraArguments)
        let run = RemoteRun(handle: handle, host: host, agent: request.agent, mode: resume ? .resume : .new,
                            directoryIntent: request.directory, sessionID: request.sessionID,
                            recordPath: marker, startedAt: now())
        do { try store.insert(run) } catch { throw OpenError.store(error.localizedDescription) }
        let plan = RemoteLaunchPlan(handle: handle, marker: marker, directory: request.directory, agentArgv: argv,
                                    path: environment?.path, socket: nil)
        return OpenPlan(handle: handle, attachment: run.attachment, creating: true,
                        argv: localArgv(connection, keepAlive.createCommand(plan)), agentArgv: argv,
                        directoryIntent: request.directory)
    }

    /// `/usr/bin/env TERM=xterm-256color ssh -t <arguments> -- <name> <remote>`:
    /// Temple's own terminal is `xterm-ghostty`, which a stock host has no
    /// terminfo for; the tmux client sees xterm-256color, the pane
    /// tmux-256color.
    private func localArgv(_ connection: SSHConnection, _ remote: String) -> [String] {
        ["/usr/bin/env", "TERM=xterm-256color"] + connection.argv(.interactive, remoteCommand: remote)
    }

    /// The agent's argv, `exec`ed by the pane: the binary by name on the
    /// resolved PATH (this Mac's detected path never reaches a host), the
    /// extra arguments, then the session.
    func agentArgv(_ agent: Agent, sessionID: String, resume: Bool, extra: [String]) -> [String] {
        let tail: [String]
        switch (agent, resume) {
        case (.claude, false): tail = ["--session-id", sessionID]
        case (.claude, true): tail = ["--resume", sessionID]
        case (.codex, _): tail = ["resume", sessionID]
        }
        return [agent.binaryName] + extra + tail
    }

    /// An open that was planned but never spawned (the tab closed, the
    /// spawn failed): no session was created, so the run is over.
    public func abandon(_ handle: String, reason: String) {
        _ = try? store().update(handle) { run in
            guard run.creation == nil, run.attachment == 1 else { return }
            run.creation = .failed
            run.failure = reason
            run.endedAt = self.now()
        }
    }

    // MARK: Records

    /// Fetches the run's records by their persisted name, writes the
    /// evidence, and only then acknowledges (deletes) them on the host.
    public func collect(_ handle: String) async -> Collected {
        guard let run = run(handle) else { return .nothing }
        if run.creation == .proven, let directory = run.directory { return .ok(directory: directory) }
        let records: CollectedRecords
        do {
            records = try await LaunchRecords.fetch(marker: run.recordPath, using: try await queryExec())
        } catch {
            transportFailed()
            return .transport(error.localizedDescription)
        }
        switch records.pane {
        case .ok(let evidence)?:
            let written = try? store().update(handle) { row in
                row.directory = evidence.directory
                row.okAt = evidence.epoch
                row.panePID = evidence.panePID
                row.paneStart = evidence.paneStart
                row.socketPath = evidence.socketPath
                row.serverPID = evidence.serverPID
                row.serverStart = evidence.serverStart
                row.creation = .proven
            }
            if written != nil, let exec = try? await queryExec() {
                await LaunchRecords.acknowledge(marker: run.recordPath, using: exec)
            }
            return .ok(directory: evidence.directory)
        case .failedCD?:
            let written = try? store().update(handle) { row in
                row.creation = .failed
                row.failure = "cd"
                row.endedAt = self.now()
            }
            if written != nil, let exec = try? await queryExec() {
                await LaunchRecords.acknowledge(marker: run.recordPath, using: exec)
            }
            return .failedCD(directory: run.directoryIntent)
        case .unreadable(let line)?:
            return .transport("the launch record could not be read: \(line)")
        case nil:
            if let client = records.client {
                _ = try? store().update(handle) { row in
                    if row.creation == nil { row.creation = .unproven }
                    row.failure = client.line.isEmpty ? "tmux exited with status \(client.status)" : client.line
                }
                return .clientFailed(client.line)
            }
            return .nothing
        }
    }

    /// A creation whose tab ended with nothing collected: unproven, so
    /// every later Open is attach-only.
    public func markCreationUnproven(_ handle: String) {
        _ = try? store().update(handle) { row in
            if row.creation == nil { row.creation = .unproven }
        }
    }

    // MARK: Exit check

    /// `has-session` on the pinned socket. Only a positive absence ends the
    /// run (written here, durably); the caller drops the answer if the
    /// attachment moved on.
    public func exitCheck(_ handle: String) async -> Liveness {
        guard let run = run(handle) else { return .unknown(reason: "Temple has no record of this session", socketMissing: false) }
        let exec: RemoteExec
        do { exec = try await queryExec() } catch {
            return .unknown(reason: error.localizedDescription, socketMissing: false)
        }
        let liveness = await keepAlive.liveness(session: run.sessionName, socket: run.socketPath, using: exec)
        if case .absent = liveness {
            _ = try? store().update(handle) { row in
                guard row.endedAt == nil else { return }
                row.endedAt = self.now()
                row.endEvidence = .absent
                row.leftRunningAt = nil
                row.leftRunningReason = nil
            }
        } else if case .unknown(_, false) = liveness {
            transportFailed()
        }
        return liveness
    }

    // MARK: Stop

    /// The one-command, attached-checked stop. `fromAttachedTab`: Temple's
    /// own client was just detached on this side, and the host waits up to
    /// three seconds for it to leave before the check (note 4). The outcome
    /// is written here whether or not a tab still exists to show it; a
    /// cancelled stop (the quit's deadline) writes nothing, for its caller
    /// records why.
    public func stop(_ handle: String, fromAttachedTab: Bool) async -> StopOutcome {
        guard let run = run(handle) else { return .unconfirmed(reason: "Temple has no record of this session", reachedHost: false) }
        let exec: RemoteExec
        do { exec = try await queryExec() } catch {
            let outcome = StopOutcome.unconfirmed(reason: error.localizedDescription, reachedHost: false)
            record(outcome, for: handle)
            return outcome
        }
        let outcome = await keepAlive.stop(session: run.sessionName, socket: run.socketPath,
                                           waitTenths: fromAttachedTab ? 30 : 0, using: exec)
        guard !Task.isCancelled else { return outcome }
        record(outcome, for: handle)
        return outcome
    }

    /// The durable completion of a stop.
    public func record(_ outcome: StopOutcome, for handle: String) {
        switch outcome {
        case .killed, .absent:
            _ = try? store().update(handle) { row in
                guard row.endedAt == nil else { return }
                row.endedAt = self.now()
                row.endEvidence = outcome == .killed ? .killed : .absent
                row.leftRunningAt = nil
                row.leftRunningReason = nil
            }
        case .refused:
            leaveRunning(handle, reason: .anotherClientAttached)
        case .unconfirmed(_, let reached):
            if !reached { transportFailed() }
            leaveRunning(handle, reason: reached ? .stopNotAcknowledged : .hostDidNotAnswer)
        }
    }

    /// A stop Temple could not carry out and confirm: the session is left
    /// running, with the reason, and listed for the user. Nothing follows.
    public func leaveRunning(_ handle: String, reason: RemoteRun.LeftRunningReason) {
        _ = try? store().update(handle) { row in
            guard row.endedAt == nil else { return }
            row.leftRunningAt = self.now()
            row.leftRunningReason = reason
            row.leftRunningNoticedAt = nil
        }
    }

    /// Keep, in "Sessions on <host>": the flag goes; the session is an
    /// ordinary detached one (fable must-fix 6).
    public func keep(_ handle: String) {
        _ = try? store().update(handle) { row in
            row.leftRunningAt = nil
            row.leftRunningReason = nil
        }
    }

    /// The sidebar's line for these flags was dismissed or acted on.
    public func noticeLeftRunning() {
        let now = now()
        for run in (try? readableStore()?.leftRunning(host: host)) ?? [] where run.leftRunningNoticedAt == nil {
            _ = try? store().update(run.handle) { $0.leftRunningNoticedAt = now }
        }
    }

    /// Runs flagged left running whose flag the sidebar has not shown yet.
    public func unnoticedLeftRunning() -> [RemoteRun] {
        ((try? readableStore()?.leftRunning(host: host)) ?? []).filter { $0.leftRunningNoticedAt == nil }
    }

    // MARK: Sessions on the host

    public struct Listed: Sendable, Equatable {
        public var name: String
        public var attached: Int
        /// The run Temple has under this name, if any ("Not in Temple" otherwise).
        public var run: RemoteRun?
    }

    public enum Listing: Sendable, Equatable {
        case sessions([Listed])
        case noServer
        case failed(String)
    }

    /// The sessions on Temple's private server, mapped to runs. Only the
    /// `-L temple` server is asked; the user's own tmux never is. A flagged
    /// run whose server answered without it is positively absent there.
    public func listSessions() async -> Listing {
        let exec: RemoteExec
        do { exec = try await queryExec() } catch { return .failed(error.localizedDescription) }
        switch await keepAlive.list(using: exec) {
        case .failed(let line):
            transportFailed()
            return .failed(line)
        case .noServer:
            return .noServer
        case .listed(let entries):
            let runs = self.runs()
            let byName = Dictionary(runs.map { ($0.sessionName, $0) }, uniquingKeysWith: { _, last in last })
            let names = Set(entries.map(\.name))
            let defaultSocket = runs.compactMap(\.socketPath).first
            for run in runs where run.isLeftRunning && !names.contains(run.sessionName)
                && (run.socketPath == nil || run.socketPath == defaultSocket) {
                // Listed by the server it was created on, and not there.
                _ = try? store().update(run.handle) { row in
                    guard row.endedAt == nil else { return }
                    row.endedAt = self.now(); row.endEvidence = .absent
                    row.leftRunningAt = nil; row.leftRunningReason = nil
                }
            }
            return .sessions(entries.map { Listed(name: $0.name, attached: $0.attached, run: byName[$0.name]) })
        }
    }

    /// Stop, from the sheet or a row's menu: no Temple client is attached
    /// (`<n>` = 0). A session with no run ("Not in Temple") is stopped by
    /// its exact name on Temple's private server and nothing is written.
    public func stopListed(_ name: String) async -> StopOutcome {
        if let run = runs().last(where: { $0.sessionName == name && !$0.isEnded }) {
            return await stop(run.handle, fromAttachedTab: false)
        }
        guard RemoteQuoting.isSafeToken(name) else {
            return .unconfirmed(reason: "Temple can't name this session safely", reachedHost: false)
        }
        do {
            return await keepAlive.stop(session: name, socket: nil, waitTenths: 0, using: try await queryExec())
        } catch {
            return .unconfirmed(reason: error.localizedDescription, reachedHost: false)
        }
    }

    /// The folder sheet's advisory check.
    public func checkFolder(_ path: String) async -> FolderCheck {
        do { return await FolderCheck.run(path, using: try await queryExec()) } catch {
            return .transport(error.localizedDescription)
        }
    }

    /// The command that stops a session from the host itself, for copy.
    public nonisolated static func manualStopCommand(handle: String) -> String {
        "tmux -L temple kill-session -t temple-\(handle)"
    }
}
