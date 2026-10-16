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
        /// The user chose Resume although Temple couldn't check whether the
        /// conversation exists.
        public var resumeUnconfirmed: Bool
        public init(agent: Agent, sessionID: String, mode: Mode, directory: String, extraArguments: [String] = [],
                    resumeAnyway: Bool = false, startNew: Bool = false, resumeUnconfirmed: Bool = false) {
            self.agent = agent; self.sessionID = sessionID; self.mode = mode; self.directory = directory
            self.extraArguments = extraArguments; self.resumeAnyway = resumeAnyway; self.startNew = startNew
            self.resumeUnconfirmed = resumeUnconfirmed
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
        /// The staged launch's name (`LaunchStage`): the tab's command waits
        /// for it on the host.
        public var stage: String
        /// Already in place when the plan was made (a master was up). When
        /// false, the caller spawns the tab, whose ssh authenticates and
        /// becomes the master, then calls `stage(_:)`.
        public var staged: Bool
        /// What the staged script carries, for checks.
        public var launch: RemoteLaunchPlan
    }

    /// What staging after the tab connected came to.
    public enum StageOutcome: Sendable, Equatable {
        case staged
        /// Nothing was put in place, so nothing ran: a creation is recorded
        /// as failed, with why.
        case failed(String)
        /// No answer: it may be in place; the tab's own exit decides.
        case unknown(String)
        /// Refused, but recording the creation as failed did not work: why.
        /// The run stays unresolved until its tab's end records it.
        case storage(String)
        /// Nothing to stage (already sent, or the open was abandoned).
        case none
    }

    public enum OpenOutcome: Sendable, Equatable {
        case plan(OpenPlan)
        /// The session's last run ended with its conversation unconfirmed,
        /// and the host has no transcript for it (`checked`), or Temple
        /// couldn't check (then Resume is offered too).
        case needsDecision(checked: Bool)
    }

    /// What the launch records said, once persisted.
    public enum Collected: Sendable, Equatable {
        /// The pane ran in this folder (its `pwd -P`), recorded.
        case ok(directory: String)
        /// The pane could not enter the folder; no agent ran. Recorded.
        case failedCD(directory: String)
        /// The launch failed before any agent ran (it couldn't be staged,
        /// or the pane wasn't told its config root). Recorded; why.
        case failedLaunch(String)
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
    private let makeExec: (SSHConnection, String?, SSHConnection.Purpose) -> RemoteExec
    private let masterCheck: ([String]) async -> Bool
    private let now: () -> Date
    private let token: () -> String

    private var connection: SSHConnection?
    public private(set) var pathState: PathState = .unresolved
    /// The connection `pathState` was resolved over: an answer for another
    /// is never cached.
    private var pathConnection: SSHConnection?
    /// Claude's config root from the same login environment as the PATH.
    private var claudeConfig: RemoteEnvironment.ClaudeConfig?
    /// Codex's home from the same login environment.
    private var codexHome: RemoteEnvironment.CodexHome?
    /// The host was removed or edited: nothing here runs again.
    public private(set) var retired = false
    /// What an ended run's pane showed, taken when its end was proven (the
    /// file is removed then), for the diagnostics that may follow.
    private var endedOutput: [String: String] = [:]
    /// Launch scripts planned but not yet staged, by stage name. `sent`:
    /// a write was attempted (it may have landed).
    private var pendingStages: [String: PendingStage] = [:]

    /// A launch planned for one tab and not yet in place on the host. It
    /// keeps the exact connection its tab uses: it is written over that
    /// connection's master and nothing else, never over a connection
    /// another open re-resolved meanwhile, never directly.
    private struct PendingStage {
        enum State {
            /// Not sent: nothing of it can be on the host.
            case planned
            /// Being written now.
            case sending
            /// Refused on the host before anything was put in place.
            case refused
        }
        let handle: String
        let creating: Bool
        let script: String
        let connection: SSHConnection
        let path: String?
        var state: State
        /// Nothing of it can be in place, so nothing of it can have run.
        var notInPlace: Bool { state == .planned || state == .refused }
    }

    public init(record: RemoteHostRecord, stateDirectory: URL, sshPath: @autoclosure @escaping () -> String,
                store: @escaping () throws -> RemoteStateStore,
                storeExists: @escaping () -> Bool = { true },
                keepAlive: KeepAlive = TmuxKeepAlive(),
                resolve: @escaping ([String]) async -> ConnectionTest.Resolution = ConnectionTest.sshResolve,
                makeExec: @escaping (SSHConnection, String?, SSHConnection.Purpose) -> RemoteExec = {
                    SSHExec(connection: $0, path: $1, purpose: $2)
                },
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
        if connection != nil { pathState = .unresolved; pathConnection = nil }
        connection = resolved
        return resolved
    }

    /// A query exec with the PATH policy's answer, resolving it first when
    /// no query has reached the host yet.
    func queryExec(refresh: Bool = false) async throws -> RemoteExec {
        let connection = try await resolvedConnection(refresh: refresh)
        if pathConnection != connection { pathState = .unresolved }
        if case .unresolved = pathState {
            let resolved = await RemoteEnvironment.resolve(using: makeExec(connection, nil, .query))
            guard !retired else { throw Retired() }
            // Cached only for the connection it was resolved over.
            if resolved.reachedHost, self.connection == connection {
                pathState = resolved.path.map(PathState.resolved) ?? .fallback(resolved.problem ?? "no PATH")
                claudeConfig = resolved.claudeConfig
                codexHome = resolved.codexHome
                pathConnection = connection
            }
        }
        guard !retired else { throw Retired() }
        if pathConnection == connection, case .resolved(let path) = pathState { return makeExec(connection, path, .query) }
        return makeExec(connection, nil, .query)
    }

    /// A transport failure: the next query resolves the PATH again.
    func transportFailed() { pathState = .unresolved; pathConnection = nil; claudeConfig = nil; codexHome = nil }

    // MARK: Enrichment (phase 2)

    /// What enrichment needs for one query (`RemoteSessionSource`): the
    /// query exec, with the PATH policy's answer, and per session where its
    /// transcripts are. A session Temple ran here is looked for under the
    /// root its latest relevant run's agent had (as that run's pane
    /// recorded it), and only there: a run that left no evidence makes the
    /// root unknown, never an older run's or the login environment's. A
    /// session with no run (imported, or run before the store existed) is
    /// looked for under the login environment's root, from the same bounded
    /// query as the PATH. A root Temple doesn't know is not searched. A
    /// store that exists but can't be read makes every root unknown.
    public func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext {
        let exec = try await queryExec(refresh: refresh)
        guard !sessionIDs.isEmpty else { return RemoteTranscriptContext(exec: exec, roots: [:]) }
        let login: [Agent: RemoteTranscriptRoot] = [
            .claude: RemoteTranscriptRoot(launchConfig, base: nil),
            .codex: RemoteTranscriptRoot(launchCodexHome, base: nil),
        ].compactMapValues { $0 }
        let host = host
        var runs: [RemoteRun] = []
        if openedStore != nil || storeExists() {
            do { runs = try await store().perform { try $0.runs(host: host) } } catch {
                return RemoteTranscriptContext(exec: exec, roots: [:])
            }
        }
        var bySession: [String: [RemoteRun]] = [:]
        for run in runs { if let id = run.sessionID { bySession[id, default: []].append(run) } }
        var roots: [String: [Agent: RemoteTranscriptRoot]] = [:]
        for id in sessionIDs {
            guard let sessionRuns = bySession[id], !sessionRuns.isEmpty else {
                roots[id] = login
                continue
            }
            guard let latest = sessionRuns.last(where: { $0.dismissedAt == nil && $0.creation != .failed }) else {
                // Every run was dismissed or never ran: nothing says where
                // its agent kept the conversation.
                roots[id] = [:]
                continue
            }
            let variable = latest.agent == .claude ? Self.effectiveRoot(of: latest) : Self.effectiveHome(of: latest)
            roots[id] = RemoteTranscriptRoot(variable, base: latest.directory).map { [latest.agent: $0] } ?? [:]
        }
        return RemoteTranscriptContext(exec: exec, roots: roots)
    }

    /// A query failed in transit (enrichment's): the next one resolves the
    /// environment again.
    public func enrichmentTransportFailed() { transportFailed() }

    /// The config root to hand a launch: only one resolved over this
    /// connection (otherwise the launch resolves it with the PATH).
    var launchConfig: RemoteEnvironment.ClaudeConfig? {
        pathConnection == connection ? claudeConfig : nil
    }

    /// Codex's home to hand a launch, the same way.
    var launchCodexHome: RemoteEnvironment.CodexHome? {
        pathConnection == connection ? codexHome : nil
    }

    var launchPath: RemoteLaunchPlan.Path {
        guard pathConnection == connection else { return .unresolved }
        switch pathState {
        case .unresolved: return .unresolved
        case .resolved(let path): return .resolved(path)
        case .fallback: return .fallback
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
        // Codex mints its own ids: a new Codex session is a pending run
        // (`openPending`), never one started under an id Temple chose.
        if request.agent == .codex, request.mode == .new || request.startNew {
            throw OpenError.refused("A new Codex session starts without an id (Temple learns it later).")
        }
        let connection = try await resolvedConnection(refresh: true)
        let resume = request.mode == .resume && !request.startNew
        let candidate = newRun(request, resume: resume)
        if request.resumeAnyway || request.startNew {
            // Explicit choices, never the ordinary reservation.
            do { try await write { try $0.insert(candidate) } } catch { throw OpenError.store(error.localizedDescription) }
            return .plan(try await createPlan(candidate, request: request, connection: connection))
        }
        return try await reserveAndPlan(request, candidate: candidate, connection: connection, recovering: true)
    }

    private func reserveAndPlan(_ request: OpenRequest, candidate: RemoteRun, connection: SSHConnection,
                                recovering: Bool, allowUnconfirmed: Bool = false,
                                verifiedRoot: RemoteEnvironment.ClaudeConfig? = nil) async throws -> OpenOutcome {
        let reservation: RemoteStateStore.Reservation
        let allow = allowUnconfirmed || request.resumeUnconfirmed
        do { reservation = try await write { try $0.reserve(candidate, allowUnconfirmed: allow) } } catch {
            throw OpenError.store(error.localizedDescription)
        }
        switch reservation {
        case .needsDecision:
            // Typed input is not evidence; the transcript on the host is.
            let verified = await verifyConversation(sessionID: request.sessionID)
            switch verified.check {
            case .present:
                // Resumed against the root the transcript was found in.
                return try await reserveAndPlan(request, candidate: candidate, connection: connection,
                                                recovering: recovering, allowUnconfirmed: true, verifiedRoot: verified.root)
            case .absent:
                return .needsDecision(checked: true)
            case .unknown:
                return .needsDecision(checked: false)
            }
        case .created(let run):
            return .plan(try await createPlan(run, request: request, connection: connection, verifiedRoot: verifiedRoot))
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
            return .plan(try await attachPlan(run, connection: connection,
                                              agentArgv: agentArgv(run.agent, sessionID: request.sessionID,
                                                                   resume: run.mode == .resume, extra: request.extraArguments)))
        }
    }

    /// An attach to a run that is not Ended: creates nothing, replays the
    /// persisted creation evidence.
    private func attachPlan(_ run: RemoteRun, connection: SSHConnection, agentArgv: [String]) async throws -> OpenPlan {
        let marker = marker(run)
        let plan = RemoteLaunchPlan(handle: run.handle, marker: marker, directory: run.directoryIntent,
                                    agentArgv: [], path: launchPath, claudeConfig: launchConfig, socket: run.socketPath,
                                    stage: LaunchStage.attachName(marker: marker, nonce: token()))
        let staged = try await stageBeforeSpawn(plan.stage, handle: run.handle, creating: false,
                                                script: keepAlive.attachScript(plan), connection: connection)
        return OpenPlan(handle: run.handle, attachment: run.attachment, creating: false,
                        argv: localArgv(connection, LaunchStage.command(stage: plan.stage)), agentArgv: agentArgv,
                        directoryIntent: run.directoryIntent,
                        evidenceDirectory: run.creation == .proven ? run.directory : nil,
                        stage: plan.stage, staged: staged, launch: plan)
    }

    private func newRun(_ request: OpenRequest, resume: Bool) -> RemoteRun {
        let marker = "r-" + token()
        var run = RemoteRun(handle: token(), host: host, agent: request.agent, mode: resume ? .resume : .new,
                            directoryIntent: request.directory, sessionID: request.sessionID,
                            recordPath: RecordDirectory.locator(marker: marker), startedAt: now())
        run.conversation = resume ? .confirmed : .unconfirmed
        return run
    }

    /// A creation's plan. A resume is started against the config root its
    /// conversation lives in: the one the transcript check just found it
    /// in (`verifiedRoot`), else the root the session's latest run had,
    /// else the login environment's.
    private func createPlan(_ run: RemoteRun, request: OpenRequest, connection: SSHConnection,
                            verifiedRoot: RemoteEnvironment.ClaudeConfig? = nil) async throws -> OpenPlan {
        try await createPlan(run, sessionID: request.sessionID, extra: request.extraArguments, connection: connection,
                             verifiedRoot: verifiedRoot)
    }

    /// `sessionID` nil: a new Codex session, which mints its own.
    private func createPlan(_ run: RemoteRun, sessionID: String?, extra: [String], connection: SSHConnection,
                            verifiedRoot: RemoteEnvironment.ClaudeConfig? = nil) async throws -> OpenPlan {
        let argv = agentArgv(run.agent, sessionID: sessionID, resume: run.mode == .resume, extra: extra)
        var config = launchConfig
        var home = launchCodexHome
        if run.mode == .resume, let sessionID {
            let latest = await latestRelevantRun(sessionID: sessionID, excluding: run.handle)
            if let verifiedRoot {
                config = verifiedRoot
            } else if let latest, let root = Self.effectiveRoot(of: latest) {
                config = root
            }
            // A Codex conversation is resumed from the home it lives in.
            if run.agent == .codex, let latest, let root = Self.effectiveHome(of: latest) { home = root }
        }
        let marker = marker(run)
        let plan = RemoteLaunchPlan(handle: run.handle, marker: marker, directory: run.directoryIntent,
                                    agentArgv: argv, path: launchPath, claudeConfig: config, codexHome: home, socket: nil,
                                    stage: LaunchStage.creationName(marker: marker, nonce: token()))
        let staged = try await stageBeforeSpawn(plan.stage, handle: run.handle, creating: true,
                                                script: keepAlive.createScript(plan), connection: connection)
        return OpenPlan(handle: run.handle, attachment: run.attachment, creating: true,
                        argv: localArgv(connection, LaunchStage.command(stage: plan.stage)), agentArgv: argv,
                        directoryIntent: run.directoryIntent, evidenceDirectory: nil,
                        stage: plan.stage, staged: staged, launch: plan)
    }

    /// Stages the launch now when Temple's master is up, so the tab's
    /// command finds it at once. Anything but a clean write refuses the
    /// open (a creation is recorded as failed first, and a write that fails
    /// is a storage error, never swallowed): nothing is spawned on a launch
    /// Temple couldn't put in place. A cancellation stays a cancellation.
    /// Without a master the launch waits for `stage(_:)`, after the tab has
    /// connected.
    private func stageBeforeSpawn(_ name: String, handle: String, creating: Bool, script: String,
                                  connection: SSHConnection) async throws -> Bool {
        var path: String?
        if case .resolved(let resolved) = launchPath { path = resolved }
        pendingStages[name] = PendingStage(handle: handle, creating: creating, script: script, connection: connection,
                                           path: path, state: .planned)
        guard await masterCheck(connection.masterCheckArgv), !retired else {
            if Task.isCancelled { try await failUnspawned(handle, creating: creating, reason: "the open was cancelled") }
            return false
        }
        let outcome = await send(name, removeIfUnanswered: true)
        switch outcome {
        case .staged:
            return true
        case .storage(let reason):
            throw OpenError.store(reason)
        case .failed(let reason), .unknown(let reason):
            try await failUnspawned(handle, creating: creating, reason: "the launch couldn't be prepared: \(reason)")
            if Task.isCancelled { throw CancellationError() }
            throw OpenError.refused(Self.stagingRefusal(host: record.name, reason: reason))
        case .none:
            try await failUnspawned(handle, creating: creating, reason: "the open was abandoned")
            if Task.isCancelled { throw CancellationError() }
            throw OpenError.refused(Self.stagingRefusal(host: record.name, reason: "the open was abandoned"))
        }
    }

    /// A planned creation that will not be spawned: recorded failed (if it
    /// still is one), its pending launch dropped once that is written. A
    /// write that fails is a storage error.
    private func failUnspawned(_ handle: String, creating: Bool, reason: String) async throws {
        guard creating else {
            for (name, pending) in pendingStages where pending.handle == handle { pendingStages[name] = nil }
            return
        }
        do { try await abandon(handle, reason: reason) } catch { throw OpenError.store(error.localizedDescription) }
    }

    static func stagingRefusal(host: String, reason: String) -> String {
        "Temple couldn't prepare the session on \(host): \(reason)"
    }

    /// The staged write, once, over the pending launch's own connection
    /// and its master only (`.overMaster`). Refused on the host (nothing
    /// put in place): a creation is recorded as failed, and the pending
    /// launch is forgotten only once that is written (a write that fails
    /// is `.storage`, the launch kept as refused so a later end of its tab
    /// records it). Unanswered: it may be in place; it is removed when no
    /// tab will run it (`removeIfUnanswered`, before the spawn), otherwise
    /// left for the tab, whose exit decides.
    private func send(_ name: String, removeIfUnanswered: Bool = false) async -> StageOutcome {
        guard var pending = pendingStages[name], pending.state == .planned else { return .none }
        pending.state = .sending
        pendingStages[name] = pending
        let exec = makeExec(pending.connection, pending.path, .overMaster)
        switch await LaunchStage.write(stage: name, script: pending.script, using: exec) {
        case .staged:
            pendingStages[name] = nil
            return .staged
        case .refused(let reason):
            pendingStages[name]?.state = .refused
            guard pending.creating else {
                pendingStages[name] = nil
                return .failed(reason)
            }
            do {
                let committed = try await failUnstarted(pending.handle, reason: "the launch couldn't be prepared: \(reason)")
                pendingStages[name] = nil
                // Another open attached to the run meanwhile: nothing here
                // to record, and nothing to claim about the run.
                return committed ? .failed(reason) : .unknown(reason)
            } catch {
                return .storage(error.localizedDescription)
            }
        case .unknown(let reason):
            pendingStages[name] = nil
            if removeIfUnanswered, !retired { await LaunchStage.discard(stage: name, using: exec) }
            return .unknown(reason)
        }
    }

    /// Stages a launch whose tab is connecting: waits for the master of
    /// the tab's own connection (at first contact the tab's ssh
    /// authenticates and becomes it), then writes the launch, once, over
    /// it. The caller cancels it when the tab goes; it gives up on its own
    /// after `stageWaitSeconds`.
    public func stage(_ name: String) async -> StageOutcome {
        guard let connection = pendingStages[name]?.connection else { return .none }
        let deadline = now().addingTimeInterval(Self.stageWaitSeconds)
        while !Task.isCancelled, !retired, pendingStages[name]?.state == .planned {
            if await masterCheck(connection.masterCheckArgv), !Task.isCancelled, !retired {
                return await send(name)
            }
            guard now() < deadline else { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .none
    }

    /// How long a connecting tab's launch waits for Temple's master: long
    /// enough for a person to authenticate.
    public static let stageWaitSeconds: TimeInterval = 600

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
    func agentArgv(_ agent: Agent, sessionID: String?, resume: Bool, extra: [String]) -> [String] {
        let tail: [String]
        switch (agent, sessionID, resume) {
        case (_, nil, _): tail = []
        case (.claude, let id?, false): tail = ["--session-id", id]
        case (.claude, let id?, true): tail = ["--resume", id]
        case (.codex, let id?, _): tail = ["resume", id]
        }
        return [agent.binaryName] + extra + tail
    }

    /// An open that was planned but never spawned (the tab closed, the
    /// spawn failed, the host changed): no session was created. Whether
    /// this call recorded the creation failed (a run another open attached
    /// to meanwhile is left alone); its pending launches are forgotten
    /// once the write has happened. A write that fails throws.
    @discardableResult
    public func abandon(_ handle: String, reason: String) async throws -> Bool {
        let committed = try await failUnstarted(handle, reason: reason)
        for (name, pending) in pendingStages where pending.handle == handle && pending.state != .sending {
            pendingStages[name] = nil
        }
        return committed
    }

    private func failUnstarted(_ handle: String, reason: String) async throws -> Bool {
        let now = now()
        return try await write { try $0.failUnstartedCreation(handle, reason: reason, at: now) }
    }

    // MARK: Records

    /// Fetches the run's records by their persisted locator, writes the
    /// evidence, and only then acknowledges (deletes) them on the host. A
    /// write that fails is `.storage`, and nothing is acknowledged.
    public func collect(_ handle: String) async -> Collected {
        guard let run = await run(handle) else { return .nothing }
        if run.creation == .proven, let directory = run.directory { return .ok(directory: directory) }
        if run.creation == .failed, run.failure == "cd" { return .failedCD(directory: run.directoryIntent) }
        if run.creation == .failed { return .failedLaunch(run.failure ?? "the launch failed") }
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
                        row.claudeConfig = evidence.claudeConfig
                        row.codexHome = evidence.codexHome
                        row.creation = .proven
                    }
                }
            } catch {
                return .storage(error.localizedDescription)
            }
            if !retired { await LaunchRecords.acknowledge(marker: marker, using: exec) }
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
            if !retired { await LaunchRecords.acknowledge(marker: marker, all: true, using: exec) }
            return .failedCD(directory: run.directoryIntent)
        case .failedLaunch(let reason)?:
            do {
                try await write {
                    try $0.update(handle) { row in
                        row.creation = .failed
                        row.failure = reason
                        row.endedAt = now
                    }
                }
            } catch {
                return .storage(error.localizedDescription)
            }
            if !retired { await LaunchRecords.acknowledge(marker: marker, all: true, using: exec) }
            return .failedLaunch(reason)
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
    /// its first 64 KiB, raw. Fetched once, then removed from the host; the
    /// pane's and the client's records are not touched (they are
    /// acknowledged only once their evidence is written).
    public func diagnostics(_ handle: String) async -> String? {
        // Taken when the end was proven (the file went with it).
        if let taken = endedOutput.removeValue(forKey: handle) { return taken }
        guard let run = await run(handle), let exec = try? await queryExec(), !retired else { return nil }
        return await LaunchRecords.takeOutput(marker: marker(run), using: exec)
    }

    /// Whether the session's transcript exists on the host. Present: the
    /// conversation is recorded as confirmed for its runs.
    public func conversation(sessionID: String) async -> ConversationCheck {
        await verifyConversation(sessionID: sessionID).check
    }

    /// The latest run of the session that may have run its agent: not
    /// dismissed, and not a creation that failed before anything ran.
    /// `excluding`: the run being planned right now.
    private func latestRelevantRun(sessionID: String, excluding handle: String? = nil) async -> RemoteRun? {
        let host = host
        return await read { try $0.runs(host: host, sessionID: sessionID) }?
            .last { $0.dismissedAt == nil && $0.creation != .failed && $0.handle != handle }
    }

    /// The config root the session's latest run started its agent with, as
    /// that agent resolved it: a relative value made absolute against the
    /// folder the pane ran in. Nil when that run left no evidence of either,
    /// or set it to the empty string (how Claude reads that is not known):
    /// never an older run's root instead.
    static func effectiveRoot(of run: RemoteRun) -> RemoteEnvironment.ClaudeConfig? {
        guard let config = run.claudeConfig, let base = run.directory else { return nil }
        switch config {
        case .unset: return .unset
        case .set(let value) where value.isEmpty: return nil
        case .set(let value) where value.hasPrefix("/"): return .set(value)
        case .set(let value): return .set((base.hasSuffix("/") ? base : base + "/") + value)
        }
    }

    /// Codex's home the run's agent was started with, as Codex read it: a
    /// relative value made absolute against the folder the pane ran in.
    /// Nil when that run left no evidence, or set it empty.
    static func effectiveHome(of run: RemoteRun) -> RemoteEnvironment.CodexHome? {
        guard let home = run.codexHome else { return nil }
        switch home {
        case .unset: return .unset
        case .set(let value) where value.isEmpty: return nil
        case .set(let value) where value.hasPrefix("/"): return .set(value)
        case .set(let value):
            guard let base = run.directory else { return nil }
            return .set((base.hasSuffix("/") ? base : base + "/") + value)
        }
    }

    /// The transcript check, on the root of the session's latest relevant
    /// run, and that root (the one a resume after a present answer must use).
    private func verifyConversation(sessionID: String) async -> (check: ConversationCheck, root: RemoteEnvironment.ClaudeConfig?) {
        guard RemoteQuoting.isSafeToken(sessionID) else { return (.unknown("this session id can't be sent to a host"), nil) }
        guard let latest = await latestRelevantRun(sessionID: sessionID), let root = Self.effectiveRoot(of: latest),
              let base = latest.directory else {
            return (.unknown("Temple doesn't know which config folder this session used"), nil)
        }
        guard let exec = try? await queryExec(), !retired else { return (.unknown("Temple couldn't reach the host"), nil) }
        let answer = await ConversationCheck.run(sessionID: sessionID, config: root, base: base, using: exec)
        if answer == .present {
            let host = host
            _ = try? await write { store in
                for run in try store.runs(host: host, sessionID: sessionID) where run.conversation != .confirmed {
                    try store.update(run.handle) { $0.conversation = .confirmed }
                }
            }
        }
        return (answer, root)
    }

    /// A run with no server on record: its record is recovered first, so
    /// every later question goes to the server it was created on.
    private func pinned(_ run: RemoteRun) async -> RemoteRun {
        guard run.socketPath == nil, run.creation == nil || run.creation == .unproven, !retired else { return run }
        _ = await collect(run.handle)
        return await self.run(run.handle) ?? run
    }

    /// A creation whose tab ended with nothing collected: unproven, so
    /// every later Open is attach-only.
    ///
    /// A creation whose launch was never sent to the host cannot have run:
    /// it is recorded as failed instead (later Opens create again), and
    /// why is returned.
    @discardableResult
    public func markCreationUnproven(_ handle: String) async throws -> String? {
        if try await abandonUnsent(handle) { return Self.unsentReason }
        try await write { try $0.update(handle) { row in if row.creation == nil { row.creation = .unproven } } }
        return nil
    }

    static let unsentReason = "the connection ended before Temple could prepare the launch"

    /// A creation whose staged launch never reached the host (never sent,
    /// or refused before anything was put in place): recorded as failed.
    /// True only once that write has committed; the proof is forgotten only
    /// then. A run another open attached to meanwhile stays as it is
    /// (false), and a write that fails throws, the proof kept.
    private func abandonUnsent(_ handle: String) async throws -> Bool {
        let unsent = pendingStages.filter { $0.value.handle == handle && $0.value.creating && $0.value.notInPlace }
        guard !unsent.isEmpty else { return false }
        guard try await failUnstarted(handle, reason: Self.unsentReason) else { return false }
        for name in unsent.keys { pendingStages[name] = nil }
        return true
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
        guard let found = await run(handle) else { return .unknown(reason: "Temple has no record of this session", socketMissing: false) }
        let run = await pinned(found)
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
            if !retired { endedOutput[handle] = await LaunchStage.discardAll(marker: marker(run), using: exec) }
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
        guard let found = await run(handle) else {
            return StopRecord(outcome: .unconfirmed(reason: "Temple has no record of this session", reachedHost: false))
        }
        // A creation whose launch never reached the host: nothing runs there,
        // once that is written; a write that fails proves nothing.
        do {
            if try await abandonUnsent(handle) { return StopRecord(outcome: .absent) }
        } catch {
            let reason = "Temple couldn't record that it never started: \(error.localizedDescription)"
            return StopRecord(outcome: .unconfirmed(reason: reason, reachedHost: true), storageError: error.localizedDescription)
        }
        let run = await pinned(found)
        let outcome: StopOutcome
        var stopExec: RemoteExec?
        do {
            let exec = try await queryExec()
            stopExec = exec
            outcome = try await keepAlive.stop(session: run.sessionName, socket: run.socketPath,
                                               waitTenths: fromAttachedTab ? 30 : 0, using: exec)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome = .unconfirmed(reason: error.localizedDescription, reachedHost: false)
        }
        do {
            try await record(outcome, for: handle)
        } catch {
            return StopRecord(outcome: outcome, storageError: error.localizedDescription)
        }
        // The run ended: what was staged for it and never read goes too
        // (best effort, after the outcome is written).
        if outcome == .killed || outcome == .absent, let stopExec, !retired, !Task.isCancelled {
            await LaunchStage.discardAll(marker: marker(run), using: stopExec)
        }
        return StopRecord(outcome: outcome)
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
        for found in live {
            guard !retired, !Task.isCancelled else {
                tracked.append(Tracked(run: found, state: .unknown(Retired().localizedDescription)))
                continue
            }
            let run = await pinned(found)
            guard !retired, !Task.isCancelled else {
                tracked.append(Tracked(run: run, state: .unknown(Retired().localizedDescription)))
                continue
            }
            switch await keepAlive.probe(session: run.sessionName, socket: run.socketPath, using: exec) {
            case .present(let attached):
                reached = true
                tracked.append(Tracked(run: run, state: .present(attached: attached)))
            case .absent:
                reached = true
                if (try? await markEnded(run.handle, evidence: .absent)) == nil {
                    tracked.append(Tracked(run: run, state: .unknown("Temple couldn't record that it ended")))
                } else if !retired {
                    await LaunchStage.discardAll(marker: marker(run), using: exec)
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
        for found in flagged {
            guard !retired, !Task.isCancelled else { return nil }
            let run = await pinned(found)
            guard !retired, !Task.isCancelled else { return nil }
            switch await keepAlive.probe(session: run.sessionName, socket: run.socketPath, using: exec) {
            case .present: reached = true
            case .absent:
                reached = true
                if (try? await markEnded(run.handle, evidence: .absent)) != nil, !retired {
                    await LaunchStage.discardAll(marker: marker(run), using: exec)
                }
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

    // MARK: Codex identity (phase 1b)

    /// What opening a pending Codex run (or starting one) decided.
    public enum PendingOpenOutcome: Sendable, Equatable {
        case plan(OpenPlan)
        /// The run ended before Temple learned its id; nothing is created
        /// in its place.
        case ended(handle: String)
        /// The run has an id now (another Temple learned it): it is that
        /// session's run, opened as any session is.
        case identified(handle: String, sessionID: String)
    }

    /// Starts a new Codex session (`handle` nil): a pending run, written
    /// before anything spawns, its agent `codex` with the extra arguments
    /// and nothing else, so Codex mints the id. Or reopens a pending run by
    /// its handle: attach-only while it is not Ended, as for any run.
    public func openPending(handle: String?, directory: String, extraArguments: [String]) async throws -> PendingOpenOutcome {
        let connection = try await resolvedConnection(refresh: true)
        guard let handle else {
            var run = RemoteRun(handle: token(), host: host, agent: .codex, mode: .new, directoryIntent: directory,
                                sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-" + token()), startedAt: now())
            run.conversation = .unconfirmed
            let candidate = run
            do { try await write { try $0.insert(candidate) } } catch { throw OpenError.store(error.localizedDescription) }
            return .plan(try await createPlan(candidate, sessionID: nil, extra: extraArguments, connection: connection))
        }
        let reservation: RemoteStateStore.PendingReservation
        do { reservation = try await write { try $0.reservePending(handle) } } catch {
            throw OpenError.store(error.localizedDescription)
        }
        switch reservation {
        case .gone:
            throw OpenError.refused("Temple no longer tracks this session on \(record.name).")
        case .identified(let id):
            return .identified(handle: handle, sessionID: id)
        case .ended:
            return .ended(handle: handle)
        case .existing(var run):
            if run.creation == nil || run.creation == .unproven {
                switch await collect(run.handle) {
                case .failedCD, .failedLaunch:
                    // Never ran: nothing to attach to, nothing to identify.
                    return .ended(handle: handle)
                case .storage(let reason):
                    throw OpenError.store(reason)
                default:
                    run = await self.run(run.handle) ?? run
                }
            }
            return .plan(try await attachPlan(run, connection: connection,
                                              agentArgv: agentArgv(.codex, sessionID: nil, resume: false, extra: extraArguments)))
        }
    }

    /// What one identity check came to.
    public enum Identity: Sendable, Equatable {
        /// Verified by the pane's own process tree, and claimed (written
        /// before anything else hears of it).
        case adopted(String)
        /// The run already has this id (claimed earlier, or by another Temple).
        case known(String)
        /// Another run on this host holds the id that was found: refused,
        /// the run stays pending.
        case taken
        case inconclusive(CodexIdentityCheck.Inconclusive)
        /// The claim could not be written: nothing was adopted.
        case storage(String)
    }

    /// Where the identity check reads processes. Tests (and acceptance, to
    /// prove the suggestion path) point it elsewhere: a host without
    /// `/proc` is suggest-only.
    public var procRoot = "/proc"

    /// Identity checks for one host run one at a time.
    private var identityTail: Task<Void, Never>?

    private func serially<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = identityTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        identityTail = Task { _ = await task.value }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The automatic check (section 3): adopts only on the run's own
    /// process tree holding exactly one rollout open for writing, whose
    /// header names its file's id and the run's folder; claims it before
    /// returning. Everything else is inconclusive and claims nothing.
    public func identify(_ handle: String) async -> Identity {
        await serially { [weak self] in
            guard let self else { return .inconclusive(.retry("cancelled")) }
            return await self.identifyNow(handle)
        }
    }

    private func identifyNow(_ handle: String) async -> Identity {
        guard !retired, !Task.isCancelled else { return .inconclusive(.retry(Retired().localizedDescription)) }
        guard let run = await run(handle), run.agent == .codex else { return .inconclusive(.ended("Temple has no record of this session")) }
        if let id = run.sessionID { return .known(id) }
        if run.isEnded { return .inconclusive(.ended("the session has ended")) }
        guard run.creation == .proven, let pid = run.panePID, let directory = run.directory else {
            return .inconclusive(.retry("Temple hasn't seen this session start yet"))
        }
        guard let start = run.paneStart else { return .inconclusive(.lasting("this host has no /proc")) }
        guard let home = CodexHomeRoot.arguments(run.codexHome, base: directory) else {
            return .inconclusive(.lasting("Temple doesn't know which Codex home this session used"))
        }
        let exec: RemoteExec
        do { exec = try await queryExec() } catch { return .inconclusive(.retry(error.localizedDescription)) }
        let answer = await CodexIdentityCheck.run(proc: procRoot, panePID: pid, paneStart: start, socket: run.socketPath,
                                                  session: run.sessionName, home: home, using: exec)
        switch answer {
        case .inconclusive(let why):
            return .inconclusive(why)
        case .found(let path, let header):
            guard let id = CodexIdentityCheck.verify(path: path, header: header, directory: directory) else {
                return .inconclusive(.retry("the open session file doesn't name this session's folder or its own id"))
            }
            return await claim(handle, sessionID: id, how: .verified)
        }
    }

    private func claim(_ handle: String, sessionID: String, how: RemoteRun.Claim, rolloutPath: String? = nil) async -> Identity {
        do {
            switch try await write({ try $0.claim(handle, sessionID: sessionID, how: how, rolloutPath: rolloutPath) }) {
            case .claimed: return .adopted(sessionID)
            case .alreadyKnown(let id): return .known(id)
            case .taken: return .taken
            case .declined: return .inconclusive(.retry("that session was declined for this one"))
            case .gone: return .inconclusive(.ended("Temple no longer tracks this session"))
            }
        } catch {
            return .storage(error.localizedDescription)
        }
    }

    /// What the suggestion lookup came to.
    public enum Suggestions: Sendable, Equatable {
        case candidates([CodexSuggestion])
        case unavailable(String)
    }

    /// Rollouts that may be this pending run's session: in its folder (as
    /// its pane spelled it), begun between its `ok` and its end (or now) on
    /// the host's clock, not declined for this run, not an id another run
    /// holds; the newest `limit` of those, with their first prompts. Asks;
    /// never adopts. Only for a run Temple started. A store that can't be
    /// read, a lookup that isn't whole: unavailable, never a guess.
    public func suggestions(_ handle: String) async -> Suggestions {
        switch await eligible(handle) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .candidates(let found):
            let offered = Array(found.prefix(CodexSuggestionLookup.limit))
            guard !offered.isEmpty else { return .candidates([]) }
            let exec: RemoteExec
            do { exec = try await queryExec() } catch { return .unavailable(error.localizedDescription) }
            let heads = await CodexSuggestionLookup.heads(offered.map(\.rolloutPath), using: exec)
            return .candidates(CodexSuggestionLookup.withPrompts(offered, heads: heads))
        }
    }

    /// Every eligible candidate for the run, read now (no prompts).
    private func eligible(_ handle: String) async -> Suggestions {
        guard !retired else { return .unavailable(Retired().localizedDescription) }
        guard let run = await run(handle), run.isPending, run.dismissedAt == nil else { return .candidates([]) }
        guard let okAt = run.okAt, let directory = run.directory else {
            return .unavailable("Temple hasn't seen this session start yet")
        }
        guard let home = CodexHomeRoot.arguments(run.codexHome, base: directory) else {
            return .unavailable("Temple doesn't know which Codex home this session used")
        }
        let exec: RemoteExec
        do { exec = try await queryExec() } catch { return .unavailable(error.localizedDescription) }
        let asked = now()
        let listing = await CodexSuggestionLookup.list(home: home, since: okAt, directory: directory, using: exec)
        guard case .headers(let remoteNow, let files) = listing else {
            if case .unavailable(let reason) = listing { return .unavailable(reason) }
            return .unavailable("no answer")
        }
        // The end on the host's clock: its end as this Mac saw it, moved by
        // the clocks' offset measured just now, with room for the lag.
        let offset = TimeInterval(remoteNow) - asked.timeIntervalSince1970
        let until = run.endedAt.map { $0.addingTimeInterval(offset + 30) }
            ?? Date(timeIntervalSince1970: TimeInterval(remoteNow + 5))
        let host = host
        let declined: Set<String>, held: Set<String>
        do {
            declined = try await write { try $0.declined(handle) }
            held = try await write { try $0.sessionIDs(host: host) }
        } catch {
            return .unavailable("Temple couldn't read what it knows about this session: \(error.localizedDescription)")
        }
        return .candidates(CodexSuggestionLookup.eligible(files, directory: directory, since: okAt, until: until,
                                                          declined: declined, held: held))
    }

    /// The user said "Yes, that's it": the candidate is checked again now
    /// (still there, still this run's folder and window, not declined, not
    /// held), then claimed under the same uniqueness as a verified id, the
    /// claim refusing a declined file in its own transaction. A check that
    /// can't be made claims nothing.
    public func confirm(_ handle: String, suggestion: CodexSuggestion) async -> Identity {
        switch await eligible(handle) {
        case .unavailable(let reason):
            return .inconclusive(.retry(reason))
        case .candidates(let current):
            guard current.contains(where: { $0.rolloutPath == suggestion.rolloutPath && $0.sessionID == suggestion.sessionID }) else {
                return .inconclusive(.retry("that session is no longer a candidate for this one"))
            }
            return await claim(handle, sessionID: suggestion.sessionID, how: .confirmed, rolloutPath: suggestion.rolloutPath)
        }
    }

    /// "Not this one": never offered again for this run.
    public func decline(_ handle: String, rolloutPath: String) async throws {
        try await write { try $0.decline(handle, rolloutPath: rolloutPath) }
    }

    /// The core join refused the id (another host's, or another agent's).
    public func releaseClaim(_ handle: String, sessionID: String) async throws {
        try await write { try $0.releaseClaim(handle, sessionID: sessionID) }
    }

    public func markJoined(_ handle: String) async throws {
        let now = now()
        try await write { try $0.markJoined(handle, at: now) }
    }

    /// Claims whose core join never happened, for the launch's reconciliation.
    public func unjoinedClaims() async -> [RemoteRun] {
        let host = host
        return await read { try $0.unjoinedClaims(host: host) } ?? []
    }

    /// The run's tab was typed into: kept, so a relaunch knows.
    public func recordInput(_ handle: String) async throws {
        let now = now()
        try await write { try $0.recordInput(handle, at: now) }
    }

    /// Pending runs (and claimed ones whose tab never reached `open_tabs`)
    /// to restore as chips.
    public func pendingRuns() async -> [RemoteRun] {
        let host = host
        return await read { try $0.pendingRuns(host: host) } ?? []
    }

    /// A pending run's tab was closed: it is not restored as a chip.
    public func closePendingTab(_ handle: String) async throws {
        let now = now()
        try await write { try $0.update(handle) { $0.tabClosedAt = now } }
    }

    /// Discard of a pending run: Temple stops tracking it (its transcript,
    /// if any, stays on the host).
    public func dismissRun(_ handle: String) async throws {
        let now = now()
        try await write { try $0.dismissRun(handle, at: now) }
    }
}
