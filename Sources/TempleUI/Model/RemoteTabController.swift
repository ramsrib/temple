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
    public var discardHandler: ((_ sessionID: String, _ host: HostID, _ incarnation: String,
                                 _ lastOpenedAt: Date?) throws -> Void)?
    /// "Not this one" on a link Temple made on its own: the row the link
    /// created is archived, reversibly (a person's archive: History
    /// restores it).
    public var unlinkHandler: ((_ sessionID: String, _ host: HostID) -> Void)?
    /// A row's open state (`last_opened_at`), read when Discard is chosen:
    /// an Open after that keeps the row.
    public var rowLastOpened: (_ sessionID: String) -> Date? = { _ in nil }
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

    /// Whether this Temple has a live tab of the run: its client is
    /// running and connected ("In a tab" in Running sessions on <host>).
    public func hasLiveTab(handle: String, host: HostID) -> Bool {
        model.tabs.contains {
            $0.host == host && $0.remote?.handle == handle && $0.remote?.phase == .connected && $0.hasLiveProcess
        }
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
            // A saved tab of a session Not this one released (the quit came
            // before the tab set was saved without it): it is that run's tab,
            // never an open of the rejected session.
            if agent == .codex, let back = await host.handBacks().first(where: { $0.sessionID == sid }) {
                guard let self, self.gate.admit(.openResult, ticket), let tab = ticket.tab else { return }
                self.takeBack(tab, back.run, from: sid, host: host)
                return
            }
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
        model.markSpawned(tab, startsAgent: plan.creating)
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
            guard let self else { return }
            let name = ticket.tab.map(self.sessionName) ?? "this session"
            let notice: String?
            switch outcome {
            case .failed(let reason):
                notice = creating ? nil : RemoteCopy.couldNotReconnect(name, host: host.hostName, reason: reason)
            case .unrecorded(let detail):
                notice = RemoteCopy.unrecorded(host.hostName, detail: detail, session: name)
            case .staged, .unknown, .none:
                return
            }
            guard self.gate.admit(.stageFailure, ticket), let tab = ticket.tab else { return }
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
                    let name = ticket.tab.map(self.sessionName)
                    self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: detail, session: name))
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
                        let name = ticket.tab.map(self.sessionName)
                        self.noticeHandler?(ticket.host, RemoteCopy.unrecorded(host.hostName, detail: detail, session: name))
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

    /// Discard (B4, B5: "Remove from Temple" or "Archive session", said per
    /// row): one meaning, a session that is not running here. Its runs are
    /// dismissed and its row let go (or archived, if the user named, pinned
    /// or colored it, or it has a transcript); the tab closes. It never
    /// stops anything: a stop is "Stop on <host>" in the row's menu.
    /// Durable work, owned to its end: the runs are dismissed, then the
    /// row is let go (or archived) if it is still the membership Discard
    /// was chosen for. Quit, retirement or a closed window change nothing
    /// of that; only the failure notice passes the gate.
    public func discard(_ tab: SessionTab) {
        guard let host = remoteHost(for: tab), let sid = tab.sessionID, decisionPending(tab) else { return }
        let hostID = tab.host
        let ticket = gate.ticket(host: hostID)
        let incarnation = rowIncarnation(sid)
        let lastOpened = rowLastOpened(sid)
        let name = sessionName(tab)
        // Held here, not looked up later: the disposition is durable work
        // and must not depend on this model outliving the window.
        let disposition = discardHandler
        model.removeTab(tab.id)
        model.forgetClosedTabs(sessionID: sid)
        operations.run(host: hostID, .write) { [weak self] in
            do {
                try await host.discard(sessionID: sid)
                if let incarnation { try disposition?(sid, hostID, incarnation, lastOpened) }
            } catch {
                guard let self, self.gate.admit(.discardNotice, ticket) else { return }
                self.noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription, session: name))
            }
        }
    }

    /// "Not this one" on a link Temple made on its own (B11): the link is
    /// undone and the agent keeps running. The durable part comes first,
    /// in one write: the claim on that session id is released and the
    /// candidate declined for this run; the run's own restoration stays off
    /// and is owed back (a hand-back, the hand-over's reverse). Only once
    /// that has committed: the hand-over the link owed is dropped (a late
    /// retry of it can't mark the run, `markTabClosed`), the row the link
    /// created is archived (reversibly), and, through the gate, the tab
    /// becomes unidentified again, saying Temple couldn't tell (with Try
    /// again) until the question's candidates arrive. The hand-back is
    /// settled like a hand-over, whatever the gate says: by an acknowledged
    /// save of a tab set without the session (the run's restoration comes
    /// back), by the tab going first (a close or detach stands), or at the
    /// next launch (`restorePending`). A write that fails changes nothing:
    /// the tab is still that session, said once, and it can be tried again.
    public func unlink(_ tab: SessionTab) {
        guard tab.remote?.linkedOnItsOwn == true, tab.remote?.unlinking != true, let linked = tab.remote?.linkedSuggestion,
              let sid = tab.sessionID, let handle = tab.remote?.handle, let host = remoteHost(for: tab),
              !isQuitting else { return }
        let hostID = tab.host, tabID = tab.id
        tab.remote?.unlinking = true
        let ticket = gate.ticket(for: tab)
        let noticeTicket = gate.ticket(host: hostID)
        let archive = unlinkHandler
        operations.run(host: hostID, .write) { [weak self] in
            do {
                try await host.unlink(handle, sessionID: sid, rolloutPath: linked.rolloutPath)
            } catch {
                guard let self else { return }
                if self.gate.admit(.unlinkResult, ticket), let tab = ticket.tab { tab.remote?.unlinking = false }
                if self.gate.admit(.identityNotice, noticeTicket) {
                    self.noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: error.localizedDescription))
                }
                return
            }
            // Committed: durable from here, whatever the tab does.
            guard let self else { return }
            self.handOvers[handle] = nil
            self.oweHandBack(handle: handle, sessionID: sid, tabID: tabID, host: host, hostID: hostID)
            self.declinedHere[handle, default: []].insert(linked.id)
            archive?(sid, hostID)
            defer { self.settleHandOvers() }
            guard self.gate.admit(.unlinkResult, ticket), let tab = ticket.tab, tab.sessionID == sid else { return }
            self.becomePending(tab, handle: handle, from: sid)
            tab.remote?.unlinking = false
            tab.remote?.linkedOnItsOwn = false
            tab.remote?.linkedSuggestion = nil
            tab.remote?.confirming = nil
            tab.remote?.suggestions = []
            // Never bare: this stays until a query brings candidates.
            tab.remote?.identityNote = RemoteCopy.couldNotTell
            tab.remote?.unlinkFallback = true
            self.asked.insert(handle)
            self.settleHandOvers()
            await self.loadSuggestions(ticket, host: host, handle: handle)
        }
    }

    /// A saved tab of a session whose run Not this one handed back: it is
    /// that run's tab again (unidentified, by its handle), owed the
    /// hand-back from the next acknowledged save; `open` attaches it.
    private func takeBack(_ tab: SessionTab, _ run: RemotePendingRun, from sessionID: String, host: RemoteSessionHost,
                          open: Bool = true) {
        model.makePendingChip(tab, handle: run.handle, ended: run.ended, typed: run.typed)
        if run.typed { inputEvidence[run.handle] = .committed }
        asked.insert(run.handle)
        model.forgetClosedTabs(sessionID: sessionID)
        oweHandBack(handle: run.handle, sessionID: sessionID, tabID: tab.id, host: host, hostID: tab.host,
                    savesBefore: model.acknowledgedSaves)
        model.persist()
        settleHandOvers()
        guard open else { return }
        if run.ended {
            loadSuggestions(tab, host: host, handle: run.handle)
        } else {
            model.ensureSurface(for: tab)
        }
    }

    /// The tab is its run's again, unidentified: out of the saved tab set
    /// from the next save, which is what its hand-back waits for.
    private func becomePending(_ tab: SessionTab, handle: String, from sessionID: String) {
        tab.sessionID = nil
        tab.isProvisional = true
        model.forgetClosedTabs(sessionID: sessionID)
        handBacks[handle]?.savesBefore = model.acknowledgedSaves
        model.persist()
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
        let name = sessionName(tab)
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
                self.notice(result, host: host, hostID: hostID, session: name)
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
                        self.notice(result, host: host, hostID: hostID, session: name)
                    }
                    return
                }
                switch result {
                case .stopped:
                    self.model.removeTab(tab.id)
                case .leftRunning(let reason, let detail):
                    tab.remote?.phase = .stopFailed(reason == .anotherClientAttached
                        ? RemoteCopy.notStoppedAttached
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

    /// A stop that did not happen, said once in the sidebar, naming the
    /// session (its tab may be gone).
    private func notice(_ result: RemoteStopResult, host: RemoteSessionHost, hostID: HostID, session: String) {
        switch result {
        case .stopped:
            break
        case .leftRunning(let reason, let detail):
            noticeHandler?(hostID, RemoteCopy.leftRunning(host.hostName, session: session, reason: reason, detail: detail))
        case .unrecorded(let detail):
            noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: detail, session: session))
        }
    }

    /// A session's name as a notice gives it: its row's title in quotes,
    /// or "the new Codex session in temple".
    func sessionName(_ tab: SessionTab) -> String {
        let title = tab.sessionID.flatMap { model.sessionRow($0)?.displayTitle }
        return RemoteCopy.sessionName(title: title, agent: tab.agent, directory: tab.projectPath)
    }

    /// The tab of a session on a host whose agent is working (busy with a
    /// task) right now, by its session or its run: Stop asks first for
    /// such an agent (S12); one waiting for input, or with no live tab
    /// here, stops at once. Read as a close reads it.
    public func workingTab(host hostID: HostID, sessionID: String? = nil, handle: String? = nil) -> SessionTab? {
        guard let tab = model.tabs.first(where: { tab in
            tab.kind == .session && tab.host == hostID && tab.remote != nil
                && ((sessionID != nil && tab.sessionID == sessionID) || (handle != nil && tab.remote?.handle == handle))
        }), tab.hasLiveProcess else { return nil }
        if model.isAtRestNow(tab) { model.settleNow(tab) }
        return tab.activity == .running ? tab : nil
    }

    /// The Stop question's title for a working agent: "may still be
    /// working" for a tab reattached a moment ago (the close prompt's rule,
    /// `workingIsUncertain`), "is working" once that is known.
    public func stopQuestionTitle(host hostID: HostID, agent: Agent, sessionID: String? = nil, handle: String? = nil) -> String {
        let tab = model.tabs.first { tab in
            tab.kind == .session && tab.host == hostID && tab.remote != nil
                && ((sessionID != nil && tab.sessionID == sessionID) || (handle != nil && tab.remote?.handle == handle))
        }
        return RemoteCopy.stopWorkingTitle(hostID.rawValue, agent: agent, uncertain: tab.map(model.workingIsUncertain) ?? false)
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
        let row = model.sessionRow(sessionID)
        let name = RemoteCopy.sessionName(title: row?.displayTitle, agent: row?.agent ?? .claude,
                                          directory: row?.directory ?? "")
        let ticket = gate.ticket(host: hostID)
        operations.run(host: hostID, .query) { [weak self] in
            guard let handle = await host.liveRunHandle(sessionID: sessionID), !Task.isCancelled, let self,
                  self.gate.launcher(hostID).map(ObjectIdentifier.init) == ticket.launcher else { return }
            self.startStop(host: host, hostID: hostID, handle: handle, fromAttachedTab: false) { [weak self] result in
                guard let self, self.gate.admit(.rowStopNotice, ticket) else { return }
                self.notice(result, host: host, hostID: hostID, session: name)
            }
        }
    }

    /// Stop, from "Running sessions on <host>": a tracked run, no Temple client
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
    /// cancelled; stops a close already started carry on inside the window.
    func quitBegan() {
        operations.cancelForQuit()
        // The frozen tab set is written now: what it holds is handed over.
        settleHandOvers()
    }

    /// The quit's plan for one tab on a host: Temple stops no agent there,
    /// working or idle (owner's decision). A live client is detached at once
    /// (no exit input, which tmux would deliver to the agent), so its
    /// surface is returned; a tab with no live client needs nothing. Every
    /// run, a pending Codex one included, is left as it is and comes back
    /// as a tab next launch, where closing it stops it as any close does.
    /// No completion touches a tab from here on: the gate refuses
    /// everything while quitting.
    func quitPlan(for tab: SessionTab) -> TerminalSurface? {
        guard tab.remote != nil, let surface = tab.surface, tab.hasLiveProcess else { return nil }
        // Said once at the next launch ("from before you quit"), while it
        // is still running there and not open in a tab: a durable write,
        // which the quit's barrier waits for.
        if let host = remoteHost(for: tab), let handle = tab.remote?.handle, flaggedAtQuit.insert(handle).inserted {
            operations.run(host: tab.host, .write) { await host.leaveRunning(handle, reason: .detachedAtQuit) }
        }
        return surface
    }

    /// Runs flagged by this quit's plan (asked for more than once, a run
    /// is flagged once).
    private var flaggedAtQuit: Set<String> = []

    // MARK: Codex identity (docs/designs/remote-ssh.md section 3, phase 1b)

    /// A new Codex session on a host whose id Temple has not learned yet.
    func isPending(_ tab: SessionTab) -> Bool { tab.kind == .session && tab.sessionID == nil && tab.agent == .codex }

    /// Input evidence per pending run, kept by handle: whether "typed into"
    /// is written with the run (`committed`), being written, or not yet.
    enum InputEvidence { case none, inFlight, committed }
    private var inputEvidence: [String: InputEvidence] = [:]
    /// How many times, and how far apart, a failed input write is tried.
    var inputWriteRetries: [TimeInterval] = [0.5, 1]

    /// Ids core refused for a run (another host's or another agent's): not
    /// claimed again on schedule (round 2), only on the user's Try again or
    /// once the conflicting row has gone.
    private var refusedClaims: [String: (id: String, reason: String)] = [:]
    /// Runs handed over to `open_tabs` whose mark (`tab_closed_at`) is not
    /// written yet, by handle (round 4). Each holds the run store itself, so
    /// it is finished whatever becomes of its host; it is kept until the
    /// write commits, and finished when its tab set is written or its tab
    /// is gone: at the hand-over, at any tab's close, at the quit, and at
    /// the next launch's restore (where the run comes back and owes it
    /// again).
    private struct HandOver {
        let ledger: RemoteRunLedger
        /// The claim it is owed for: the mark is written only while the
        /// run still holds it (Not this one may release it meanwhile).
        let sessionID: String
        let hostID: HostID
        let hostName: String
        let tabID: SessionTab.ID
        /// The model's acknowledged saves when it was owed: a later one
        /// wrote the tab set with this tab in it (`.max`: none counts, only
        /// the tab's absence does).
        let savesBefore: Int
        var inFlight = false
        var said = false
    }
    private var handOvers: [String: HandOver] = [:]
    /// How many times, and how far apart, a hand-over's write is tried.
    var handOverRetries: [TimeInterval] = [0.5, 1]

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
        // A refusal this launch remembers for the run is said again whenever
        // it reopens, with Try again (round 3).
        if let handle, let refusal = refusedClaims[handle] {
            state.identityNote = refusal.reason
            state.identityRefused = true
        }
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
        // Core refused this run's id: the walk would find and claim it again,
        // and core would refuse again. The question still comes.
        if refusedClaims[handle] != nil {
            await loadSuggestions(ticket, host: host, handle: handle)
            return false
        }
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
    /// session through the gate. `titleHint`: the first prompt of the
    /// candidate the user said yes to, which the row shows until its
    /// transcript's title arrives (display only, through the gate).
    private func adopted(_ id: String, directory: String?, handle: String, host: RemoteSessionHost,
                         ticket: RemoteTicket, titleHint: String? = nil, linked: RemoteSuggestion? = nil) async {
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
                refusedClaims[handle] = (id, conflict.message)
                pendingWrite(host, hostID) { try await host.releaseClaim(handle, sessionID: id) }
                guard gate.admit(.identityResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.identityNote = conflict.message
                tab.remote?.identityRefused = true
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
        // Display only, so it is the tab's part: nothing after its close,
        // the quit or the host's retirement (sol round 4).
        if let titleHint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !titleHint.isEmpty {
            model.titleHintHandler?(id, titleHint)
        }
        if let at = tab.launchObservation?.at { model.touchHandler?(id, hostID, at) }
        // An ended tab's title is the terminal's last, never the session's
        // own: the transcript's fill titles the row (the hint until then).
        if tab.remote?.phase == .endedPending {
            concludeEnded(tab, id: id, host: host)
            return
        }
        if !tab.title.isEmpty, tab.title != tab.agent.newSessionTitle { model.titleHandler?(id, hostID, tab.title) }
        becomeSession(tab, id: id, host: host)
        // Temple's own yes says so, in the tab only, with Not this one.
        if let linked {
            tab.remote?.identityNote = RemoteCopy.linkedOnItsOwn(linked)
            tab.remote?.linkedOnItsOwn = true
            tab.remote?.linkedSuggestion = linked
        }
    }

    /// Its run ended: the yes records who it was (the claim and the join,
    /// already written), nothing more. The tab closes, as a local tab does
    /// when its agent exits, and the selection follows the active tab as
    /// after any close: the identified row, at the top of its project, is
    /// the way back, and resuming is the user's act, never this answer's
    /// (round 1). The tab never becomes the session, so no save of the tab
    /// set can hold a resumable tab of it: the run's own restoration is
    /// retired once the pending tab is gone (fix round).
    private func concludeEnded(_ tab: SessionTab, id: String, host: RemoteSessionHost) {
        let hostID = tab.host
        if let operation = tab.remote?.identityOperation { operations.cancel(id: operation) }
        tab.remote?.identityOperation = nil
        if let handle = tab.remote?.handle {
            refusedClaims[handle] = nil
            oweHandOver(handle: handle, sessionID: id, tabID: tab.id, host: host, hostID: hostID, untilGone: true)
        }
        // Its removal finishes the hand-over (`tabRemoved`).
        model.removeTab(tab.id)
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
        tab.remote?.identityRefused = false
        if let operation = tab.remote?.identityOperation { operations.cancel(id: operation) }
        tab.remote?.identityOperation = nil
        if let handle = tab.remote?.handle { refusedClaims[handle] = nil }
        // Handed over only once the tab set is written: until then the run
        // is what restores this tab (round 2).
        if let handle = tab.remote?.handle { handOver(tab, handle: handle, host: host) }
    }

    /// The run now restores through `open_tabs`: its own restoration is
    /// retired (`tab_closed_at`) once the tab set is written, or once the
    /// tab is gone, whichever comes first, and not before.
    private func handOver(_ tab: SessionTab, handle: String, host: RemoteSessionHost) {
        guard let sessionID = tab.sessionID,
              oweHandOver(handle: handle, sessionID: sessionID, tabID: tab.id, host: host, hostID: tab.host,
                          untilGone: false) else { return }
        // The tab set's ordinary save: its acknowledgement settles this.
        model.persist()
        settleHandOvers()
    }

    /// Records that the run's restoration is to be retired. `untilGone`:
    /// only once its tab is gone (a tab that never becomes the session, so
    /// no save of the tab set holds it); otherwise also once a save has.
    @discardableResult
    private func oweHandOver(handle: String, sessionID: String, tabID: SessionTab.ID, host: RemoteSessionHost, hostID: HostID,
                             untilGone: Bool) -> Bool {
        guard let ledger = host.runLedger() else {
            TempleUILog.db.error("no run store to hand a run over with; it stays restorable by its run")
            return false
        }
        handOvers[handle] = HandOver(ledger: ledger, sessionID: sessionID, hostID: hostID, hostName: host.hostName, tabID: tabID,
                                     savesBefore: untilGone ? .max : model.acknowledgedSaves)
        return true
    }

    /// The model's own save of the tab set was written (round 5: no save
    /// is made for a hand-over; it waits on the ones that happen anyway).
    func tabSetSaved() { settleHandOvers() }

    /// A tab went (closed, detached, discarded, on any host): every hand-over
    /// whose tab is gone is finished, and every one that failed is tried
    /// again.
    func tabRemoved(_ tab: SessionTab) { settleHandOvers() }

    /// Finishes each hand-over whose tab is gone, or whose tab set has been
    /// written since it was owed (an acknowledged save the model made
    /// anyway); one already being written is left to finish. Never saves.
    func settleHandOvers() {
        settleHandBacks()
        guard handOvers.values.contains(where: { !$0.inFlight }) else { return }
        let open = Set(model.tabs.map(\.id))
        let saves = model.acknowledgedSaves
        for (handle, obligation) in handOvers where !obligation.inFlight
            && (saves > obligation.savesBefore || !open.contains(obligation.tabID)) {
            finishHandOver(handle)
        }
    }

    private func finishHandOver(_ handle: String) {
        guard var obligation = handOvers[handle] else { return }
        obligation.inFlight = true
        handOvers[handle] = obligation
        let retries = handOverRetries
        // Taken before the write: a host replaced meanwhile refuses it.
        let ticket = gate.ticket(host: obligation.hostID)
        operations.run(host: obligation.hostID, .write) { [weak self] in
            var failure: Error?
            for delay in [0] + retries {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                do {
                    try await obligation.ledger.markTabClosed(handle, sessionID: obligation.sessionID)
                    failure = nil
                    break
                } catch {
                    failure = error
                }
            }
            guard let self else { return }
            guard let failure else {
                self.handOvers[handle] = nil
                return
            }
            // Kept for the next close, quit or launch; said once, and logged
            // first, so a suppressed notice still leaves a diagnostic.
            self.handOvers[handle]?.inFlight = false
            guard self.handOvers[handle]?.said == false else { return }
            self.handOvers[handle]?.said = true
            TempleUILog.remote.notice("hand-over of \(handle, privacy: .public) not written: \(failure.localizedDescription, privacy: .public)")
            if self.gate.admit(.pendingWriteNotice, ticket) {
                self.noticeHandler?(obligation.hostID, RemoteCopy.unrecorded(obligation.hostName, detail: failure.localizedDescription))
            }
        }
    }

    /// Whether a run still owes its hand-over (tests).
    func owesHandOver(_ handle: String) -> Bool { handOvers[handle] != nil }

    // MARK: Hand-backs (Not this one), the hand-over's reverse

    /// A run whose claim Not this one released, while a saved tab set may
    /// still hold the session it was claimed as. Like a hand-over it holds
    /// the run store itself, is settled only by an acknowledged save (here
    /// of a tab set without the session, its tab now the run's) or by its
    /// tab going, is retried, and is finished at the quit or the next
    /// launch. A close or detach in between stands: the hand-back is
    /// dropped and the run's restoration stays as that close left it.
    private struct HandBack {
        let ledger: RemoteRunLedger
        let sessionID: String
        let hostID: HostID
        let hostName: String
        let tabID: SessionTab.ID
        /// The acknowledged saves when the tab became the run's; `.max`
        /// until then (no save counts while the tab is still the session).
        var savesBefore: Int = .max
        var inFlight = false
        var said = false
    }
    private var handBacks: [String: HandBack] = [:]

    private func oweHandBack(handle: String, sessionID: String, tabID: SessionTab.ID, host: RemoteSessionHost,
                             hostID: HostID, savesBefore: Int = .max) {
        guard let ledger = host.runLedger() else {
            TempleUILog.db.error("no run store to hand a run back with; the next launch reconciles it")
            return
        }
        handBacks[handle] = HandBack(ledger: ledger, sessionID: sessionID, hostID: hostID, hostName: host.hostName,
                                     tabID: tabID, savesBefore: savesBefore)
    }

    /// Whether a run still owes its hand-back (tests).
    func owesHandBack(_ handle: String) -> Bool { handBacks[handle] != nil }

    /// Each hand-back whose tab is gone is dropped; each whose tab is the
    /// run's and whose tab set has been saved since is finished.
    private func settleHandBacks() {
        guard handBacks.values.contains(where: { !$0.inFlight }) else { return }
        let saves = model.acknowledgedSaves
        for (handle, owed) in handBacks where !owed.inFlight {
            guard let tab = model.tabs.first(where: { $0.id == owed.tabID }) else {
                finishHandBack(handle, reopen: false)
                continue
            }
            if tab.sessionID == nil, saves > owed.savesBefore { finishHandBack(handle, reopen: true) }
        }
    }

    private func finishHandBack(_ handle: String, reopen: Bool) {
        guard var owed = handBacks[handle] else { return }
        owed.inFlight = true
        handBacks[handle] = owed
        let retries = handOverRetries
        let ticket = gate.ticket(host: owed.hostID)
        operations.run(host: owed.hostID, .write) { [weak self] in
            var failure: Error?
            for delay in [0] + retries {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                do {
                    if reopen {
                        try await owed.ledger.finishHandBack(handle, sessionID: owed.sessionID)
                    } else {
                        try await owed.ledger.dropHandBack(handle, sessionID: owed.sessionID)
                    }
                    failure = nil
                    break
                } catch {
                    failure = error
                }
            }
            guard let self else { return }
            guard let failure else {
                self.handBacks[handle] = nil
                return
            }
            // Kept for the next save, close, quit or launch; said once.
            self.handBacks[handle]?.inFlight = false
            guard self.handBacks[handle]?.said == false else { return }
            self.handBacks[handle]?.said = true
            TempleUILog.remote.notice("hand-back of \(handle, privacy: .public) not written: \(failure.localizedDescription, privacy: .public)")
            if self.gate.admit(.pendingWriteNotice, ticket) {
                self.noticeHandler?(owed.hostID, RemoteCopy.unrecorded(owed.hostName, detail: failure.localizedDescription))
            }
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
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab),
              inputEvidence[handle, default: .none] == .none else { return }
        inputEvidence[handle] = .inFlight
        let hostID = tab.host
        let ticket = gate.ticket(host: hostID)
        let retries = inputWriteRetries
        // Committed only once written; a failed write is tried again a few
        // times, then said, and the next Return tries afresh (round 2).
        operations.run(host: hostID, .write) { [weak self] in
            var failure: Error?
            for delay in [0] + retries {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                do {
                    try await host.recordInput(handle)
                    failure = nil
                    break
                } catch {
                    failure = error
                }
            }
            guard let self else { return }
            self.inputEvidence[handle] = failure == nil ? .committed : InputEvidence.none
            if let failure, self.gate.admit(.pendingWriteNotice, ticket) {
                self.noticeHandler?(hostID, RemoteCopy.unrecorded(host.hostName, detail: failure.localizedDescription))
            }
        }
    }

    /// Whether a pending run's input is written with it (tests).
    func inputCommitted(_ handle: String) -> Bool { inputEvidence[handle] == .committed }

    /// Try again, after core refused the id: the next check claims it anew.
    public func retryIdentity(_ tab: SessionTab) {
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab) else { return }
        refusedClaims[handle] = nil
        tab.remote?.identityRefused = false
        // "Couldn't tell" stays until candidates arrive (never a bare tab);
        // a refusal's reason goes with the refusal.
        if tab.remote?.identityNote != RemoteCopy.couldNotTell { tab.remote?.identityNote = nil }
        lastIdentityCheck[tab.id] = Date()
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .identity) { [weak self] in
            await self?.checkIdentity(ticket, host: host, handle: handle)
        }
    }

    /// Core's rows changed: a refused id whose conflicting row is gone may
    /// be claimed again (the next check tries it).
    func rowsChanged() {
        for (handle, refusal) in refusedClaims where model.sessionRow(refusal.id) == nil {
            refusedClaims[handle] = nil
            for tab in model.tabs where tab.remote?.handle == handle {
                tab.remote?.identityRefused = false
            }
        }
    }

    private func loadSuggestions(_ tab: SessionTab, host: RemoteSessionHost, handle: String) {
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .query) { [weak self] in
            await self?.loadSuggestions(ticket, host: host, handle: handle)
        }
    }

    private func loadSuggestions(_ ticket: RemoteTicket, host: RemoteSessionHost, handle: String) async {
        let answer = await host.suggestions(handle)
        guard gate.admit(.suggestionsLoaded, ticket), let tab = ticket.tab, isPending(tab),
              case .candidates(let found) = answer else { return }
        let refused = refusedClaims[handle]?.id
        // Never one the user declined for this run, even before the host's
        // own record of the decline is written (Try again included).
        let declined = declinedHere[handle] ?? []
        let offered = found.filter { $0.sessionID != refused && !declined.contains($0.id) }
        // Exactly one eligible candidate for a connected run that was typed
        // into and never asked about: Temple says yes on its own, through
        // the yes's own path (owner, round 2; Fable's decision). Two or
        // more, an ended tab, or once asked: the question.
        if offered.count == 1, tab.remote?.phase == .connected, tab.inputSubmitted, !isQuitting,
           refusedClaims[handle] == nil, tab.remote?.confirming == nil, !asked.contains(handle),
           !hasUnidentifiedNeighbour(tab) {
            claim(offered[0], in: tab, automatic: true)
            return
        }
        // After Not this one, the question replaces "couldn't tell" once
        // there is something to ask about.
        if !offered.isEmpty, tab.remote?.unlinkFallback == true {
            tab.remote?.unlinkFallback = false
            if tab.remote?.identityNote == RemoteCopy.couldNotTell { tab.remote?.identityNote = nil }
        }
        // In start order: the question reads earliest first.
        tab.remote?.suggestions = offered.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id.lexicographicallyPrecedes($1.id)
        }
        if !offered.isEmpty { asked.insert(handle) }
        // Once asked, the tab is never bare: with no candidate left (the
        // last one declined), it says Temple couldn't tell.
        if offered.isEmpty, asked.contains(handle), tab.remote?.identityNote == nil {
            tab.remote?.identityNote = RemoteCopy.couldNotTell
        }
    }

    /// Another new Codex session this Temple started on the same host in the
    /// same folder that is still unidentified and not ended: its window
    /// overlaps this one's, so the lone candidate may be the other's, and
    /// both ask. (The claim's own transaction checks every run on the host,
    /// detached ones and another Temple's included.)
    /// Folders compare only once both panes reported theirs (canonical,
    /// by bytes); one not yet resolved counts as the same folder.
    private func hasUnidentifiedNeighbour(_ tab: SessionTab) -> Bool {
        let mine = tab.launchObservation?.directory
        return model.tabs.contains { other in
            guard other !== tab, isPending(other), other.host == tab.host, other.remote != nil,
                  other.remote?.phase != .endedPending else { return false }
            guard let mine, let theirs = other.launchObservation?.directory else { return true }
            return Array(mine.utf8) == Array(theirs.utf8)
        }
    }

    /// Runs whose question was shown this launch (or whose automatic yes
    /// failed): Temple never says yes on its own for them. A decline is the
    /// durable "asked": the store refuses an automatic claim for a run with
    /// a declined candidate, across relaunches.
    private var asked: Set<String> = []

    /// "Yes, that's it": the claim is durable work (owned through close and
    /// quit); what the tab shows passes the gate.
    public func confirm(_ suggestion: RemoteSuggestion, in tab: SessionTab) {
        claim(suggestion, in: tab, automatic: false)
    }

    /// A yes, the user's or (`automatic`) Temple's own to a lone candidate:
    /// one path. Only the automatic one's own claim of the candidate's id
    /// adds the tab's note that it linked on its own (display only, gated
    /// with the rest of the tab's part); an automatic claim that fails
    /// asks the question.
    private func claim(_ suggestion: RemoteSuggestion, in tab: SessionTab, automatic: Bool) {
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab),
              tab.remote?.confirming == nil, !isQuitting else { return }
        tab.remote?.confirming = suggestion.id
        let ticket = gate.ticket(for: tab)
        operations.run(host: tab.host, .write) { [weak self] in
            let identity = await host.confirm(handle, suggestion: suggestion, automatic: automatic)
            guard let self else { return }
            switch identity {
            case .adopted(let id, let directory), .known(let id, let directory):
                // The candidate's prompt titles only the candidate: a claim
                // that answers with another id (a concurrent `.known`) gets
                // none. Compared by bytes, as ids are everywhere else.
                let same = id.utf8.elementsEqual(suggestion.sessionID.utf8)
                var linked = false
                if automatic, case .adopted = identity, same { linked = true }
                await self.adopted(id, directory: directory, handle: handle, host: host, ticket: ticket,
                                   titleHint: same ? suggestion.firstPrompt : nil,
                                   linked: linked ? suggestion : nil)
            case .taken, .inconclusive:
                guard self.gate.admit(.confirmResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.confirming = nil
                if automatic {
                    self.asked.insert(handle)
                    await self.loadSuggestions(ticket, host: host, handle: handle)
                    return
                }
                tab.remote?.suggestions.removeAll { $0.id == suggestion.id }
                tab.remote?.identityNote = RemoteCopy.couldNotTell
            case .storage(let detail):
                guard self.gate.admit(.confirmResult, ticket), let tab = ticket.tab else { return }
                tab.remote?.confirming = nil
                tab.remote?.identityNote = RemoteCopy.unrecorded(host.hostName, detail: detail)
                // Temple's own yes is not tried again: the question, with
                // the failure said above it.
                if automatic {
                    self.asked.insert(handle)
                    await self.loadSuggestions(ticket, host: host, handle: handle)
                }
            }
        }
    }

    /// Candidates declined for each run this launch, by rollout path: never
    /// offered again here, whatever the host's lookup returns (its own
    /// record of a decline is the durable one, across launches).
    private var declinedHere: [String: Set<[UInt8]>] = [:]

    /// "Not this one": gone from the tab at once, and never offered again
    /// for this run (durable).
    public func decline(_ suggestion: RemoteSuggestion, in tab: SessionTab) {
        guard isPending(tab), let handle = tab.remote?.handle, let host = remoteHost(for: tab) else { return }
        declinedHere[handle, default: []].insert(suggestion.id)
        tab.remote?.suggestions.removeAll { $0.id == suggestion.id }
        asked.insert(handle)
        // The last one declined, on a running tab: it says Temple couldn't
        // tell (with Try again), never goes bare.
        if tab.remote?.suggestions.isEmpty == true, tab.remote?.phase == .connected, tab.remote?.identityNote == nil {
            tab.remote?.identityNote = RemoteCopy.couldNotTell
        }
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
    /// run is kept, listed under Running sessions on <host> for Stop, its tab
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
    /// Running sessions on <host>, where it can be opened again). A stop (an idle
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
        let name = sessionName(tab)
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
                if self.gate.admit(.closeStopNotice, noticeTicket) { self.notice(result, host: host, hostID: hostID, session: name) }
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
                self.notice(result, host: host, hostID: hostID, session: name)
            case .unrecorded(let detail):
                tab.remote?.phase = .stopFailed(RemoteCopy.unrecorded(host.hostName, detail: detail))
            }
        }
    }

    /// At launch, for each host: first the claims whose core join never
    /// happened are joined again (a refusal releases its claim, a failed
    /// write leaves it for later), then the pending Codex runs come back as
    /// chips, each by that outcome (round 2): a claim core holds becomes
    /// that session's chip, handed over once the tab set is written; any
    /// other run (pending, released, or claimed but not joined) comes back
    /// by its handle, inert until activated (which attaches; an ended one
    /// asks).
    public func restorePending(hosts: [HostID]) {
        for hostID in hosts {
            guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { continue }
            let ticket = gate.ticket(host: hostID)
            operations.run(host: hostID, .query) { [weak self] in
                guard let self else { return }
                let joined = await self.reconcile(host: host, hostID: hostID)
                let backs = await host.handBacks()
                let runs = await host.pendingRuns()
                guard !runs.isEmpty || !backs.isEmpty, self.gate.admit(.pendingRestore, ticket) else { return }
                // Hand-backs first (Not this one, settled before the quit or
                // not): a saved tab still holding the session is that run's
                // tab; with none, the run comes back by its handle. Either
                // way the hand-back is owed until a save without the session.
                for back in backs {
                    if let saved = self.model.tabs.first(where: {
                        $0.kind == .session && $0.host == hostID && $0.sessionID == back.sessionID
                    }) {
                        self.takeBack(saved, back.run, from: back.sessionID, host: host, open: false)
                        continue
                    }
                    let tab = self.model.tabs.first(where: { $0.host == hostID && $0.remote?.handle == back.run.handle })
                        ?? self.model.appendPendingChip(host: hostID, handle: back.run.handle,
                                                        directory: back.run.directory, ended: back.run.ended,
                                                        typed: back.run.typed)
                    if back.run.typed { self.inputEvidence[back.run.handle] = .committed }
                    self.asked.insert(back.run.handle)
                    self.oweHandBack(handle: back.run.handle, sessionID: back.sessionID, tabID: tab.id, host: host,
                                     hostID: hostID, savesBefore: self.model.acknowledgedSaves)
                }
                if !backs.isEmpty {
                    self.model.persist()
                    self.settleHandOvers()
                }
                for run in runs where !self.model.tabs.contains(where: { $0.host == hostID && $0.remote?.handle == run.handle }) {
                    if let id = run.sessionID, run.joined || joined.contains(run.handle) {
                        let chip = self.model.tabs.first(where: { $0.sessionID == id })
                            ?? self.model.appendClaimedChip(host: hostID, sessionID: id, directory: run.directory)
                        self.handOver(chip, handle: run.handle, host: host)
                        continue
                    }
                    self.model.appendPendingChip(host: hostID, handle: run.handle, directory: run.directory,
                                                 ended: run.ended, typed: run.typed)
                    if run.typed { self.inputEvidence[run.handle] = .committed }
                }
            }
        }
    }

    /// The launch's reconciliation alone (`restorePending` runs it first).
    public func reconcileClaims(hosts: [HostID]) {
        for hostID in hosts {
            guard let host = model.launcherForHost(hostID) as? RemoteSessionHost else { continue }
            operations.run(host: hostID, .query) { [weak self] in
                _ = await self?.reconcile(host: host, hostID: hostID)
            }
        }
    }

    /// Joins every claim whose core join never happened (a quit or crash
    /// between the two writes); core's refusal releases it; a failed write
    /// leaves it for the next launch. Durable work, outside the gate (see
    /// `RemoteCompletion`). The handles joined now.
    private func reconcile(host: RemoteSessionHost, hostID: HostID) async -> Set<String> {
        var joined = Set<String>()
        for claim in await host.unjoinedClaims() {
            guard !isQuitting, !Task.isCancelled else { return joined }
            let open = SessionOpen(id: claim.sessionID, host: hostID, via: .created, agent: .codex, locator: nil)
            switch model.openedHandler?(open) ?? .joined {
            case .joined:
                if let directory = claim.directory { model.launchDirectoryHandler?(claim.sessionID, hostID, directory) }
                joined.insert(claim.handle)
                do { try await host.markJoined(claim.handle) } catch {
                    TempleUILog.db.error("claim not marked joined: \(error.localizedDescription, privacy: .public)")
                }
            case .refused:
                do { try await host.releaseClaim(claim.handle, sessionID: claim.sessionID) } catch {
                    TempleUILog.db.error("refused claim not released: \(error.localizedDescription, privacy: .public)")
                }
            case .failed(let error):
                TempleUILog.db.error("reconciliation join failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return joined
    }

    /// "Open" in Running sessions on a session with an id but no row in
    /// Temple's list: a tab of it, opened by its id (the open joins it,
    /// then attaches to its live run on the host).
    public func openSession(_ id: String, agent: Agent, host hostID: HostID, directory: String) {
        if let tab = model.tabs.first(where: { $0.kind == .session && $0.sessionID == id && $0.host == hostID }) {
            model.activate(tab)
            return
        }
        let tab = model.appendSessionChip(host: hostID, sessionID: id, agent: agent, directory: directory)
        model.activate(tab)
        model.persist()
    }

    /// "Open" on a pending Codex session in Running sessions on <host>: its tab, or
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
