import Foundation
import TempleCore

/// One host's sessions: which run an Open attaches to or creates, the
/// launch records, the exit check, the stop, and every durable write that
/// follows them (docs/designs/remote-ssh.md sections 3 to 5). The tab side
/// (headers, prompts, notices) lives in the app; everything the host says,
/// and what Temple concludes from it, is decided and written here.
///
/// - The run row is written before anything spawns; a read or write that
///   fails refuses the open, never reads as "no run, mint another". The
///   ordinary find-or-reserve is one immediate transaction across processes.
/// - Store work runs off the main actor; a write that fails is reported,
///   never reported as success.
/// - Only tracked runs are ever asked about, each on its own pinned server;
///   nothing is discovered, and nothing Temple did not start is stopped.
/// - Nothing here kills a session without being asked to by a caller acting
///   for the user, and an unconfirmed stop is never retried.
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
        /// The user chose Start a new session for a session whose
        /// conversation was never confirmed: a new run with the same id,
        /// started fresh, never resumed.
        public var startNew: Bool
        public init(agent: Agent, sessionID: String, mode: Mode, directory: String, extraArguments: [String] = [],
                    resumeAnyway: Bool = false, startNew: Bool = false) {
            self.agent = agent; self.sessionID = sessionID; self.mode = mode; self.directory = directory
            self.extraArguments = extraArguments; self.resumeAnyway = resumeAnyway; self.startNew = startNew
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
        public var directoryIntent: String
        /// An attach to a run whose creation evidence was persisted: the
        /// folder its pane reported, replayed into the row and tab.
        public var evidenceDirectory: String?
    }

    public enum OpenOutcome: Sendable, Equatable {
        case plan(OpenPlan)
        /// The session's last run ended with its conversation unconfirmed:
        /// the user chooses Start a new session or Discard.
        case needsDecision
    }

    /// What the launch records said, once persisted.
    public enum Collected: Sendable, Equatable {
        /// The pane ran in this folder (its `pwd -P`), recorded.
        case ok(directory: String)
        /// The pane could not enter the folder; no agent ran. Recorded.
        case failedCD(directory: String)
        /// The tmux client failed; creation is unproven, not disproven.
        case clientFailed(String)
        /// Nothing there (yet).
        case nothing
        case transport(String)
        /// The host's answer could not be written here: nothing acknowledged.
        case storage(String)
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

    /// A stop's decoded outcome and whether it was written.
    public struct StopRecord: Sendable, Equatable {
        public var outcome: StopOutcome
        /// Why the outcome could not be written, if it could not.
        public var storageError: String?
    }

    /// One tracked session as "Sessions on <host>" shows it.
    public struct Tracked: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case present(attached: Int)
            case unknown(String)
        }
        public var run: RemoteRun
        public var state: State
    }

    /// The remote PATH (section 2's one policy), memory only.
    public enum PathState: Sendable, Equatable {
        /// No query has reached the host since the last transport failure.
        case unresolved
        case resolved(String)
        /// Resolution ran on the host and found no PATH: ssh's default
        /// environment, for the checks and the launch alike.
        case fallback(String)
    }

    private let storeProvider: () throws -> RemoteStateStore
    /// Whether the store's file exists; reads never create it.
    private let storeExists: () -> Bool
    private var openedStore: RemoteStateStore?
    private let keepAlive: KeepAlive
    private let stateDirectory: URL
    private let sshPath: () -> String
    private let resolve: ([String]) async -> ConnectionTest.Resolution
    private let makeExec: (SSHConnection, String?) -> RemoteExec
    private let masterCheck: ([String]) async -> Bool
    private let now: () -> Date
    private let token: () -> String

    private var connection: SSHConnection?
    public private(set) var pathState: PathState = .unresolved
    /// The host was removed or edited: nothing here runs again.
    public private(set) var retired = false

    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: @autoclosure @escaping () -> String,
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

    /// The host was removed or its record edited: its connection and PATH
    /// are dropped and nothing here queries the host again. The caller
    /// cancels the tasks already running.
    public func retire() {
        retired = true
        connection = nil
        pathState = .unresolved
    }

    struct Retired: Error, LocalizedError {
        var errorDescription: String? { "the host's settings changed" }
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

    /// A store operation, off the main actor.
    func write<T: Sendable>(_ body: @escaping @Sendable (RemoteStateStore) throws -> T) async throws -> T {
        try await store().perform(body)
    }

    /// A read: nil, rather than a new empty file, when there is none yet.
    func read<T: Sendable>(_ body: @escaping @Sendable (RemoteStateStore) throws -> T) async -> T? {
        guard openedStore != nil || storeExists(), let store = try? store() else { return nil }
        return try? await store.perform(body)
    }

    public func liveRun(sessionID: String) async -> RemoteRun? {
        let host = host
        return await read { try $0.liveRun(host: host, sessionID: sessionID) } ?? nil
    }

    public func run(_ handle: String) async -> RemoteRun? { await read { try $0.run(handle) } ?? nil }

    public func runs() async -> [RemoteRun] {
        let host = host
        return await read { try $0.runs(host: host) } ?? []
    }

    // MARK: Connection

    /// The connection, keyed by where `ssh -G` resolves the host (as the
    /// Test connection keys it), its socket directory prepared. `refresh`
    /// (explicit opens and contacts) asks `ssh -G` again: an alias
    /// retargeted in `~/.ssh/config` gets a new connection and its PATH is
    /// resolved again.
    public func resolvedConnection(refresh: Bool = false) async throws -> SSHConnection {
        guard !retired else { throw Retired() }
        if !refresh, let connection { return connection }
        let provisional = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath())
        let answer = await resolve(provisional.resolutionArgv)
        guard !retired else { throw Retired() }
        guard case .resolved(let values) = answer else {
            throw OpenError.refused("ssh couldn't read its configuration for \(record.name).")
        }
        let resolved = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath(), resolved: values)
        if let connection, connection == resolved { return connection }
        try resolved.prepareSocketDirectory()
        SocketHygiene.removeIfNothingListens(resolved.controlPath)
        if connection != nil { pathState = .unresolved }
        connection = resolved
        return resolved
    }

    /// A query exec with the PATH policy's answer, resolving it first when
    /// no query has reached the host yet.
    func queryExec(refresh: Bool = false) async throws -> RemoteExec {
        let connection = try await resolvedConnection(refresh: refresh)
        if case .unresolved = pathState {
            let resolved = await RemoteEnvironment.resolve(using: makeExec(connection, nil))
            guard !retired else { throw Retired() }
            if resolved.reachedHost {
                pathState = resolved.path.map(PathState.resolved) ?? .fallback(resolved.problem ?? "no PATH")
            }
        }
        if case .resolved(let path) = pathState { return makeExec(connection, path) }
        return makeExec(connection, nil)
    }

    /// A transport failure: the next query resolves the PATH again.
    func transportFailed() { pathState = .unresolved }

    var launchPath: RemoteLaunchPlan.Path {
        switch pathState {
        case .unresolved: .unresolved
        case .resolved(let path): .resolved(path)
        case .fallback: .fallback
        }
    }

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

    /// Decides attach or create from the run's state (one transaction),
    /// recovers an uncollected record first, and writes the run before
    /// returning the command. Attach-only for every run that is not Ended:
    /// Temple never creates from a state where the original may be running.
    public func open(_ request: OpenRequest) async throws -> OpenOutcome {
        guard RemoteQuoting.isSafeToken(request.sessionID) else { throw OpenError.refused("This session id can't be sent to a host.") }
        if request.agent == .codex, request.mode == .new || request.startNew {
            throw OpenError.refused("Temple can't start new Codex sessions on \(record.name) yet.")
        }
        let connection = try await resolvedConnection(refresh: true)
        let resume = request.mode == .resume && !request.startNew
        let candidate = newRun(request, resume: resume)
        if request.resumeAnyway || request.startNew {
            // Explicit choices, never the ordinary reservation.
            do { try await write { try $0.insert(candidate) } } catch { throw OpenError.store(error.localizedDescription) }
            return .plan(createPlan(candidate, request: request, connection: connection))
        }
        return try await reserveAndPlan(request, candidate: candidate, connection: connection, recovering: true)
    }

    private func reserveAndPlan(_ request: OpenRequest, candidate: RemoteRun, connection: SSHConnection,
                                recovering: Bool) async throws -> OpenOutcome {
        let reservation: RemoteStateStore.Reservation
        do { reservation = try await write { try $0.reserve(candidate, allowUnconfirmed: false) } } catch {
            throw OpenError.store(error.localizedDescription)
        }
        switch reservation {
        case .needsDecision:
            return .needsDecision
        case .created(let run):
            return .plan(createPlan(run, request: request, connection: connection))
        case .existing(var run):
            // An `ok` written but never collected is recovered before the attach.
            if recovering, run.creation == nil || run.creation == .unproven {
                switch await collect(run.handle) {
                case .failedCD:
                    // Never created: reserve again, which now creates.
                    return try await reserveAndPlan(request, candidate: newRun(request, resume: candidate.mode == .resume),
                                                    connection: connection, recovering: false)
                case .storage(let reason):
                    throw OpenError.store(reason)
                default:
                    run = await self.run(run.handle) ?? run
                }
            }
            let plan = RemoteLaunchPlan(handle: run.handle, marker: marker(run), directory: run.directoryIntent,
                                        agentArgv: [], path: launchPath, socket: run.socketPath)
            return .plan(OpenPlan(handle: run.handle, attachment: run.attachment, creating: false,
                                  argv: localArgv(connection, keepAlive.attachCommand(plan)),
                                  agentArgv: agentArgv(run.agent, sessionID: request.sessionID, resume: run.mode == .resume,
                                                       extra: request.extraArguments),
                                  directoryIntent: run.directoryIntent,
                                  evidenceDirectory: run.creation == .proven ? run.directory : nil))
        }
    }

    private func newRun(_ request: OpenRequest, resume: Bool) -> RemoteRun {
        let marker = "r-" + token()
        var run = RemoteRun(handle: token(), host: host, agent: request.agent, mode: resume ? .resume : .new,
                            directoryIntent: request.directory, sessionID: request.sessionID,
                            recordPath: RecordDirectory.locator(marker: marker), startedAt: now())
        run.conversation = resume ? .confirmed : .unconfirmed
        return run
    }

    private func createPlan(_ run: RemoteRun, request: OpenRequest, connection: SSHConnection) -> OpenPlan {
        let argv = agentArgv(run.agent, sessionID: request.sessionID, resume: run.mode == .resume,
                             extra: request.extraArguments)
        let plan = RemoteLaunchPlan(handle: run.handle, marker: marker(run), directory: run.directoryIntent,
                                    agentArgv: argv, path: launchPath, socket: nil)
        return OpenPlan(handle: run.handle, attachment: run.attachment, creating: true,
                        argv: localArgv(connection, keepAlive.createCommand(plan)), agentArgv: argv,
                        directoryIntent: run.directoryIntent, evidenceDirectory: nil)
    }

    /// The marker the run's persisted locator names.
    private func marker(_ run: RemoteRun) -> String {
        RecordDirectory.marker(from: run.recordPath) ?? "invalid"
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
    /// spawn failed, the host changed): no session was created.
    public func abandon(_ handle: String, reason: String) async throws {
        let now = now()
        try await write {
            try $0.update(handle) { run in
                guard run.creation == nil, run.attachment == 1 else { return }
                run.creation = .failed
                run.failure = reason
                run.endedAt = now
            }
        }
    }

    // MARK: Records

    /// Fetches the run's records by their persisted locator, writes the
    /// evidence, and only then acknowledges (deletes) them on the host. A
    /// write that fails is `.storage`, and nothing is acknowledged.
    public func collect(_ handle: String) async -> Collected {
        guard let run = await run(handle) else { return .nothing }
        if run.creation == .proven, let directory = run.directory { return .ok(directory: directory) }
        if run.creation == .failed, run.failure == "cd" { return .failedCD(directory: run.directoryIntent) }
        let marker = marker(run)
        let records: CollectedRecords
        let exec: RemoteExec
        do {
            exec = try await queryExec()
            records = try await LaunchRecords.fetch(marker: marker, using: exec)
        } catch {
            if case LaunchRecords.FetchError.transport? = error as? LaunchRecords.FetchError { transportFailed() }
            return .transport(error.localizedDescription)
        }
        let now = now()
        switch records.pane {
        case .ok(let evidence)?:
            do {
                try await write {
                    try $0.update(handle) { row in
                        row.directory = evidence.directory
                        row.okAt = evidence.epoch
                        row.panePID = evidence.panePID
                        row.paneStart = evidence.paneStart
                        row.socketPath = evidence.socketPath
                        row.serverPID = evidence.serverPID
                        row.serverStart = evidence.serverStart
                        row.creation = .proven
                    }
                }
            } catch {
                return .storage(error.localizedDescription)
            }
            await LaunchRecords.acknowledge(marker: marker, using: exec)
            return .ok(directory: evidence.directory)
        case .failedCD?:
            do {
                try await write {
                    try $0.update(handle) { row in
                        row.creation = .failed
                        row.failure = "cd"
                        row.endedAt = now
                    }
                }
            } catch {
                return .storage(error.localizedDescription)
            }
            await LaunchRecords.acknowledge(marker: marker, all: true, using: exec)
            return .failedCD(directory: run.directoryIntent)
        case .unreadable(let line)?:
            return .transport("the launch record could not be read: \(line)")
        case nil:
            if let client = records.client {
                let line = client.line.isEmpty ? "tmux exited with status \(client.status)" : client.line
                do {
                    try await write {
                        try $0.update(handle) { row in
                            if row.creation == nil { row.creation = .unproven }
                            row.failure = line
                        }
                    }
                } catch {
                    return .storage(error.localizedDescription)
                }
                return .clientFailed(client.line)
            }
            return .nothing
        }
    }

    /// What the pane showed, for an agent that ended at once: the end of
    /// its first 64 KiB, raw. Fetched once, then removed from the host.
    public func diagnostics(_ handle: String) async -> String? {
        guard let run = await run(handle), let exec = try? await queryExec(),
              let records = try? await LaunchRecords.fetch(marker: marker(run), using: exec) else { return nil }
        await LaunchRecords.acknowledge(marker: marker(run), all: true, using: exec)
        return records.output
    }

    /// A creation whose tab ended with nothing collected: unproven, so
    /// every later Open is attach-only.
    public func markCreationUnproven(_ handle: String) async throws {
        try await write { try $0.update(handle) { row in if row.creation == nil { row.creation = .unproven } } }
    }

    /// A Temple tab sent this run's agent something: the conversation exists.
    public func confirmConversation(_ handle: String) async throws {
        try await write { try $0.update(handle) { $0.conversation = .confirmed } }
    }

    /// Discard: none of the session's runs is attached to or resumed again.
    public func dismiss(sessionID: String) async throws {
        let host = host, now = now()
        try await write { try $0.dismiss(host: host, sessionID: sessionID, at: now) }
    }

    // MARK: Exit check

    /// `has-session` on the pinned socket. Only a positive absence ends the
    /// run, and only once that is written; the caller drops the answer if
    /// the attachment moved on.
    public func exitCheck(_ handle: String) async -> Liveness {
        guard let run = await run(handle) else { return .unknown(reason: "Temple has no record of this session", socketMissing: false) }
        let exec: RemoteExec
        do { exec = try await queryExec() } catch {
            return .unknown(reason: error.localizedDescription, socketMissing: false)
        }
        let liveness = await keepAlive.liveness(session: run.sessionName, socket: run.socketPath, using: exec)
        switch liveness {
        case .absent:
            do { try await markEnded(handle, evidence: .absent) } catch {
                return .unknown(reason: "Temple couldn't record that it ended: \(error.localizedDescription)", socketMissing: false)
            }
        case .unknown(_, false):
            transportFailed()
        default:
            break
        }
        return liveness
    }

    private func markEnded(_ handle: String, evidence: RemoteRun.EndEvidence) async throws {
        let now = now()
        try await write {
            try $0.update(handle) { row in
                guard row.endedAt == nil else { return }
                row.endedAt = now
                row.endEvidence = evidence
                row.leftRunningAt = nil
                row.leftRunningReason = nil
            }
        }
    }

    // MARK: Stop

    /// The one-command, attached-checked stop. `fromAttachedTab`: Temple's
    /// own client was just detached on this side, and the host waits up to
    /// three seconds for it to leave before the check (note 4). An answer
    /// that arrived is decoded and written whether or not anyone is still
    /// waiting (a cancellation after it arrived changes nothing); a query
    /// cancelled before any answer throws `CancellationError`, and its
    /// owner records why.
    public func stop(_ handle: String, fromAttachedTab: Bool) async throws -> StopRecord {
        guard let run = await run(handle) else {
            return StopRecord(outcome: .unconfirmed(reason: "Temple has no record of this session", reachedHost: false))
        }
        let outcome: StopOutcome
        do {
            let exec = try await queryExec()
            outcome = try await keepAlive.stop(session: run.sessionName, socket: run.socketPath,
                                               waitTenths: fromAttachedTab ? 30 : 0, using: exec)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome = .unconfirmed(reason: error.localizedDescription, reachedHost: false)
        }
        do {
            try await record(outcome, for: handle)
            return StopRecord(outcome: outcome)
        } catch {
            return StopRecord(outcome: outcome, storageError: error.localizedDescription)
        }
    }

    /// The durable completion of a stop.
    public func record(_ outcome: StopOutcome, for handle: String) async throws {
        switch outcome {
        case .killed: try await markEnded(handle, evidence: .killed)
        case .absent: try await markEnded(handle, evidence: .absent)
        case .refused: try await leaveRunning(handle, reason: .anotherClientAttached)
        case .unconfirmed(_, let reached):
            if !reached { transportFailed() }
            try await leaveRunning(handle, reason: reached ? .stopNotAcknowledged : .hostDidNotAnswer)
        }
    }

    /// A stop Temple could not carry out and confirm: the session is left
    /// running, with the reason, and listed for the user. Nothing follows.
    public func leaveRunning(_ handle: String, reason: RemoteRun.LeftRunningReason) async throws {
        let now = now()
        try await write {
            try $0.update(handle) { row in
                guard row.endedAt == nil else { return }
                row.leftRunningAt = now
                row.leftRunningReason = reason
                row.leftRunningNoticedAt = nil
            }
        }
    }

    /// Keep, in "Sessions on <host>": the flag goes; the session is an
    /// ordinary detached one (fable must-fix 6).
    public func keep(_ handle: String) async throws {
        try await write {
            try $0.update(handle) { row in
                row.leftRunningAt = nil
                row.leftRunningReason = nil
            }
        }
    }

    /// The sidebar's line for these flags was dismissed or acted on.
    public func noticeLeftRunning() async throws {
        let host = host, now = now()
        try await write { store in
            for run in try store.leftRunning(host: host) where run.leftRunningNoticedAt == nil {
                try store.update(run.handle) { $0.leftRunningNoticedAt = now }
            }
        }
    }

    /// Runs flagged left running whose flag the sidebar has not shown yet.
    public func unnoticedLeftRunning() async -> [RemoteRun] {
        let host = host
        return (await read { try $0.leftRunning(host: host) } ?? []).filter { $0.leftRunningNoticedAt == nil }
    }

    // MARK: Sessions on the host

    /// "Sessions on <host>": the runs Temple tracks there that are not
    /// Ended, each asked about on its own pinned server. A run that server
    /// says is gone is Ended and left out; one Temple can't check stays,
    /// with why. `reachedHost`: whether any answer came from the host.
    public func trackedSessions() async -> (sessions: [Tracked], reachedHost: Bool) {
        let live = await runs().filter { !$0.isEnded && $0.dismissedAt == nil }
        guard !live.isEmpty else { return ([], true) }
        let exec: RemoteExec
        do { exec = try await queryExec(refresh: true) } catch {
            return (live.map { Tracked(run: $0, state: .unknown(error.localizedDescription)) }, false)
        }
        var tracked: [Tracked] = []
        var reached = false
        for run in live {
            switch await keepAlive.probe(session: run.sessionName, socket: run.socketPath, using: exec) {
            case .present(let attached):
                reached = true
                tracked.append(Tracked(run: run, state: .present(attached: attached)))
            case .absent:
                reached = true
                if (try? await markEnded(run.handle, evidence: .absent)) == nil {
                    tracked.append(Tracked(run: run, state: .unknown("Temple couldn't record that it ended")))
                }
            case .unknown(let reason, let reachedHost):
                reached = reached || reachedHost
                tracked.append(Tracked(run: run, state: .unknown(reason)))
            }
        }
        if !reached { transportFailed() }
        return (tracked, reached)
    }

    /// At launch, for a host with flags the sidebar has not shown: each
    /// flagged run is asked about on its pinned server; nil when the host
    /// did not answer, otherwise how many are still left running.
    public func contactLeftRunning() async -> Int? {
        let flagged = await unnoticedLeftRunning()
        guard !flagged.isEmpty, let exec = try? await queryExec(refresh: true) else { return nil }
        var reached = false
        for run in flagged {
            switch await keepAlive.probe(session: run.sessionName, socket: run.socketPath, using: exec) {
            case .present: reached = true
            case .absent:
                reached = true
                try? await markEnded(run.handle, evidence: .absent)
            case .unknown(_, let reachedHost): reached = reached || reachedHost
            }
        }
        guard reached else { return nil }
        return await unnoticedLeftRunning().count
    }

    /// The folder sheet's advisory check.
    public func checkFolder(_ path: String) async -> FolderCheck {
        do { return await FolderCheck.run(path, using: try await queryExec(refresh: true)) } catch {
            return .transport(error.localizedDescription)
        }
    }

    /// The command that stops a session from the host itself, for copy.
    public nonisolated static func manualStopCommand(handle: String) -> String {
        "tmux -L temple kill-session -t temple-\(handle)"
    }
}
