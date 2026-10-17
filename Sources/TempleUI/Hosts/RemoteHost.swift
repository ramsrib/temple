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
    /// Its source reads the transcripts of the sessions Temple has rows for
    /// (enrichment, phase 2) over the same connection; its launcher runs
    /// sessions there under the hidden tmux server.
    @MainActor static func remote(_ record: RemoteHostRecord,
                                  availability: @escaping (Agent) -> LaunchAvailability,
                                  extraArgs: @escaping (Agent) -> [String] = { _ in [] },
                                  stateDirectory: URL = TempleState.directory) -> HostRegistry.Entry {
        let sessions = RemoteSessions(record: record, stateDirectory: stateDirectory,
                                      sshPath: RemoteHostComposition.sshPath,
                                      store: { try RemoteHostComposition.store(in: stateDirectory) },
                                      storeExists: { RemoteHostComposition.storeExists(in: stateDirectory) })
        return HostRegistry.Entry(source: RemoteSessionSource(sessions: sessions),
                                  launcher: RemoteHostLauncher(sessions: sessions, availability: availability,
                                                               extraArgs: extraArgs))
    }
}

/// A host's launcher: every open, exit, close and stop of a session there,
/// through the host's `RemoteSessions`. `availability` is the last test's
/// proof (`.unavailable` only when a test connected and a CLI or tmux did
/// not run). A new Codex session starts pending and is identified by its
/// process tree or by the user's yes (phase 1b).
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

    func availability(_ agent: Agent) -> LaunchAvailability { check(agent) }

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
        case .storage(let reason): .unrecorded(reason)
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
                                            : nil,
                                        directory: tracked.run.directory ?? tracked.run.directoryIntent)
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

    // MARK: Codex identity

    func openPending(handle: String?, directory: String) async throws -> RemotePendingOpenResult {
        let outcome = try await sessions.openPending(handle: handle, directory: directory, extraArguments: extraArgs(.codex))
        await refreshLiveSessions()
        switch outcome {
        case .ended: return .ended
        case .identified(let handle, let id): return .identified(id, directory: await sessions.run(handle)?.directory)
        case .plan(let plan):
            return .plan(RemoteOpenPlan(handle: plan.handle, attachment: plan.attachment, creating: plan.creating,
                                        command: TerminalCommand(argv: plan.argv, cwd: NSHomeDirectory()),
                                        displayArgv: plan.agentArgv, evidenceDirectory: plan.evidenceDirectory,
                                        stage: plan.staged ? nil : plan.stage))
        }
    }

    func identify(_ handle: String) async -> RemoteIdentity {
        await identity(await sessions.identify(handle), handle: handle)
    }

    private func identity(_ answer: RemoteSessions.Identity, handle: String) async -> RemoteIdentity {
        switch answer {
        case .adopted(let id):
            await refreshLiveSessions()
            return .adopted(id, directory: await sessions.run(handle)?.directory)
        case .known(let id):
            return .known(id, directory: await sessions.run(handle)?.directory)
        case .taken:
            return .taken
        case .storage(let detail):
            return .storage(detail)
        case .inconclusive(let why):
            switch why {
            case .retry(let reason): return .inconclusive(reason, lasting: false, ended: false)
            case .lasting(let reason): return .inconclusive(reason, lasting: true, ended: false)
            case .ended(let reason): return .inconclusive(reason, lasting: false, ended: true)
            }
        }
    }

    func suggestions(_ handle: String) async -> RemoteSuggestions {
        switch await sessions.suggestions(handle) {
        case .unavailable(let reason): .unavailable(reason)
        case .candidates(let found):
            .candidates(found.map {
                RemoteSuggestion(rolloutPath: $0.rolloutPath, sessionID: $0.sessionID, firstPrompt: $0.firstPrompt,
                                 startedAt: $0.startedAt, directory: $0.directory, promptKnown: $0.promptKnown)
            })
        }
    }

    func confirm(_ handle: String, suggestion: RemoteSuggestion) async -> RemoteIdentity {
        await identity(await sessions.confirm(handle, suggestion: Self.candidate(suggestion)), handle: handle)
    }

    func autoConfirm(_ handle: String, suggestion: RemoteSuggestion) async -> RemoteIdentity {
        await identity(await sessions.confirm(handle, suggestion: Self.candidate(suggestion), automatic: true), handle: handle)
    }

    private static func candidate(_ suggestion: RemoteSuggestion) -> CodexSuggestion {
        CodexSuggestion(rolloutPath: suggestion.rolloutPath, sessionID: suggestion.sessionID,
                        firstPrompt: suggestion.firstPrompt, startedAt: suggestion.startedAt,
                        directory: suggestion.directory, promptKnown: suggestion.promptKnown)
    }

    func markAsked(_ handle: String) async throws { try await sessions.markAsked(handle) }

    func recordAutoLinkRow(_ handle: String, sessionID: String, incarnation: String) async throws {
        try await sessions.recordAutoLinkRow(handle, sessionID: sessionID, incarnation: incarnation)
    }

    func autoLink(of handle: String) async -> RemoteAutoLink? {
        guard let run = await sessions.run(handle), let link = run.autoLink, let id = run.sessionID,
              Array(id.utf8) == Array(link.sessionID.utf8) else { return nil }
        let suggestion = RemoteSuggestion(rolloutPath: link.rolloutPath, sessionID: link.sessionID,
                                          firstPrompt: link.firstPrompt, startedAt: link.startedAt,
                                          directory: link.directory, promptKnown: link.promptKnown)
        return RemoteAutoLink(suggestion: suggestion, sessionID: link.sessionID, createdIncarnation: link.incarnation)
    }

    func decline(_ handle: String, rolloutPath: String) async throws {
        try await sessions.decline(handle, rolloutPath: rolloutPath)
    }

    func releaseClaim(_ handle: String, sessionID: String) async throws {
        try await sessions.releaseClaim(handle, sessionID: sessionID)
        await refreshLiveSessions()
    }

    func markJoined(_ handle: String) async throws { try await sessions.markJoined(handle) }

    func unlink(_ handle: String, sessionID: String, rolloutPath: String) async throws {
        try await sessions.unlink(handle, sessionID: sessionID, rolloutPath: rolloutPath)
        await refreshLiveSessions()
    }

    func unjoinedClaims() async -> [(handle: String, sessionID: String, directory: String?)] {
        await sessions.unjoinedClaims().compactMap { run in run.sessionID.map { (run.handle, $0, run.directory) } }
    }

    func pendingRuns() async -> [RemotePendingRun] {
        await sessions.pendingRuns().map {
            RemotePendingRun(handle: $0.handle, directory: $0.directory ?? $0.directoryIntent, ended: $0.isEnded,
                             sessionID: $0.sessionID, typed: $0.inputSeenAt != nil, joined: $0.joinedAt != nil,
                             asked: $0.askedAt != nil)
        }
    }

    func closePendingTab(_ handle: String) async throws { try await sessions.closePendingTab(handle) }

    func dismissRun(_ handle: String) async throws {
        try await sessions.dismissRun(handle)
        await refreshLiveSessions()
    }

    func recordInput(_ handle: String) async throws { try await sessions.recordInput(handle) }

    func runLedger() -> RemoteRunLedger? { (try? sessions.store()).map(RemoteStoreLedger.init) }
}

/// `remote-state.sqlite`, written directly by run: what a hand-over
/// obligation holds, so retiring a run's fallback never needs the host's
/// registry entry or launcher (round 4).
@MainActor
final class RemoteStoreLedger: RemoteRunLedger {
    private let store: RemoteStateStore
    init(store: RemoteStateStore) { self.store = store }

    /// Only a run that still has an id: one whose claim was undone since
    /// ("Not this session") is restored by its handle again, and a late
    /// hand-over must not retire that.
    func markTabClosed(_ handle: String) async throws {
        let now = Date()
        _ = try await store.perform { try $0.update(handle) { if $0.sessionID != nil { $0.tabClosedAt = now } } }
    }
}

/// Remote project masks and order in `remote-state.sqlite`.
@MainActor
final class RemoteProjectStateStore: RemoteProjectStatePersisting {
    private let stateDirectory: URL
    init(stateDirectory: URL) { self.stateDirectory = stateDirectory }

    /// Whether the remote store file is there (asking creates nothing).
    static func exists(in stateDirectory: URL) -> Bool { RemoteHostComposition.storeExists(in: stateDirectory) }

    private var store: RemoteStateStore? { try? RemoteHostComposition.store(in: stateDirectory) }

    /// Reading creates no file: with none yet there is nothing to read.
    func projectStates() -> [(key: ProjectKey, archived: Bool, position: Int?)] {
        guard RemoteHostComposition.storeExists(in: stateDirectory) else { return [] }
        return ((try? store?.projectStates()) ?? []).map { (ProjectKey(host: $0.host, path: $0.path), $0.archived, $0.position) }
    }

    func setArchived(_ archived: Bool, key: ProjectKey) {
        // Unarchiving with no store yet has nothing to clear: no file.
        if !archived, !RemoteHostComposition.storeExists(in: stateDirectory) { return }
        do { try store?.setProjectArchived(archived, host: key.host, path: key.path) } catch {
            TempleUILog.db.error("remote project state not written: \(String(describing: error), privacy: .public)")
        }
    }

    func setOrder(_ keys: [(key: ProjectKey, position: Int)]) {
        // An order with no host's project in it (every local reorder while
        // no host has a project) only clears positions: with no store yet
        // there is nothing to clear, and no file is created for it.
        if keys.isEmpty, !RemoteHostComposition.storeExists(in: stateDirectory) { return }
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
