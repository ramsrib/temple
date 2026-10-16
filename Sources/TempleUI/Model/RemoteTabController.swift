import Foundation
import TempleCore
import TempleTerminalAPI

// MARK: - Sessions on hosts (docs/designs/remote-ssh.md sections 3 to 5)
//
// Every tab on a host is driven from here: its open, its exit, its close,
// the quit's plan for it, and a host's retirement. `OpenSessionsModel`
// keeps only thin seams into this type (its tab list, the activity
// heuristics, the saved tab set), so deleting remote deletes this file
// rather than branches spread through the model ("Removing remote",
// section 9).
//
// Every asynchronous completion here takes a `RemoteTicket` before its
// awaits and passes `gate.admit` after the last one, right before it
// touches a tab, a row, a sheet or the saved tab set (`RemoteCompletion`
// lists them). Durable writes of outcomes happen in the host's own calls,
// whatever the gate says.

@MainActor
public final class RemoteTabController {
    unowned let model: OpenSessionsModel

    /// Every asynchronous operation on a host, owned through close, host
    /// changes and quit.
    public let operations = RemoteOperations()
    /// The one gate every remote completion passes before it touches a
    /// tab, a row, a sheet or the saved tab set.
    public let gate = RemoteEffectGate()

    /// A session on a host was left running when it was closed: one notice.
    public var noticeHandler: ((_ host: HostID, _ message: String) -> Void)?
    /// Discard on a session whose conversation was never confirmed: the
    /// app lets its row go (or archives it, if the row is the user's), only
    /// while the row is still the membership Discard was chosen for.
    public var discardHandler: ((_ sessionID: String, _ host: HostID, _ incarnation: String) throws -> Void)?
    /// A row's membership identity, read when Discard is chosen.
    public var rowIncarnation: (_ sessionID: String) -> String? = { _ in nil }

    /// Tabs whose host was removed or edited while connected: their exit
    /// asks nothing of the old host.
    var hostRetiredTabs: Set<SessionTab.ID> = []

    /// When a creation's records are fetched while its tab is connected
    /// (seconds after the spawn); the exit path collects once more.
    var recordPollDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
    /// How long a remote open may show no sign of life (no record, no
    /// title from tmux) before its tab says it is still connecting.
    var startupEvidenceDeadline: TimeInterval = 20

    init(model: OpenSessionsModel) {
        self.model = model
        gate.isQuitting = { [weak model] in model?.isQuitting ?? true }
        gate.launcher = { [weak model] host in model?.launcherForHost(host) as AnyObject? }
        gate.isMember = { [weak model] tab in model?.tabs.contains { $0 === tab } ?? false }
    }

    private var isQuitting: Bool { model.isQuitting }

    func remoteHost(for tab: SessionTab) -> RemoteSessionHost? {
        model.launcherForHost(tab.host) as? RemoteSessionHost
    }

    /// Whether a session on a host has a run there that is not Ended (as
    /// last read), for "Stop on <host>".
    public func hasRun(sessionID: String, host: HostID) -> Bool {
        (model.launcherForHost(host) as? RemoteSessionHost)?.hasLiveRun(sessionID: sessionID) ?? false
    }

    static func reconnectable(_ state: RemoteTabState) -> Bool {
        switch state.phase {
        case .disconnected, .unknown: true
        default: false
        }
    }

    // MARK: Open

    /// Opens a tab on a host: the host decides attach or create from the
    /// run (one transaction, recovering an uncollected record first) and
    /// writes the run before anything spawns. The open is owned: a host
    /// change or the quit cancels it, and an answer the gate refuses
    /// spawns nothing (a creation it planned is abandoned durably).
    func ensureSurface(for tab: SessionTab, on host: RemoteSessionHost, resumeAnyway: Bool,
                       startNew: Bool = false, resumeUnconfirmed: Bool = false) {
        // One open at a time: a second activation while the first decides
        // would race it for the same run.
        if tab.remote?.phase == .opening { return }
        guard let sid = tab.sessionID else {
            // A new Codex session: Codex mints the id, so the run starts
            // pending and is identified later (phase 1b).
            ensurePending(tab, on: host, startNew: false)
            return
        }
        // A session Temple already has on another host is not run here.
        if let conflict = model.openedHandler?(SessionOpen(id: sid, host: tab.host, via: tab.isResume ? .opened : .created,
                                                           agent: tab.agent, locator: tab.transcriptHint)).conflict {
            tab.launchPreparationError = conflict.message
            tab.activity = .exited(status: -1)
            return
        }
        var state = RemoteTabState(phase: .opening)
        state.resumedAfterAbsence = tab.remote?.resumedAfterAbsence ?? false
        tab.remote = state
        let ticket = gate.ticket(for: tab)
        let agent = tab.agent, directory = tab.projectPath
        // A tab that never sent anything started no transcript: its minted
        // id is used again, never resumed.
        let resume = (tab.isResume || tab.inputSubmitted || resumeAnyway || resumeUnconfirmed) && !startNew
        operations.run(host: tab.host, .open) { [weak self] in
            let result: Result<RemoteOpenResult, Error>
            do {
                result = .success(try await host.open(agent: agent, sessionID: sid, resume: resume, directory: directory,
                                                      resumeAnyway: resumeAnyway, startNew: startNew,
                                                      resumeUnconfirmed: resumeUnconfirmed))
            } catch {
                result = .failure(error)
            }
            guard let self, self.gate.admit(.openResult, ticket), let tab = ticket.tab else {
                if case .success(.plan(let plan)) = result, plan.creating { await host.abandon(plan.handle) }
                return
            }
            switch result {
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                TempleUILog.launch.error("remote open refused: \(error.localizedDescription, privacy: .public)")
                tab.remote = nil
                tab.launchPreparationError = error.localizedDescription
                tab.activity = .exited(status: -1)
            case .success(.needsDecision(let checked)):
                tab.remote?.phase = .needsDecision(checked: checked)
            case .success(.plan(let plan)):
                guard tab.surface == nil else {
                    if plan.creating { self.operations.run(host: tab.host, .write) { await host.abandon(plan.handle) } }
                    return
                }
                self.spawn(tab, plan: plan, host: host)
            }
        }
    }

    private func spawn(_ tab: SessionTab, plan: RemoteOpenPlan, host: RemoteSessionHost) {
        tab.remote?.handle = plan.handle
        tab.remote?.attachment = plan.attachment
        tab.remote?.creating = plan.creating
        tab.remote?.diagnostics = []
        tab.setLaunch(AgentLaunch(command: plan.command, displayArgv: plan.displayArgv, result: nil))
        let surface = model.surfaceFactory.makeSurface(appearance: model.appearanceProvider())
        surface.delegate = model
        let spawnedAt = model.now()
        tab.attach(surface: surface, at: spawnedAt)
        tab.remote?.phase = .connected
        do {
            try surface.start(TerminalIdentity.apply(to: plan.command))
        } catch {
            TempleUILog.launch.error("remote spawn failed: \(String(describing: error), privacy: .public)")
            if plan.creating { operations.run(host: tab.host, .write) { await host.abandon(plan.handle) } }
            tab.remote?.phase = .failedToStart(directory: tab.projectPath)
            tab.commandWasSuspect = true
            tab.activity = .exited(status: -1)
            return
        }
        // Only a created pane reports a folder; an attach replays what its
        // creation's pane reported, once persisted.
        tab.launchObservation = SessionTab.LaunchObservation(at: spawnedAt, directory: nil)
        if let sid = tab.sessionID, !isQuitting { model.touchHandler?(sid, tab.host, spawnedAt) }
        tab.activity = .running
        model.lastTitleChange[tab.id] = Date()
        model.scheduleSettle(for: tab)
        if plan.creating {
            pollRecords(tab, host: host, handle: plan.handle)
        } else if let directory = plan.evidenceDirectory {
            recordDirectory(tab, directory)
            tab.remote?.evidenceSeen = false
        }
        // A pending Codex run reattached: its `ok` is known, so the identity
        // schedule starts now (a creation's starts when its `ok` arrives).
        if isPending(tab), !plan.creating { startIdentity(tab, host: host, handle: plan.handle) }
        if let stage = plan.stage { stageAfterSpawn(tab, host: host, stage: stage, creating: plan.creating) }
        watchStartup(tab)
    }

    /// First contact: no master answered when the open was planned, so the
    /// tab's own ssh authenticates (the person may be asked) and becomes
    /// it; the launch is staged once it answers, over that master, never
    /// through the terminal. Cancelled when the tab's client ends. A
    /// refusal (nothing put in place) ends the client now, rather than let
    /// it wait out its own deadline; a creation's failure is already
    /// recorded, and the exit shows it.
    private func stageAfterSpawn(_ tab: SessionTab, host: RemoteSessionHost, stage: String, creating: Bool) {
        let ticket = gate.ticket(for: tab)
        tab.remote?.stageOperation = operations.run(host: tab.host, .open) { [weak self] in
            let outcome = await host.stage(stage)
            let notice: String?
            switch outcome {
            case .failed(let reason):
                notice = creating ? nil : RemoteCopy.couldNotPrepare(host.hostName, reason: reason)
            case .unrecorded(let detail):
                notice = RemoteCopy.unrecorded(host.hostName, detail: detail)
            case .staged, .unknown, .none:
                return
            }
            guard let self, self.gate.admit(.stageFailure, ticket), let tab = ticket.tab else { return }
            if let notice { self.noticeHandler?(ticket.host, notice) }
            if tab.hasLiveProcess { tab.surface?.terminate() }
        }
    }

    /// A remote open that shows no sign of life (no record, no title from
    /// tmux) within the startup deadline says so: "Still connecting to
    /// <host>…" with Cancel. Nothing else happens: no second run, and the
    /// run's state stays as unknown as it is.
    private func watchStartup(_ tab: SessionTab) {
        let ticket = gate.ticket(for: tab)
        let deadline = startupEvidenceDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let self, self.gate.admit(.startupDeadline, ticket), let tab = ticket.tab,
                  tab.remote?.phase == .connected, tab.remote?.evidenceSeen == false else { return }
            tab.remote?.stillConnecting = true
        }
    }

    /// While the tab is connected, the creation's `ok` is fetched on a
    /// bounded schedule; the folder is recorded the moment it arrives.
    private func pollRecords(_ tab: SessionTab, host: RemoteSessionHost, handle: String) {
        let delays = recordPollDelays
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .collect) { [weak self] in
            for delay in delays {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, ticket.tab?.remote?.phase == .connected else { return }
                let outcome = await host.collect(handle)
                switch outcome {
                case .ok(let directory):
                    let runAttachment = await host.attachment(of: handle)
                    guard let self, self.gate.admit(.pollDirectory, ticket, runAttachment: runAttachment),
                          let tab = ticket.tab else { return }
                    self.recordDirectory(tab, directory)
                    if self.isPending(tab) { self.startIdentity(tab, host: host, handle: handle) }
                    return
                case .storage(let detail):
                    guard let self, self.gate.admit(.storageNotice, ticket) else { return }
                    self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: detail))
                    return
                case .failedCD, .failedLaunch, .clientFailed:
                    return
                case .nothing, .transport:
                    continue
                }
            }
        }
    }

    /// The pane's `ok`: the folder becomes tab-sourced, through the one
    /// operation that keeps the row, the tab and its project in step.
    private func recordDirectory(_ tab: SessionTab, _ directory: String) {
        if tab.remote?.phase == .connected { tab.remote?.evidenceSeen = true; tab.remote?.stillConnecting = false }
        guard tab.launchObservation != nil, tab.launchObservation?.directory == nil else { return }
        tab.launchObservation?.directory = directory
        model.applyLaunchDirectory(tab, canonical: directory)
    }

    /// A title from a tab on a host is tmux drawing: the connection is up.
    func titleArrived(_ tab: SessionTab) {
        if tab.remote?.phase == .connected { tab.remote?.evidenceSeen = true; tab.remote?.stillConnecting = false }
    }

    // MARK: Exit

    /// The tab's ssh is a tmux client: its exit proves nothing. The final
    /// collection, then the exit check on the pinned server, decide; every
    /// effect on the tab passes the gate after its last await.
    func handleExit(_ tab: SessionTab, surface: TerminalSurface, status: Int32) {
        if let sid = tab.sessionID { model.touchHandler?(sid, tab.host, nil) }
        // The client is gone: a launch not yet staged never will be.
        if let staging = tab.remote?.stageOperation {
            operations.cancel(id: staging)
            tab.remote?.stageOperation = nil
        }
        if hostRetiredTabs.remove(tab.id) != nil {
            // The host was removed or edited: nothing is asked of the old one.
            tab.remote?.phase = .disconnected
            tab.activity = .exited(status: status)
            return
        }
        let userClosed = model.closingTabIDs.remove(tab.id) != nil
        if userClosed {
            // Detach and Stop now remove the tab; an explicit Stop keeps it
            // until its outcome is known.
            if tab.remote?.phase != .stopping { model.removeTab(tab.id) } else { tab.activity = .exited(status: status) }
            return
        }
        guard let host = remoteHost(for: tab), let state = tab.remote, let handle = state.handle else {
            tab.activity = .exited(status: status)
            return
        }
        let creating = state.creating
        let pending = isPending(tab)
        if let identity = state.identityOperation { operations.cancel(id: identity) }
        let age = tab.spawnedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        tab.remote?.lastSeenWorking = tab.activity == .running
        model.cancelSettle(for: tab.id)
        tab.remote?.phase = .checking
        tab.activity = .exited(status: status)
        let ticket = gate.ticket(for: tab)
        let grace = model.earlyExitGraceSeconds
        let early = age < grace
        operations.run(host: tab.host, .exitCheck) { [weak self] in
            var outcome = RemoteLaunchOutcome.nothing
            if creating {
                outcome = await host.collect(handle)
                switch outcome {
                case .ok(let directory):
                    let runAttachment = await host.attachment(of: handle)
                    if let self, self.gate.admit(.exitCollectDirectory, ticket, runAttachment: runAttachment),
                       let tab = ticket.tab {
                        self.recordDirectory(tab, directory)
                    }
                case .nothing, .transport, .clientFailed:
                    if let reason = await host.markCreationUnproven(handle) { outcome = .failedLaunch(reason) }
                case .storage(let detail):
                    if let self, self.gate.admit(.storageNotice, ticket) {
                        self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: detail))
                    }
                case .failedCD, .failedLaunch:
                    break
                }
            }
            if case .failedCD(let directory) = outcome {
                let runAttachment = await host.attachment(of: handle)
                guard let self, self.gate.admit(.exitFailedToStart, ticket, runAttachment: runAttachment),
                      let tab = ticket.tab else { return }
                tab.remote?.phase = .failedToStart(directory: directory)
                tab.launchFailure = LaunchFailure(category: .cdFailed,
                                                  message: RemoteCopy.cannotEnter(directory, host: host.hostName))
                return
            }
            if case .failedLaunch(let reason) = outcome {
                let runAttachment = await host.attachment(of: handle)
                guard let self, self.gate.admit(.exitFailedToStart, ticket, runAttachment: runAttachment),
                      let tab = ticket.tab else { return }
                tab.remote?.phase = .failedToStart(directory: tab.projectPath)
                tab.launchFailure = LaunchFailure(category: .transport,
                                                  message: RemoteCopy.launchFailed(host.hostName, reason: reason))
                return
            }
            // A pending Codex run is checked once more at its exit: its agent
            // may still be running there (a dropped connection).
            if pending, let self {
                let identity = await host.identify(handle)
                if case .adopted(let id, let directory) = identity {
                    await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
                } else if case .known(let id, let directory) = identity {
                    await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
                }
            }
            let liveness = await host.exitCheck(handle)
            let runAttachment = await host.attachment(of: handle)
            guard let self, self.gate.admit(.exitVerdict, ticket, runAttachment: runAttachment),
                  let tab = ticket.tab else { return }
            var wantDiagnostics = false
            switch liveness {
            case .present:
                tab.remote?.phase = .disconnected
            case .unknown(let reason):
                tab.remote?.phase = .unknown(reason: reason)
                // An agent that ended at once as the server's only session
                // takes the server with it, and the check can't tell; what
                // it printed is still shown, and proves nothing either way.
                wantDiagnostics = early
            case .absent:
                if !creating, !state.resumedAfterAbsence, early, tab.sessionID != nil {
                    // The attach found nothing there: the end is proven, so
                    // the session resumes from its transcript, once.
                    tab.remote?.resumedAfterAbsence = true
                    tab.dropSurface()
                    self.model.ensureSurface(for: tab)
                } else if early {
                    // An agent that died at once keeps its tab, with what it
                    // printed when that can be had.
                    tab.remote?.phase = .exitedEarly
                    wantDiagnostics = true
                } else if self.isPending(tab) {
                    // Codex finished before Temple learned its id: what was
                    // typed into it may be a conversation to identify; if
                    // nothing was, there is nothing to keep.
                    if tab.inputSubmitted {
                        tab.remote?.phase = .endedPending
                        self.loadSuggestions(tab, host: host, handle: handle)
                    } else {
                        self.model.removeTab(tab.id)
                        self.pendingWrite(host, tab.host) { try await host.dismissRun(handle) }
                    }
                } else {
                    // The agent finished: the tab closes, as a local one does.
                    self.model.removeTab(tab.id)
                }
            }
            guard wantDiagnostics else { return }
            let diagnosticsTicket = self.gate.ticket(for: tab)
            let raw = await host.diagnostics(handle)
            let diagnosticsAttachment = await host.attachment(of: handle)
            guard let raw, self.gate.admit(.exitDiagnostics, diagnosticsTicket, runAttachment: diagnosticsAttachment),
                  let tab = diagnosticsTicket.tab else { return }
            tab.remote?.diagnostics = RemoteCopy.diagnosticLines(raw)
        }
    }

    // MARK: Reconnect, Resume anyway, the unconfirmed conversation

    /// Opens a disconnected tab again: an attach, never a creation, while
    /// the run is not Ended.
    public func reconnect(_ tab: SessionTab) {
        guard tab.remote != nil, !tab.hasLiveProcess, !isQuitting else { return }
        tab.dropSurface()
        tab.launchPreparationError = nil
        tab.activity = .idle
        model.ensureSurface(for: tab)
    }

    /// The explicit way out of Unknown: a new run under a new handle that
    /// resumes the session; the old run is kept, so its Stop still works.
    public func resumeAnyway(_ tab: SessionTab) {
        guard let host = remoteHost(for: tab), tab.sessionID != nil, !tab.hasLiveProcess, !isQuitting else { return }
        tab.dropSurface()
        tab.launchPreparationError = nil
        tab.activity = .idle
        tab.remote?.phase = .disconnected
        ensureSurface(for: tab, on: host, resumeAnyway: true)
    }

    /// The command that stops this tab's run from the host itself, for the
    /// Resume anyway and Start a new session confirmations.
    public func stopCommand(_ tab: SessionTab) -> String? {
        guard let host = remoteHost(for: tab), let handle = tab.remote?.handle else { return nil }
        return host.manualStopCommand(handle: handle)
    }

    private func decisionPending(_ tab: SessionTab) -> Bool {
        if case .needsDecision? = tab.remote?.phase { return true }
        return false
    }

    /// Start a new session, for a session stopped with no transcript found
    /// (or none Temple could check): a fresh agent under the same id.
    public func startNewSession(_ tab: SessionTab) {
        guard let host = remoteHost(for: tab), decisionPending(tab), !isQuitting else { return }
        tab.dropSurface()
        tab.launchPreparationError = nil
        tab.activity = .idle
        tab.remote?.phase = .disconnected
        ensureSurface(for: tab, on: host, resumeAnyway: false, startNew: true)
    }

    /// Resume, offered only when Temple couldn't check for the transcript.
    public func resumeUnconfirmed(_ tab: SessionTab) {
        guard let host = remoteHost(for: tab), tab.remote?.phase == .needsDecision(checked: false), !isQuitting else { return }
        tab.dropSurface()
        tab.launchPreparationError = nil
        tab.activity = .idle
        tab.remote?.phase = .disconnected
        ensureSurface(for: tab, on: host, resumeAnyway: false, resumeUnconfirmed: true)
    }

    /// Discard: its runs are dismissed and its row let go (or archived, if
    /// the user named or kept it). The tab closes.
    /// Durable work, owned to its end: the runs are dismissed, then the
    /// row is let go (or archived) if it is still the membership Discard
    /// was chosen for. Quit, retirement or a closed window change nothing
    /// of that; only the failure notice passes the gate.
    public func discard(_ tab: SessionTab) {
        guard let host = remoteHost(for: tab), let sid = tab.sessionID, decisionPending(tab) else { return }
        let hostID = tab.host
        let ticket = gate.ticket(host: hostID)
        let incarnation = rowIncarnation(sid)
        // Held here, not looked up later: the disposition is durable work
        // and must not depend on this model outliving the window.
        let disposition = discardHandler
        model.removeTab(tab.id)
        model.forgetClosedTabs(sessionID: sid)
        operations.run(host: hostID, .write) { [weak self] in
            do {
                try await host.discard(sessionID: sid)
                if let incarnation { try disposition?(sid, hostID, incarnation) }
            } catch {
                guard let self, self.gate.admit(.discardNotice, ticket) else { return }
                self.noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
            }
        }
    }

    /// Cancel, on a tab still connecting past the startup deadline: its
    /// client goes; the exit check decides what is known; nothing is
    /// created in its place.
    public func cancelConnect(_ tab: SessionTab) {
        guard tab.remote?.phase == .connected, tab.hasLiveProcess, let surface = tab.surface else { return }
        tab.remote?.resumedAfterAbsence = true
        tab.remote?.stillConnecting = false
        surface.terminate()
    }

    // MARK: Close

    enum Close {
        /// ⌘W, ✕, the CLI: an idle agent is stopped now; a tab that is not
        /// connected stops it if the host answers. Either way the tab goes;
        /// the stop stays owned until its outcome is written, and a stop not
        /// confirmed leaves it running with one notice.
        case stopIfRunning
        /// The working prompt's Detach: the agent keeps working.
        case detach
        /// The working prompt's Stop: the tab stays until the outcome is known.
        case stop
    }

    public func confirmDetach() {
        guard let tab = model.pendingRemoteCloseTab else { model.pendingRemoteCloseTabID = nil; return }
        model.pendingRemoteCloseTabID = nil
        model.recordClosed(tab)
        close(tab, .detach)
    }

    public func confirmStop() {
        guard let tab = model.pendingRemoteCloseTab else { model.pendingRemoteCloseTabID = nil; return }
        model.pendingRemoteCloseTabID = nil
        model.recordClosed(tab)
        close(tab, .stop)
    }

    public func cancelClose() { model.pendingRemoteCloseTabID = nil }

    /// The command line's `close --force` on a working tab: detach, never stop.
    public func detach(_ tabID: SessionTab.ID) {
        guard !isQuitting, let tab = model.tabs.first(where: { $0.id == tabID }), tab.remote != nil else { return }
        model.recordClosed(tab)
        close(tab, .detach)
    }

    func close(_ tab: SessionTab, _ how: Close) {
        if isPending(tab), tab.remote?.handle != nil {
            closePending(tab, how)
            return
        }
        let host = remoteHost(for: tab)
        let handle = tab.remote?.handle
        let live = tab.hasLiveProcess
        let agent = tab.agent, hostID = tab.host
        // Temple's own client goes first, on this side (note 4); the stop
        // then requires that nobody is attached, in one server-side check.
        func detachClient() {
            guard live, let surface = tab.surface else { return }
            model.closingTabIDs.insert(tab.id)
            surface.terminate()
        }
        switch how {
        case .detach:
            detachClient()
            model.removeTab(tab.id)
        case .stopIfRunning:
            let mayRun = tab.remote?.mayBeRunning ?? false
            if case .stopFailed? = tab.remote?.phase {
                // Already left running and listed: closing just closes.
                model.removeTab(tab.id)
                return
            }
            detachClient()
            model.removeTab(tab.id)
            guard mayRun, let host, let handle else { return }
            let ticket = gate.ticket(host: hostID)
            startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: live) { [weak self] result in
                guard let self, self.gate.admit(.closeStopNotice, ticket) else { return }
                self.notice(result, host: host, hostID: hostID, agent: agent)
            }
        case .stop:
            guard let host, let handle else {
                detachClient()
                model.removeTab(tab.id)
                return
            }
            tab.remote?.phase = .stopping
            let ticket = gate.ticket(for: tab)
            let noticeTicket = gate.ticket(host: hostID)
            detachClient()
            startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: live) { [weak self] result in
                guard let self else { return }
                guard self.gate.admit(.explicitStopOutcome, ticket), let tab = ticket.tab else {
                    // The tab went meanwhile: what happened is said once, if
                    // the app is not quitting and the host is the same.
                    if self.gate.admit(.closeStopNotice, noticeTicket) {
                        self.notice(result, host: host, hostID: hostID, agent: agent)
                    }
                    return
                }
                switch result {
                case .stopped:
                    self.model.removeTab(tab.id)
                case .leftRunning(let reason, let detail):
                    tab.remote?.phase = .stopFailed(reason == .anotherClientAttached
                        ? RemoteCopy.leftRunning(host.hostName, agent: agent, reason: reason, detail: detail)
                        : RemoteCopy.couldNotStop(host.hostName, agent: agent,
                                                  reason: detail ?? "the host didn't confirm the stop"))
                case .unrecorded(let detail):
                    tab.remote?.phase = .stopFailed(RemoteCopy.unrecorded(host.hostName, detail: detail))
                }
            }
        }
    }

    /// A stop, owned until its outcome is written. Cancelled before its
    /// answer (the host changed, the quit's window closed), it is recorded
    /// left running with the canceller's reason; never retried. The
    /// completion is UI only: each caller gates it.
    private func startStop(host: RemoteSessionHost, hostID: HostID, handle: String, fromAttachedTab: Bool,
                           completion: @escaping @MainActor (RemoteStopResult) -> Void) {
        operations.run(host: hostID, .stop, onCancel: { reason in
            await host.leaveRunning(handle, reason: reason)
        }) {
            guard let result = try? await host.stop(handle, fromAttachedTab: fromAttachedTab) else { return }
            completion(result)
        }
    }

    private func notice(_ result: RemoteStopResult, host: RemoteSessionHost, hostID: HostID, agent: Agent) {
        switch result {
        case .stopped:
            break
        case .leftRunning(let reason, let detail):
            noticeHandler?(hostID, RemoteCopy.leftRunning(host.hostName, agent: agent, reason: reason, detail: detail))
        case .unrecorded(let detail):
            noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: detail))
        }
    }

    /// "Stop on <host>" from a row's menu: through its tab when it has a
    /// connected one (Temple's client is detached first), otherwise with no
    /// Temple client attached.
    public func stopSession(sessionID: String, host hostID: HostID) {
        if let tab = model.tabs.first(where: { $0.kind == .session && $0.sessionID == sessionID && $0.host == hostID }),
           tab.remote != nil {
            model.recordClosed(tab)
            close(tab, tab.hasLiveProcess ? .stop : .stopIfRunning)
            return
        }
        guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { return }
        let agent = model.sessionRow(sessionID)?.agent ?? .claude
        let ticket = gate.ticket(host: hostID)
        operations.run(host: hostID, .query) { [weak self] in
            guard let handle = await host.liveRunHandle(sessionID: sessionID), !Task.isCancelled, let self,
                  self.gate.launcher(hostID).map(ObjectIdentifier.init) == ticket.launcher else { return }
            self.startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: false) { [weak self] result in
                guard let self, self.gate.admit(.rowStopNotice, ticket) else { return }
                self.notice(result, host: host, hostID: hostID, agent: agent)
            }
        }
    }

    /// Stop, from "Sessions on <host>": a tracked run, no Temple client
    /// attached (a connected tab of it is stopped through the tab). The
    /// stop is owned here, so closing the sheet abandons nothing; the
    /// sheet gates its own completion.
    public func stopTracked(handle: String, host hostID: HostID, agent: Agent,
                            completion: @escaping @MainActor (RemoteStopResult) -> Void) {
        guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { return }
        if let tab = model.tabs.first(where: { $0.host == hostID && $0.remote?.handle == handle }), tab.hasLiveProcess {
            tab.remote?.phase = .stopping
            let ticket = gate.ticket(for: tab)
            model.closingTabIDs.insert(tab.id)
            tab.surface?.terminate()
            startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: true) { [weak self] result in
                if let self, self.gate.admit(.trackedStopTabOutcome, ticket), let tab = ticket.tab {
                    if result == .stopped { self.model.removeTab(tab.id) } else { tab.remote?.phase = .disconnected }
                }
                completion(result)
            }
            return
        }
        startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: false, completion: completion)
    }

    // MARK: A host removed or edited

    /// Retires a host's connection context before its registry entry goes:
    /// its launcher queries nothing more, every operation of its is
    /// cancelled (a stop recorded left running), every ticket taken for it
    /// fails the gate (its launcher is no longer the host's), and connected
    /// tabs are detached (their agents keep running; the next Open uses
    /// whatever the host is now).
    public func retireHost(_ hostID: HostID) {
        (model.launcherForHost(hostID) as? RemoteSessionHost)?.retire()
        operations.cancel(host: hostID)
        for tab in model.tabs where tab.kind == .session && tab.host == hostID && tab.remote != nil {
            tab.remote?.openToken = UUID()
            if tab.remote?.handle == nil {
                tab.remote = nil
                continue
            }
            if tab.hasLiveProcess, let surface = tab.surface {
                hostRetiredTabs.insert(tab.id)
                surface.terminate()
            } else if tab.remote?.phase == .checking || tab.remote?.phase == .stopping {
                tab.remote?.phase = .disconnected
            }
        }
    }

    // MARK: Quit

    /// The quit began: what only looks (opens, polls, checks, queries) is
    /// cancelled; stops already running carry on inside the window.
    func quitBegan() { operations.cancelForQuit() }

    /// The quit's plan for one tab on a host: a working agent is detached
    /// at once (no exit input, which would reach it through tmux), so its
    /// surface is returned; an idle one, or one whose client had already
    /// ended while it was idle, is stopped by the one-command stop when its
    /// host has a live master, and left running when it has none or the
    /// window closes first. No completion touches a tab from here on: the
    /// gate refuses everything while quitting.
    func quitPlan(for tab: SessionTab, state: RemoteTabState) -> TerminalSurface? {
        // A pending Codex run follows the same policy (round 1): a working
        // agent is detached, an idle one stopped. Stopped, one that was typed
        // into keeps its ended run, so the next launch asks about it; one
        // that never was is no longer tracked. A stop that fails is left
        // running, as any, and never retried.
        let dismissIfStopped = isPending(tab) && !tab.inputSubmitted
        guard let host = remoteHost(for: tab), let handle = state.handle else {
            if let surface = tab.surface, tab.hasLiveProcess { return surface }
            return nil
        }
        if let surface = tab.surface, tab.hasLiveProcess {
            if tab.activity == .running { return surface }
            startQuitStop(host: host, hostID: tab.host, handle: handle, surface: surface, dismissIfStopped: dismissIfStopped)
            return nil
        }
        switch state.phase {
        case .disconnected, .unknown, .checking:
            if !state.lastSeenWorking {
                startQuitStop(host: host, hostID: tab.host, handle: handle, surface: nil, dismissIfStopped: dismissIfStopped)
            }
        default:
            break
        }
        return nil
    }

    private func startQuitStop(host: RemoteSessionHost, hostID: HostID, handle: String, surface: TerminalSurface?,
                               dismissIfStopped: Bool = false) {
        operations.run(host: hostID, .stop, onCancel: { reason in
            surface?.terminate()
            await host.leaveRunning(handle, reason: reason)
        }) {
            guard await host.hasLiveMaster() else {
                surface?.terminate()
                await host.leaveRunning(handle, reason: .hostDidNotAnswer)
                return
            }
            surface?.terminate()
            let result = try? await host.stop(handle, fromAttachedTab: surface != nil)
            if dismissIfStopped, result == .stopped {
                do { try await host.dismissRun(handle) } catch {
                    TempleUILog.db.error("an unused pending run not dismissed at quit: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: Codex identity (docs/designs/remote-ssh.md section 3, phase 1b)

    /// A new Codex session on a host whose id Temple has not learned yet.
    func isPending(_ tab: SessionTab) -> Bool { tab.kind == .session && tab.sessionID == nil && tab.agent == .codex }

    /// The identity schedule, in seconds after the run's `ok` (then each
    /// minute while attached).
    var identitySchedule: [TimeInterval] = [2, 5, 15, 60]
    var identityInterval: TimeInterval = 60
    /// An activation checks again only when the last check is older.
    var activationRecheck: TimeInterval = 5
    private var lastIdentityCheck: [SessionTab.ID: Date] = [:]

    /// Opens a pending Codex session: a new run (no handle, or Start a new
    /// session), or the tab's own run by its handle (attach-only while it
    /// runs). Owned, and gated like every open.
    func ensurePending(_ tab: SessionTab, on host: RemoteSessionHost, startNew: Bool) {
        if tab.remote?.phase == .opening { return }
        let handle = startNew ? nil : tab.remote?.handle
        var state = RemoteTabState(phase: .opening)
        state.handle = handle
        state.suggestions = startNew ? [] : (tab.remote?.suggestions ?? [])
        tab.remote = state
        let ticket = gate.ticket(for: tab)
        let directory = tab.projectPath
        operations.run(host: tab.host, .open) { [weak self] in
            let result: Result<RemotePendingOpenResult, Error>
            do { result = .success(try await host.openPending(handle: handle, directory: directory)) } catch {
                result = .failure(error)
            }
            guard let self, self.gate.admit(.pendingOpenResult, ticket), let tab = ticket.tab else {
                if case .success(.plan(let plan)) = result, plan.creating { await host.abandon(plan.handle) }
                return
            }
            switch result {
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                TempleUILog.launch.error("remote pending open refused: \(error.localizedDescription, privacy: .public)")
                tab.remote = nil
                tab.launchPreparationError = error.localizedDescription
                tab.activity = .exited(status: -1)
            case .success(.ended):
                tab.remote?.phase = .endedPending
                tab.activity = .exited(status: 0)
                if let handle { self.loadSuggestions(tab, host: host, handle: handle) }
            case .success(.identified(let id, let directory)):
                // Another Temple learned its id meanwhile: this tab is that
                // session now (joined like any claim), then opened as any
                // session is. The open this answered is over.
                tab.remote?.phase = .disconnected
                guard let handle else { return }
                await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
                guard tab.sessionID == id, self.model.tabs.contains(where: { $0 === tab }) else { return }
                tab.remote = nil
                self.model.ensureSurface(for: tab)
            case .success(.plan(let plan)):
                guard tab.surface == nil else {
                    if plan.creating { self.operations.run(host: tab.host, .write) { await host.abandon(plan.handle) } }
                    return
                }
                self.spawn(tab, plan: plan, host: host)
            }
        }
    }

    /// The bounded schedule (2, 5, 15 and 60 s after `ok`, then each minute
    /// while attached): each check owned, one host's checks serial (the
    /// host's own queue). Ends when the tab has its id, closes or detaches.
    private func startIdentity(_ tab: SessionTab, host: RemoteSessionHost, handle: String) {
        if let running = tab.remote?.identityOperation { operations.cancel(id: running) }
        let ticket = gate.ticket(for: tab)
        var delays: [TimeInterval] = []
        var previous: TimeInterval = 0
        for at in identitySchedule {
            delays.append(max(0, at - previous))
            previous = at
        }
        let interval = identityInterval
        tab.remote?.identityOperation = operations.run(host: tab.host, .identity) { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let delay = index < delays.count ? delays[index] : interval
                index += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let tab = ticket.tab, tab.remote?.phase == .connected,
                      self?.isPending(tab) == true else { return }
                guard let self, await self.checkIdentity(ticket, host: host, handle: handle) else { continue }
                return
            }
        }
    }

    /// One check; true when the tab's identity is settled (it has its id).
    @discardableResult
    private func checkIdentity(_ ticket: RemoteTicket, host: RemoteSessionHost, handle: String) async -> Bool {
        if let id = ticket.tab?.id { lastIdentityCheck[id] = Date() }
        let identity = await host.identify(handle)
        switch identity {
        case .adopted(let id, let directory), .known(let id, let directory):
            await adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
            // Settled only once the tab is that session: a join that core
            // refused or failed to write is tried again on schedule.
            guard let tab = ticket.tab else { return true }
            return !isPending(tab)
        case .taken:
            guard gate.admit(.identityResult, ticket), let tab = ticket.tab else { return false }
            tab.remote?.identityNote = RemoteCopy.couldNotTell
            await loadSuggestions(ticket, host: host, handle: handle)
            return false
        case .storage(let detail):
            guard gate.admit(.identityNotice, ticket) else { return false }
            noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: detail))
            return false
        case .inconclusive(_, let lasting, let ended):
            // The question is asked once the automatic check can't answer:
            // for good (no /proc, a shared Codex server), when the agent
            // ended, or once something was typed (Codex writes its session
            // file from the first prompt).
            if lasting || ended || ticket.tab?.inputSubmitted == true {
                await loadSuggestions(ticket, host: host, handle: handle)
            }
            return false
        }
    }

    /// Activating a connected pending tab checks again (not more than once
    /// in a few seconds).
    func activated(_ tab: SessionTab) {
        guard isPending(tab), tab.remote?.phase == .connected, let handle = tab.remote?.handle,
              let host = remoteHost(for: tab) else { return }
        if let last = lastIdentityCheck[tab.id], Date().timeIntervalSince(last) < activationRecheck { return }
        lastIdentityCheck[tab.id] = Date()
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .identity) { [weak self] in
            await self?.checkIdentity(ticket, host: host, handle: handle)
        }
    }

    /// A claimed id (verified, or the user's yes). The claim is written;
    /// the core join and the row's folder are durable work too (only the
    /// quit defers them, to the next launch's reconciliation). A join core
    /// refuses releases the claim and the tab says why. The tab becomes the
    /// session through the gate.
    private func adopted(_ id: String, directory: String?, handle: String, host: RemoteSessionHost,
                         ticket: RemoteTicket) async {
        let hostID = ticket.host
        // While quitting the join waits for the next launch (the claim
        // stays unjoined); the gate below refuses the tab's part.
        if !isQuitting {
            let open = SessionOpen(id: id, host: hostID, via: .created, agent: .codex, locator: nil)
            switch model.openedHandler?(open) ?? .joined {
            case .joined:
                if let directory { model.launchDirectoryHandler?(id, hostID, directory) }
                operations.run(host: hostID, .write) {
                    do { try await host.markJoined(handle) } catch {
                        // Unmarked, the next launch joins it again (idempotent).
                        TempleUILog.db.error("claim not marked joined: \(error.localizedDescription, privacy: .public)")
                    }
                }
            case .refused(let conflict):
                TempleUILog.launch.notice("remote Codex id refused by core: \(conflict.message, privacy: .public)")
                pendingWrite(host, hostID) { try await host.releaseClaim(handle, sessionID: id) }
                guard gate.admit(.identityResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.identityNote = conflict.message
                tab.remote?.confirming = nil
                return
            case .failed(let error):
                // Core's row was not written: the claim stays unjoined, and
                // the next check (or the next launch) joins it again. The
                // tab stays pending and says so.
                TempleUILog.db.error("core join of a claimed Codex id failed: \(error.localizedDescription, privacy: .public)")
                guard gate.admit(.identityResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.identityNote = RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription)
                tab.remote?.confirming = nil
                return
            }
        }
        guard gate.admit(.identityResult, ticket), let tab = ticket.tab, isPending(tab) else { return }
        let ended = tab.remote?.phase == .endedPending
        becomeSession(tab, id: id, host: host)
        if let at = tab.launchObservation?.at { model.touchHandler?(id, hostID, at) }
        if !tab.title.isEmpty, tab.title != tab.agent.newSessionTitle { model.titleHandler?(id, hostID, tab.title) }
        if ended {
            // Its run ended: the yes records who it was, nothing more. The
            // tab is that session's, at rest; resuming it is the user's
            // Resume (or opening its chip), never this answer's (round 1).
            tab.remote?.phase = .endedIdentified
            tab.activity = .idle
        }
    }

    /// The tab is that session from here on: in `open_tabs`, so its run is
    /// no longer restored from the runs (handed over, durably).
    private func becomeSession(_ tab: SessionTab, id: String, host: RemoteSessionHost) {
        tab.sessionID = id
        tab.isProvisional = false
        // A claimed id has a conversation (a session file): a later open
        // resumes it, never starts it again.
        tab.inputSubmitted = true
        tab.remote?.suggestions = []
        tab.remote?.identityNote = nil
        tab.remote?.confirming = nil
        if let operation = tab.remote?.identityOperation { operations.cancel(id: operation) }
        tab.remote?.identityOperation = nil
        model.persist()
        if let handle = tab.remote?.handle {
            pendingWrite(host, tab.host) { try await host.closePendingTab(handle) }
        }
    }

    /// A pending run's durable write, owned through close and quit; one
    /// that fails is said once (never swallowed).
    private func pendingWrite(_ host: RemoteSessionHost, _ hostID: HostID,
                              _ body: @escaping @MainActor () async throws -> Void) {
        let ticket = gate.ticket(host: hostID)
        operations.run(host: hostID, .write) { [weak self] in
            do { try await body() } catch {
                guard let self, self.gate.admit(.pendingWriteNotice, ticket) else { return }
                self.noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
            }
        }
    }

    /// The same, inside an operation already owned.
    private func reportWrite(_ host: RemoteSessionHost, _ ticket: RemoteTicket,
                             _ body: @MainActor () async throws -> Void) async {
        do { try await body() } catch {
            guard gate.admit(.pendingWriteNotice, ticket) else { return }
            noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
        }
    }

    /// Something was typed into a pending tab: kept with its run, so a
    /// relaunch still knows the conversation may exist.
    func inputSubmitted(_ tab: SessionTab) {
        guard isPending(tab), let handle = tab.remote?.handle, tab.remote?.inputRecorded == false,
              let host = remoteHost(for: tab) else { return }
        tab.remote?.inputRecorded = true
        pendingWrite(host, tab.host) { try await host.recordInput(handle) }
    }

    private func loadSuggestions(_ tab: SessionTab, host: RemoteSessionHost, handle: String) {
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .query) { [weak self] in
            await self?.loadSuggestions(ticket, host: host, handle: handle)
        }
    }

    private func loadSuggestions(_ ticket: RemoteTicket, host: RemoteSessionHost, handle: String) async {
        let answer = await host.suggestions(handle)
        guard gate.admit(.suggestionsLoaded, ticket), let tab = ticket.tab, isPending(tab) else { return }
        if case .candidates(let found) = answer { tab.remote?.suggestions = found }
    }

    /// "Yes, that's it": the claim is durable work (owned through close and
    /// quit); what the tab shows passes the gate.
    public func confirm(_ suggestion: RemoteSuggestion, in tab: SessionTab) {
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab),
              tab.remote?.confirming == nil, !isQuitting else { return }
        tab.remote?.confirming = suggestion.id
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .write) { [weak self] in
            let identity = await host.confirm(handle, suggestion: suggestion)
            guard let self else { return }
            switch identity {
            case .adopted(let id, let directory), .known(let id, let directory):
                await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
            case .taken, .inconclusive:
                guard self.gate.admit(.confirmResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.confirming = nil
                tab.remote?.suggestions.removeAll { $0.id == suggestion.id }
                tab.remote?.identityNote = RemoteCopy.couldNotTell
            case .storage(let detail):
                guard self.gate.admit(.confirmResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.confirming = nil
                tab.remote?.identityNote = RemoteCopy.unrecorded(host.hostName, detail: detail)
            }
        }
    }

    /// "Not this one": gone from the tab at once, and never offered again
    /// for this run (durable).
    public func decline(_ suggestion: RemoteSuggestion, in tab: SessionTab) {
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab) else { return }
        tab.remote?.suggestions.removeAll { $0.id == suggestion.id }
        let ticket = gate.ticket(host: tab.host)
        operations.run(host: tab.host, .write) { [weak self] in
            do { try await host.decline(handle, rolloutPath: suggestion.rolloutPath) } catch {
                guard let self, self.gate.admit(.identityNotice, ticket) else { return }
                self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
            }
        }
    }

    /// Start a new session, for a pending Codex session that ended
    /// unidentified (its run is dismissed) or that Temple can't reach (its
    /// run is kept, listed under Sessions on <host> for Stop, its tab
    /// closed): a new run under a new handle, a new Codex session.
    public func startNewPending(_ tab: SessionTab) {
        guard isPending(tab), let host = remoteHost(for: tab), !tab.hasLiveProcess, !isQuitting else { return }
        if let old = tab.remote?.handle {
            let ended = tab.remote?.phase == .endedPending
            pendingWrite(host, tab.host) {
                if ended { try await host.dismissRun(old) } else { try await host.closePendingTab(old) }
            }
        }
        tab.dropSurface()
        tab.launchPreparationError = nil
        tab.activity = .idle
        tab.inputSubmitted = false
        ensurePending(tab, on: host, startNew: true)
    }

    /// Discard of a pending Codex session: Temple stops tracking it (its
    /// transcript stays on the host). Durable work; only the failure
    /// notice passes the gate.
    public func discardPending(_ tab: SessionTab) {
        guard isPending(tab), let host = remoteHost(for: tab) else { return }
        let handle = tab.remote?.handle
        let ticket = gate.ticket(host: tab.host)
        model.removeTab(tab.id)
        guard let handle else { return }
        operations.run(host: tab.host, .write) { [weak self] in
            do { try await host.dismissRun(handle) } catch {
                guard let self, self.gate.admit(.pendingDiscardNotice, ticket) else { return }
                self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
            }
        }
    }

    /// Closing a pending Codex tab. Detach keeps it running (listed under
    /// Sessions on <host>, where it can be opened again). A stop (an idle
    /// close, or the prompt's Stop) checks its identity one last time while
    /// its agent still runs, then stops it: identified, the tab closes as
    /// any does; unidentified with something typed, the tab stays with the
    /// question (Codex ended before Temple learned its id); with nothing
    /// typed, there is nothing to keep and Temple stops tracking it.
    private func closePending(_ tab: SessionTab, _ how: Close) {
        guard let host = remoteHost(for: tab), let handle = tab.remote?.handle else {
            model.removeTab(tab.id)
            return
        }
        let hostID = tab.host, live = tab.hasLiveProcess, typed = tab.inputSubmitted
        if let identity = tab.remote?.identityOperation { operations.cancel(id: identity) }
        func detachClient() {
            guard live, let surface = tab.surface else { return }
            model.closingTabIDs.insert(tab.id)
            surface.terminate()
        }
        let phase = tab.remote?.phase
        if how == .detach {
            detachClient()
            model.removeTab(tab.id)
            pendingWrite(host, hostID) { try await host.closePendingTab(handle) }
            return
        }
        if case .stopFailed? = phase {
            model.removeTab(tab.id)
            pendingWrite(host, hostID) { try await host.closePendingTab(handle) }
            return
        }
        guard tab.remote?.mayBeRunning == true else {
            // Nothing runs (it ended, never started, or failed at once):
            // closing it is being done with it.
            model.removeTab(tab.id)
            pendingWrite(host, hostID) { try await host.dismissRun(handle) }
            return
        }
        tab.remote?.phase = .stopping
        let ticket = gate.ticket(for: tab)
        let noticeTicket = gate.ticket(host: hostID)
        let agent = tab.agent
        detachClient()
        operations.run(host: hostID, .stop, onCancel: { reason in
            await host.leaveRunning(handle, reason: reason)
        }) { [weak self] in
            // The last chance to learn its id: its agent still runs.
            let identity = await host.identify(handle)
            var identified = false
            if case .adopted(let id, let directory) = identity, let self {
                await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
                identified = true
            } else if case .known(let id, let directory) = identity, let self {
                await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket)
                identified = true
            }
            guard let result = try? await host.stop(handle, fromAttachedTab: live) else { return }
            // Durable: nothing typed and nothing learned, and it stopped:
            // there is nothing to keep.
            guard let self else { return }
            if result == .stopped, !identified, !typed {
                await self.reportWrite(host, noticeTicket) { try await host.dismissRun(handle) }
            }
            if case .leftRunning = result {
                await self.reportWrite(host, noticeTicket) { try await host.closePendingTab(handle) }
            }
            guard self.gate.admit(.pendingStopOutcome, ticket), let tab = ticket.tab else {
                if self.gate.admit(.closeStopNotice, noticeTicket) { self.notice(result, host: host, hostID: hostID, agent: agent) }
                return
            }
            switch result {
            case .stopped:
                if !self.isPending(tab) || !typed {
                    self.model.removeTab(tab.id)
                } else {
                    tab.remote?.phase = .endedPending
                    self.loadSuggestions(tab, host: host, handle: handle)
                }
            case .leftRunning:
                self.model.removeTab(tab.id)
                self.notice(result, host: host, hostID: hostID, agent: agent)
            case .unrecorded(let detail):
                tab.remote?.phase = .stopFailed(RemoteCopy.unrecorded(host.hostName, detail: detail))
            }
        }
    }

    /// At launch: the pending Codex runs of each host come back as chips
    /// (inert until activated, which attaches; an ended one asks).
    public func restorePending(hosts: [HostID]) {
        for hostID in hosts {
            guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { continue }
            let ticket = gate.ticket(host: hostID)
            operations.run(host: hostID, .query) { [weak self] in
                let runs = await host.pendingRuns()
                guard let self, !runs.isEmpty, self.gate.admit(.pendingRestore, ticket) else { return }
                for run in runs where !self.model.tabs.contains(where: { $0.host == hostID && $0.remote?.handle == run.handle }) {
                    if let id = run.sessionID {
                        // Claimed after its tab set was saved: restored as
                        // that session's chip, then handed over to open_tabs.
                        if !self.model.tabs.contains(where: { $0.sessionID == id }) {
                            self.model.appendClaimedChip(host: hostID, sessionID: id, directory: run.directory)
                            self.model.persist()
                        }
                        let handle = run.handle
                        self.pendingWrite(host, hostID) { try await host.closePendingTab(handle) }
                        continue
                    }
                    self.model.appendPendingChip(host: hostID, handle: run.handle, directory: run.directory,
                                                 ended: run.ended, typed: run.typed)
                }
            }
        }
    }

    /// At launch: a claim whose core join never happened (a quit or crash
    /// between the two writes) is joined again; core's refusal releases it.
    /// Durable work, outside the gate (see `RemoteCompletion`).
    public func reconcileClaims(hosts: [HostID]) {
        for hostID in hosts {
            guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { continue }
            operations.run(host: hostID, .query) { [weak self] in
                let claims = await host.unjoinedClaims()
                for claim in claims {
                    guard let self, !self.isQuitting, !Task.isCancelled else { return }
                    let open = SessionOpen(id: claim.sessionID, host: hostID, via: .created, agent: .codex, locator: nil)
                    switch self.model.openedHandler?(open) ?? .joined {
                    case .joined:
                        if let directory = claim.directory { self.model.launchDirectoryHandler?(claim.sessionID, hostID, directory) }
                        do { try await host.markJoined(claim.handle) } catch {
                            TempleUILog.db.error("claim not marked joined: \(error.localizedDescription, privacy: .public)")
                        }
                    case .refused:
                        do { try await host.releaseClaim(claim.handle, sessionID: claim.sessionID) } catch {
                            TempleUILog.db.error("refused claim not released: \(error.localizedDescription, privacy: .public)")
                        }
                    case .failed(let error):
                        // Not written: left unjoined for the next launch.
                        TempleUILog.db.error("reconciliation join failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// "Open" on a pending Codex session in Sessions on <host>: its tab, or
    /// a chip for it, activated (which attaches).
    public func openPendingRun(handle: String, host hostID: HostID, directory: String) {
        if let tab = model.tabs.first(where: { $0.host == hostID && $0.remote?.handle == handle }) {
            model.activate(tab)
            return
        }
        let tab = model.appendPendingChip(host: hostID, handle: handle, directory: directory, ended: false)
        model.activate(tab)
    }
}
