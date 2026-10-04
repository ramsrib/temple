import SwiftUI
import TempleCore
import TempleTerminalAPI

/// A tab now runs (or adopted) this session; the handler makes it Temple's.
public struct SessionOpen {
    public let id: String
    public let host: HostID
    public let via: JoinedVia
    public let agent: Agent?
    public let locator: TranscriptLocator?
}

struct ClosedTabRecord {
    let host: HostID
    let sessionID: String
    let agent: Agent
    let projectPath: String
    let title: String
}

/// The set of open tabs and the active one (U2). Each session tab owns a
/// `TerminalSurface` from the injected factory; reuse-or-focus prevents
/// duplicates; the active project (derived from the active session tab) scopes
/// the per-project horizontal tab bar.
@MainActor
public final class OpenSessionsModel: NSObject, ObservableObject {
    @Published public private(set) var tabs: [SessionTab] = []
    @Published public private(set) var activeTabID: SessionTab.ID? {
        didSet {
            // Going anywhere else is the user's answer: the restored tab that
            // could not open yet is no longer waited on.
            if activeTabID != pendingRestoreActivation { pendingRestoreActivation = nil }
            guard let id = activeTabID, id != oldValue else { return }
            activationHistory.removeAll { $0 == id }
            activationHistory.append(id)
            if activationHistory.count > 50 { activationHistory.removeFirst() }
        }
    }
    /// Tab ids in activation order, most recent last — the "where you came
    /// from" trail that closing a tab walks back (browser MRU, not first-tab).
    private var activationHistory: [SessionTab.ID] = []
    /// The restored active tab, when its row could not say where to resume
    /// it yet. It opens the moment the row can (`rowsChanged`), unless the
    /// user has gone elsewhere in the meantime.
    private var pendingRestoreActivation: SessionTab.ID?
    /// Derived from the active *session* tab; the Settings tab never changes it.
    @Published public private(set) var activeProjectKey: ProjectKey?

    // Dependencies (injected; all swappable for Track C/T).
    private let surfaceFactory: TerminalSurfaceFactory
    private let appearanceProvider: () -> TerminalAppearance
    private let runtime: SessionRuntimeController
    private let registry: ProcessRegistry
    private let reconciler: CodexAdopting
    private let persistence: TabPersistence
    private let defaultAgent: () -> Agent
    private let now: () -> Date
    /// "Is there anything wrong with how we'd launch this agent?" — asked at the
    /// moment a tab dies, never afterwards (see `SessionTab.commandWasSuspect`).
    /// User-closed sessions only, oldest first. Process exits bypass this stack.
    private var closedTabs: [ClosedTabRecord] = []
    private static let closedTabLimit = 20

    /// U7 hook: fired when a non-active tab needs attention (bell / OSC / etc.).
    public var attentionHandler: ((SessionTab, _ title: String, _ body: String) -> Void)?
    /// The agent retitled itself (sessionID, title) — AppModel persists it so the
    /// sidebar/palette show it, live and after the session closes.
    public var titleHandler: ((_ sessionID: String, _ host: HostID, _ title: String) -> Void)?
    /// A tab now runs this session: `.created` for one started here (a minted
    /// Claude id, or the Codex id adopted for a session this model launched),
    /// `.opened` for one resumed or restored. AppModel makes it a Temple session.
    /// A refusal (the id is Temple's on another host) stops the spawn, or
    /// keeps an adopting tab provisional; a failed write does not.
    public var openedHandler: ((SessionOpen) -> JoinResult)?
    public var touchHandler: ((_ sessionID: String, _ host: HostID, _ at: Date?) -> Void)?
    /// A new session's tab went away before anything was sent to it.
    public var unstartedHandler: ((_ sessionID: String, _ host: HostID) -> Void)?
    public var launchDirectoryHandler: ((_ sessionID: String, _ host: HostID, _ directory: String) -> Void)?
    private var awaitingExitDiagnosis: Set<SessionTab.ID> = []

    /// Transitional lookup: legacy callers, restore and reopen prefer the durable row.
    public var sessionRow: (String) -> Session? = { _ in nil }
    /// The owning host's folder evidence, asked after an agent exits: a
    /// folder deleted while it ran gets its own line. (Before a spawn, the
    /// launcher's `prepare` is what proves a folder gone.)
    private let directoryEvidence: (ProjectKey) async -> DirectoryEvidence
    private let launcherForHost: (HostID) -> (any HostLauncher)?

    /// Resolution updates retain the diagnosis interest after an early exit.
    public func refreshExitedResumeDiagnoses() {
        for tab in tabs where awaitingExitDiagnosis.contains(tab.id) {
            guard case .exited = tab.activity, let sid = tab.sessionID else { continue }
            if let known = sessionKnown(sid) {
                tab.resumeTargetMissing = !known
                awaitingExitDiagnosis.remove(tab.id)
            }
        }
    }

    private func diagnoseExit(_ tab: SessionTab) {
        let key = tab.projectKey, path = tab.projectPath, evidence = directoryEvidence
        let exited = tab.surface.map(ObjectIdentifier.init)
        Task { @MainActor [weak tab] in
            let result = await evidence(key)
            // Only for the exit it was asked about: a relaunch has another
            // surface, and its own exit asks again.
            guard let tab, case .exited = tab.activity, tab.projectPath == path,
                  tab.surface.map(ObjectIdentifier.init) == exited else { return }
            tab.missingWorkingDirectory = result == .missing ? path : nil
        }
        guard tab.isResume, let sid = tab.sessionID else { return }
        if let known = sessionKnown(sid) { tab.resumeTargetMissing = !known }
        else { awaitingExitDiagnosis.insert(tab.id) }
    }

    /// Does any transcript on disk carry this session id? Answered from the
    /// latest engine snapshot (AppModel wires it); nil means "can't say yet"
    /// because resolution is unfinished — and no verdict is recorded. Only a provable absence
    /// annotates a failure; this can prove a missing target, never a good one.
    public var sessionKnown: (_ sessionID: String) -> Bool? = { _ in nil }

    public init(surfaceFactory: TerminalSurfaceFactory,
                appearanceProvider: @escaping () -> TerminalAppearance,
                runtime: SessionRuntimeController,
                registry: ProcessRegistry,
                reconciler: CodexAdopting? = nil,
                persistence: TabPersistence? = nil,
                defaultAgent: @escaping () -> Agent = { .claude },
                now: @escaping () -> Date = Date.init,
                launcherForHost: ((HostID) -> (any HostLauncher)?)? = nil,
                directoryEvidence: ((ProjectKey) async -> DirectoryEvidence)? = nil) {
        if let launcherForHost {
            self.launcherForHost = launcherForHost
        } else {
            // The registry owns launchers in the app (AppModel passes them in).
            // Without it nothing here can say a folder is gone.
            let local = LocalHostLauncher(folderEvidence: { _ in .unknown })
            self.launcherForHost = { $0.isLocal ? local : nil }
        }
        // The host registry owns directory evidence (AppModel passes it in).
        self.directoryEvidence = directoryEvidence ?? { _ in .unknown }
        self.surfaceFactory = surfaceFactory
        self.appearanceProvider = appearanceProvider
        self.runtime = runtime
        self.registry = registry
        self.reconciler = reconciler ?? NoopCodexReconciler()
        self.persistence = persistence ?? UserDefaultsTabPersistence()
        self.defaultAgent = defaultAgent
        self.now = now
        super.init()
    }

    // MARK: Derived

    public var activeTab: SessionTab? { tabs.first { $0.id == activeTabID } }

    public var settingsTab: SessionTab? { tabs.first { $0.kind == .settings } }

    public var historyTab: SessionTab? { tabs.first { $0.kind == .history } }

    /// Visible-row index of each project-agnostic utility chip — Settings,
    /// History (its ORDER is user-controlled via drag). A single GLOBAL offset
    /// per kind, not a per-project one: dragging the chip sets where it sits
    /// in the row, and switching projects keeps that offset, clamped to the
    /// new project's row length (so a short row can't push it off the end).
    /// Absent means "trailing" — the default, matching the original append
    /// behavior. Runtime-only; not persisted across restarts (utility tabs are
    /// never persisted — they're re-created on demand — so there's nothing to
    /// anchor a saved offset to).
    private var utilityRowOffsets: [TabKind: Int] = [:]

    /// The chips shown in the header strip: the active project's session tabs, in
    /// order, with each open utility chip inserted at its user-controlled offset
    /// (clamped to the row length). Lower offsets go in first, so two utility
    /// chips land where they were dropped; ties keep the order they opened in.
    public var visibleTabs: [SessionTab] {
        let sessions = tabs.filter { $0.kind == .session && $0.projectKey == activeProjectKey }
        let utilities = tabs.filter(\.isUtility)
        guard !utilities.isEmpty else { return sessions }
        var result = sessions
        let placed = utilities.enumerated().sorted { lhs, rhs in
            let left = utilityRowOffsets[lhs.element.kind] ?? .max
            let right = utilityRowOffsets[rhs.element.kind] ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        for (_, utility) in placed {
            let offset = utilityRowOffsets[utility.kind] ?? .max
            result.insert(utility, at: min(max(offset, 0), result.count))
        }
        return result
    }

    func sessionTab(withSessionID id: String) -> SessionTab? {
        tabs.first { $0.kind == .session && $0.sessionID == id }
    }

    /// The open tab for a session id, if any (used by the sidebar for open/activity state).
    /// Open session ids across ALL projects, in tab order (⌘K switcher).
    public var openSessionIDsInTabOrder: [String] {
        tabs.filter { $0.kind == .session }.compactMap(\.sessionID)
    }

    public func openTab(forSessionID id: String) -> SessionTab? {
        sessionTab(withSessionID: id)
    }

    private func tab(for surface: TerminalSurface) -> SessionTab? {
        tabs.first { $0.surface === surface }
    }

    /// Session tabs whose agent is mid-task. Quitting interrupts these, which is
    /// what the quit gate asks about.
    public var workingTabs: [SessionTab] {
        tabs.filter { $0.kind == .session && $0.hasSurface && $0.activity == .running }
    }

    public var allSurfaces: [TerminalSurface] {
        tabs.compactMap { $0.surface }
    }

    // MARK: Open / reuse-or-focus

    /// Click a sidebar session → focus its tab if open, else open a new one.
    /// Either way the session's project becomes active (UX "Open an existing
    /// session").
    public func openSession(_ session: Session) {
        // Focusing a live process does not require resume facts or spawn again.
        if let existing = sessionTab(withSessionID: session.id), existing.hasSurface {
            activate(existing)
            return
        }
        guard session.canResume, let agent = session.agent, let directory = session.directory else {
            logNonOpenable(session)
            return
        }
        if let existing = sessionTab(withSessionID: session.id) {
            existing.transcriptHint = session.transcript
            existing.prepareResume(session)
            activate(existing)
            return
        }
        let tab = SessionTab(kind: .session, sessionID: session.id, agent: agent,
            projectPath: directory, title: session.displayTitle,
            isResume: true, host: session.host)
        tab.transcriptHint = session.transcript
        tabs.append(tab)
        activate(tab)
        persist()
    }

    private func logNonOpenable(_ session: Session) {
        let reason = session.agent == nil ? "agent is unknown" : "directory is unknown"
        TempleUILog.launch.notice("session not opened: id=\(session.id, privacy: .public) reason=\(reason, privacy: .public)")
    }

    public func openSession(_ session: TranscriptSummary) {
        if let row = sessionRow(session.id) {
            openSession(row)
            return
        }
        if let existing = sessionTab(withSessionID: session.id) {
            existing.transcriptHint = session.locator
            activate(existing)
            return
        }
        let tab = SessionTab(
            kind: .session,
            sessionID: session.id,
            agent: session.agent,
            projectPath: session.catalogDirectory,
            title: session.catalogTitle,
            isResume: true, host: session.locator.host)
        tab.transcriptHint = session.locator
        tabs.append(tab)
        activate(tab)
        persist()
    }

    // MARK: New session (U4)

    /// New empty session in a project with an explicit agent (`+` menu).
    @discardableResult
    public func newSession(agent: Agent, project: ProjectKey) -> SessionTab {
        let projectPath = project.path
        let spec = SessionLauncher.newSession(agent: agent, projectPath: projectPath)
        let tab = SessionTab(
            kind: .session,
            sessionID: spec.sessionID,
            agent: spec.agent,
            projectPath: spec.projectPath,
            title: spec.title,
            isProvisional: spec.isProvisional, host: project.host)
        tabs.append(tab)
        if let sid = spec.sessionID {
            _ = openedHandler?(SessionOpen(id: sid, host: project.host, via: .created, agent: spec.agent, locator: nil))
        }
        if spec.isProvisional {
            // Codex: adopt the real id once its rollout file appears (ADR-008).
            reconciler.reconcile(host: tab.host, projectPath: projectPath, startedAt: Date()) { [weak self, weak tab] id, locator in
                guard let self, let tab else { return }
                self.adopt(sessionID: id, for: tab.id, locator: locator)
            }
        }
        activate(tab)
        persist()
        return tab
    }

    /// ⌘T / empty-tab: new session in the current (or given) project with the
    /// configured default agent (UX keyboard path — no menu).
    @discardableResult
    public func newSessionDefaultAgent(project: ProjectKey? = nil) -> SessionTab? {
        guard let key = project ?? activeProjectKey else { return nil }
        return newSession(agent: defaultAgent(), project: key)
    }

    /// Codex reconcile seam (ADR-008): rebind a provisional tab to its real id.
    public func adopt(sessionID: String, for tabID: SessionTab.ID, locator: TranscriptLocator? = nil) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        // Join before binding: an id Temple already has on another host is
        // never bound to this tab, which stays provisional.
        let open = SessionOpen(id: sessionID, host: tab.host, via: .created, agent: .codex,
                               locator: locator?.host == tab.host ? locator : nil)
        if let conflict = openedHandler?(open).conflict {
            TempleUILog.launch.notice("adoption refused for \(sessionID, privacy: .public): \(conflict.message, privacy: .public)")
            return
        }
        tab.sessionID = sessionID
        tab.isProvisional = false
        if let launch = tab.launchObservation {
            if let directory = launch.directory { launchDirectoryHandler?(sessionID, tab.host, directory) }
            if !isQuitting { touchHandler?(sessionID, tab.host, launch.at) }
        }
        if case .running(let pid) = tab.surface?.processState ?? .notStarted {
            registry.register(pid: pid, sessionID: sessionID)
        }
        persist()
    }

    // MARK: Activation & lazy surface spawn

    public func activate(_ tab: SessionTab) {
        let openable = prepareInertResume(tab)
        activeTabID = tab.id
        if tab.kind == .session {
            let projectChanged = activeProjectKey != tab.projectKey
            activeProjectKey = tab.projectKey
            lastActiveTabByProject[tab.projectKey] = tab.id
            touchProject(tab.projectKey)
            if openable { ensureSurface(for: tab) }
            // Keep the persisted active-project ordering current even when the
            // switch happens by focusing an already-open tab (no open/close).
            if projectChanged { persist() }
            // Viewing a tab that was waiting for you clears its attention. The
            // agent already stopped working (that's what rang), so it settles to
            // idle rather than back to running (Item E).
            if tab.activity == .needsAttention { tab.activity = .idle }
        }
        tab.surface?.focus()
    }

    /// An inert resume chip takes the latest row before its first spawn. The
    /// row wins where it knows; where it does not, the tab's own facts stand
    /// in — for a restored chip, the agent and folder its tab last ran with,
    /// which is how a legacy row with no directory yet still resumes (and the
    /// spawn then records that folder on the row). A chip neither can place
    /// says so on screen instead of silently not opening.
    private func prepareInertResume(_ tab: SessionTab) -> Bool {
        guard tab.kind == .session, tab.isResume, !tab.hasSurface, let sid = tab.sessionID,
              let row = sessionRow(sid) else { return true }
        let agent = row.agent ?? tab.agent
        guard let directory = row.directory ?? (tab.projectPath.isEmpty ? nil : tab.projectPath) else {
            logNonOpenable(row)
            tab.launchPreparationError = Self.unknownDirectoryMessage
            tab.activity = .exited(status: -1)
            return false
        }
        if tab.launchPreparationError == Self.unknownDirectoryMessage { tab.launchPreparationError = nil }
        tab.prepareResume(row, agent: agent, directory: directory)
        return true
    }

    static let unknownDirectoryMessage = "Temple doesn't know which folder this session ran in yet, so it can't resume it."

    /// Rows changed: a restored active tab that could not open at launch
    /// opens now, if its row has learned enough and the user is still on it.
    public func rowsChanged() {
        guard let id = pendingRestoreActivation else { return }
        guard activeTabID == id, let tab = tabs.first(where: { $0.id == id }), !tab.hasSurface else {
            pendingRestoreActivation = nil
            return
        }
        guard let sid = tab.sessionID, let row = sessionRow(sid), row.directory != nil else { return }
        pendingRestoreActivation = nil
        activate(tab)
    }

    /// Hand the keyboard back to the active terminal — an overlay (⌘K, ⌘/) took
    /// the window's first responder to type into, and closing it must not leave
    /// focus nowhere.
    public func focusActiveTerminal() {
        activeTab?.surface?.focus()
    }

    public func activate(tabID: SessionTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        activate(tab)
    }

    /// ⌘⇧H / "return home": deactivate to the empty-state launcher without
    /// closing any tab. The launcher IS the new-session entry point (UX §New
    /// session) — there is no modal duplicate. Clicking a chip reactivates.
    public func showHome() {
        activeTabID = nil
    }

    /// Spawn the surface for a session tab on first activation (lazy restore).
    private func ensureSurface(for tab: SessionTab) {
        guard !isQuitting, tab.kind == .session, tab.surface == nil else { return }
        guard let launcher = launcherForHost(tab.host) else {
            TempleUILog.launch.notice("host has no launcher: \(tab.host.rawValue, privacy: .public)")
            return
        }
        tab.launchPreparationError = nil
        tab.commandWasSuspect = false
        tab.missingWorkingDirectory = nil
        // Every spawn needs a folder, row or no row: an empty cwd starts the
        // agent in Temple's own working directory. An orphan restored chip
        // or a catalog session that never recorded one stops here.
        guard !tab.projectPath.isEmpty else {
            tab.launchPreparationError = Self.unknownDirectoryMessage
            tab.activity = .exited(status: -1)
            return
        }
        let spec = AgentLaunchSpec(agent: tab.agent,
            mode: tab.isResume ? .resume(sessionID: tab.sessionID!) : .new(sessionID: tab.sessionID),
            directory: tab.projectPath, host: tab.host)
        let launch: AgentLaunch
        do { launch = try launcher.prepare(spec) }
        catch HostLaunchError.directoryMissing(let path) {
            showMissingFolder(tab, path)
            return
        } catch {
            TempleUILog.launch.error("command preparation failed: \(String(describing: error), privacy: .public)")
            tab.launchPreparationError = error.localizedDescription
            tab.commandWasSuspect = true
            tab.activity = .exited(status: -1)
            return
        }
        // A session Temple already has on another host is not run here.
        if let sid = tab.sessionID,
           let conflict = openedHandler?(SessionOpen(id: sid, host: tab.host, via: tab.isResume ? .opened : .created,
                                                     agent: tab.agent, locator: tab.transcriptHint)).conflict {
            launch.result?.cancel()
            tab.launchPreparationError = conflict.message
            tab.activity = .exited(status: -1)
            return
        }
        // The launcher armed its result before returning, so nothing the
        // spawn reports can be missed; it is held until the spawn has started.
        tab.setLaunch(launch)
        let surface = surfaceFactory.makeSurface(appearance: appearanceProvider())
        surface.delegate = self
        let spawnedAt = now()
        tab.attach(surface: surface, at: spawnedAt)
        // The shell should know it is in Temple, not in the library that
        // drives its PTY. A command's own variables still win.
        do {
            try surface.start(TerminalIdentity.apply(to: launch.command))
        } catch {
            TempleUILog.launch.error("spawn failed: agent=\(tab.agent.rawValue, privacy: .public) argv0=\(launch.displayArgv.first ?? "?", privacy: .public) cwd=\(launch.command.cwd, privacy: .public) error=\(String(describing: error), privacy: .public)")
            tab.launchResult?.cancel()
            tab.launchResult = nil
            // A surface that won't even start is always the command's problem.
            tab.commandWasSuspect = true
            diagnoseExit(tab)
            tab.activity = .exited(status: -1)
            return
        }
        // The folder is recorded only when the launch reports entering it
        // (`handleLaunchEvent`), never from a start that merely returned.
        tab.launchObservation = SessionTab.LaunchObservation(at: spawnedAt, directory: nil)
        // From here on, what this launch reports reaches this tab — and only
        // while it is still this tab's launch.
        if let channel = launch.result {
            channel.onEvent = { [weak self, weak tab, weak channel] event in
                guard let self, let tab, let channel, tab.launchResult === channel else { return }
                self.handleLaunchEvent(event, for: tab)
            }
        }
        if let sid = tab.sessionID, !isQuitting { touchHandler?(sid, tab.host, spawnedAt) }
        if case .running(let pid) = surface.processState, let sid = tab.sessionID {
            registry.register(pid: pid, sessionID: sid)
        }
        tab.activity = .running
        // Item E: a freshly spawned agent boots into .running; if it never rings
        // and its title goes quiet, settle it to .idle so the close gate doesn't
        // treat a resting prompt as "still working".
        lastTitleChange[tab.id] = Date()
        scheduleSettle(for: tab)
    }

    /// Deliver whatever every live launch has reported so far, now. The exit
    /// path does this per tab; tests use it to avoid waiting on file events.
    func drainLaunchResults() {
        for tab in tabs { tab.launchResult?.drain() }
    }

    private func showMissingFolder(_ tab: SessionTab, _ path: String) {
        TempleUILog.launch.notice("not spawning in a missing folder: \(path, privacy: .public)")
        tab.launchPreparationError = "The folder \(path) no longer exists."
        tab.activity = .exited(status: -1)
    }

    /// What a launch reported. The folder becomes tab-sourced only here; a
    /// launcher failure is kept for the exit to show, however long the
    /// process lived.
    private func handleLaunchEvent(_ event: LaunchEvent, for tab: SessionTab) {
        switch event {
        case .directoryEstablished(let directory):
            guard tab.launchObservation != nil else { return }
            tab.launchObservation?.directory = directory
            if let sid = tab.sessionID { launchDirectoryHandler?(sid, tab.host, directory) }
        case .failed(let category, let message):
            TempleUILog.launch.notice("launch failed before the agent ran: \(category.rawValue, privacy: .public)")
            tab.launchFailure = LaunchFailure(category: category, message: message)
        case .finished:
            break
        }
    }

    // MARK: Activity settle (Item E)

    /// How long after spawn (or the last title change) a still-`.running`, never-
    /// rung session decays to `.idle`. Overridable so tests exercise it fast.
    var settleDelaySeconds: TimeInterval = 15
    /// A session whose title changed within this window is treated as actively
    /// working (Claude Code live-updates its title while thinking).
    var titleQuietWindow: TimeInterval = 4
    /// A title change this soon after a bell is the agent's own finishing
    /// retitle (work → bell → title resets), not new work — the idle→running
    /// promotion in `didUpdateTitle` ignores it.
    var ringGraceSeconds: TimeInterval = 3

    /// Last time each tab's title changed — feeds the settle heuristic.
    private var lastTitleChange: [SessionTab.ID: Date] = [:]
    /// Last bell/notification per tab — guards the idle→running promotion.
    private var lastRing: [SessionTab.ID: Date] = [:]
    /// Pending settle timers, keyed by tab, so they can be cancelled/replaced.
    private var settleTasks: [SessionTab.ID: Task<Void, Never>] = [:]

    private func scheduleSettle(for tab: SessionTab) {
        settleTasks[tab.id]?.cancel()
        let delay = settleDelaySeconds
        settleTasks[tab.id] = Task { [weak self, weak tab] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let tab else { return }
            self.settleIfQuiet(tab)
        }
    }

    private func settleIfQuiet(_ tab: SessionTab) {
        // Only a still-booting/working session decays; a bell (→ idle/attention),
        // input (→ running, reschedules), or exit will have moved it on already.
        guard tab.activity == .running else { return }
        let sinceTitle = lastTitleChange[tab.id].map { Date().timeIntervalSince($0) } ?? .infinity
        if sinceTitle >= titleQuietWindow {
            tab.activity = .idle
        } else {
            // Title still moving → the agent is working; wait another window.
            scheduleSettle(for: tab)
        }
    }

    private func cancelSettle(for tabID: SessionTab.ID) {
        settleTasks[tabID]?.cancel()
        settleTasks[tabID] = nil
        lastTitleChange[tabID] = nil
        lastRing[tabID] = nil
    }

    // MARK: Settings (U9) and History — singleton utility tabs

    public func openSettings() {
        openUtility(.settings)
    }

    /// Open Settings at the part a warning is about: `agent`'s section, or the
    /// top of the page for a problem that is no one agent's (the shell). The
    /// page consumes the request (`consumeSettingsFocus`) once it has scrolled.
    public func openSettings(focusing agent: Agent?) {
        settingsFocusSerial += 1
        settingsFocus = SettingsFocusRequest(agent: agent, serial: settingsFocusSerial)
        openUtility(.settings)
    }

    /// Where the Settings page should land next; nil once it has.
    @Published public private(set) var settingsFocus: SettingsFocusRequest?
    private var settingsFocusSerial = 0

    public func consumeSettingsFocus(_ request: SettingsFocusRequest) {
        if settingsFocus == request { settingsFocus = nil }
    }

    /// View ▸ Session History, the ⌘K bridge: open the History tab, or focus
    /// it if it is already open.
    public func openHistory() {
        openUtility(.history)
    }

    /// ⌘Y. Opens or focuses History; pressed while History is already the
    /// active tab, goes back to the tab you came from and leaves History open
    /// (the old overlay was a toggle, and ⌘Y-look-⌘Y is muscle memory).
    public func openOrLeaveHistory() {
        if let history = historyTab, activeTabID == history.id {
            returnToPreviousTab()
        } else {
            openHistory()
        }
    }

    /// Back to the tab that was active before the current one, closing
    /// nothing — the launcher if there is none.
    public func returnToPreviousTab() {
        let previous = activationHistory.dropLast().last { id in
            id != activeTabID && tabs.contains { $0.id == id }
        }
        guard let previousID = previous,
              let tab = tabs.first(where: { $0.id == previousID }) else {
            showHome()
            return
        }
        if tab.kind == .session { activate(tab) } else { activeTabID = tab.id }
    }

    private func openUtility(_ kind: TabKind) {
        if let existing = tabs.first(where: { $0.kind == kind }) {
            activeTabID = existing.id
            return
        }
        let tab = SessionTab(kind: kind, sessionID: nil, agent: .claude,
                             projectPath: "", title: kind.utilityTitle ?? "")
        tabs.append(tab)
        activeTabID = tab.id
    }

    // MARK: Close (U3 lifecycle)

    /// The tab awaiting a close-confirmation prompt (a busy agent). Drives the
    /// confirmation dialog; nil when nothing is pending.
    @Published public var pendingCloseTabID: SessionTab.ID?

    public var pendingCloseTab: SessionTab? {
        pendingCloseTabID.flatMap { id in tabs.first { $0.id == id } }
    }

    /// User-initiated close gate (chip ✕ / ⌘W). A session tab whose agent is
    /// actively **working** (`.running`, with a live surface) asks first —
    /// closing would interrupt it. Everything else (idle / needs-attention /
    /// exited / inert chip / Settings) closes immediately.
    public func requestClose(tabID: SessionTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.kind == .session, tab.hasSurface, tab.activity == .running {
            pendingCloseTabID = tabID
        } else {
            closeTab(tabID)
        }
    }

    public func requestCloseActiveTab() {
        if let id = activeTabID { requestClose(tabID: id) }
    }

    /// Proceed with the pending close (user confirmed).
    public func confirmPendingClose() {
        guard let id = pendingCloseTabID else { return }
        pendingCloseTabID = nil
        closeTab(id)
    }

    public func cancelPendingClose() { pendingCloseTabID = nil }

    /// Close a tab from the UI. Session tabs end their process gracefully; the
    /// eventual `.exited` delegate callback removes the tab. Inert chips and the
    /// Settings tab are removed immediately.
    public func closeTab(_ tabID: SessionTab.ID) {
        guard !isQuitting, let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.kind == .session, let sessionID = tab.sessionID {
            touchHandler?(sessionID, tab.host, nil)
            closedTabs.append(ClosedTabRecord(
                host: tab.host,
                sessionID: sessionID,
                agent: tab.agent,
                projectPath: tab.projectPath,
                title: tab.title
            ))
            if closedTabs.count > Self.closedTabLimit {
                closedTabs.removeFirst(closedTabs.count - Self.closedTabLimit)
            }
        }
        if let surface = tab.surface, case .running = surface.processState {
            closingTabIDs.insert(tabID)  // user-initiated: always remove on exit
            runtime.close(surface)       // delegate .exited → removeTab
        } else {
            removeTab(tabID)
        }
    }

    /// Tabs the user explicitly closed — their `.exited` always removes the
    /// tab, bypassing the early-exit grace that keeps failed launches visible.
    private var closingTabIDs: Set<SessionTab.ID> = []

    /// Set once ⌘Q starts draining the agents. From here the open-tab set is
    /// frozen: it is what the next launch restores, and nothing the dying
    /// processes report may change it.
    public private(set) var isQuitting = false

    /// Freeze the tab set for restore, then let the caller drain the agents.
    public func prepareForQuit() {
        guard !isQuitting else { return }
        titlePersistTask?.cancel()
        titlePersistTask = nil
        persist()          // last write wins: capture the set as the user left it
        isQuitting = true
    }

    public func closeActiveTab() {
        if let id = activeTabID { closeTab(id) }
    }

    /// Reopen the newest user-closed session. Entries are spent if that session
    /// was opened by another route in the meantime, preventing duplicate tabs.
    public func reopenLastClosedTab() {
        while let closed = closedTabs.popLast() {
            if let open = sessionTab(withSessionID: closed.sessionID) {
                // ⌘⇧T can race the graceful close: the record is pushed the
                // moment the user closes, but the tab stays in `tabs` until
                // the process exits (up to the graceful timeout). That tab is
                // not "reopened elsewhere" — keep the record for the retry
                // after the exit lands, and resume nothing while the old
                // process still owns the session.
                if closingTabIDs.contains(open.id) {
                    closedTabs.append(closed)
                    return
                }
                continue  // genuinely reopened by another route — spent
            }
            // A row that cannot place itself yet reopens from the closed
            // tab's own facts, as a restored chip does (activate re-reads it).
            if let row = sessionRow(closed.sessionID), row.canResume {
                openSession(row)
                return
            }
            let tab = SessionTab(
                kind: .session,
                sessionID: closed.sessionID,
                agent: closed.agent,
                projectPath: closed.projectPath,
                title: closed.title,
                isResume: true, host: closed.host
            )
            tabs.append(tab)
            activate(tab)
            persist()
            return
        }
    }

    /// The session's row was discarded (it never started): ⌘⇧T has nothing
    /// to resume for it. Records are dropped only then — a row that was kept
    /// (pinned, named, a transcript found) still reopens.
    public func forgetClosedTabs(sessionID: String) {
        closedTabs.removeAll { $0.sessionID == sessionID }
    }

    private func removeTab(_ tabID: SessionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        awaitingExitDiagnosis.remove(tabID)
        cancelSettle(for: tabID)
        // Nothing a closed tab's launch reports later can reach anyone.
        tab.launchResult?.cancel()
        tab.launchResult = nil
        if let sid = tab.sessionID { registry.unregister(sessionID: sid) }
        let wasActive = activeTabID == tabID
        tabs.remove(at: index)
        // Free the native surface here, at a known point, not when ARC gets to
        // the tab: the runtime orders the free against its own drain so a
        // queued title cannot reach the surface spawned next (GhosttyApp.release).
        tab.surface?.release()
        // A gone tab must not be anyone's "go back here" target — least of
        // all its own successor's.
        activationHistory.removeAll { $0 == tabID }
        // A project with no tabs left is not switchable — forget it, or the MRU
        // list grows for the life of the run as folders come and go.
        if !tabs.contains(where: { $0.kind == .session && $0.projectKey == tab.projectKey }) {
            projectMRU.removeAll { $0 == tab.projectKey }
            lastActiveTabByProject.removeValue(forKey: tab.projectKey)
        }
        if wasActive { selectNeighbor(removedIndex: index, removedProject: tab.projectKey, wasUtility: tab.isUtility) }
        persist()
        // After persist: the row must no longer be in a restorable tab.
        if tab.startedNothing, let sid = tab.sessionID { unstartedHandler?(sid, tab.host) }
    }

    private func selectNeighbor(removedIndex: Int, removedProject: ProjectKey, wasUtility: Bool) {
        // Go back where you came from (browser MRU): closing Settings or a
        // just-opened tab returns to the previously active tab, wherever it
        // lives — not to the first tab in the row.
        if let previousID = activationHistory.last,
           let previous = tabs.first(where: { $0.id == previousID }) {
            if previous.kind == .session { activate(previous) } else { activeTabID = previous.id }
            return
        }
        // No history (e.g. relaunch-restored chips): prefer another tab in the
        // same project; else any session tab; else nil.
        let sameProject = tabs.filter { $0.kind == .session && $0.projectKey == removedProject }
        if let next = sameProject.first {
            activate(next)
        } else if let anySession = tabs.first(where: { $0.kind == .session }) {
            activate(anySession)
        } else if let utility = tabs.first(where: \.isUtility) {
            activeTabID = utility.id
        } else {
            activeTabID = nil
            // Keep activeProjectKey so the launcher defaults to the last project.
        }
    }

    // MARK: Auto-close on process exit (ADR-010 reverse direction)

    /// Exits younger than this keep their tab (visible failure); older exits
    /// auto-close (the user ended the agent). Tests shrink it to exercise the
    /// auto-close path with instantly-exiting fakes.
    var earlyExitGraceSeconds: TimeInterval = 5

    private func autoClose(surface: TerminalSurface) {
        guard let tab = tab(for: surface) else { return }
        removeTab(tab.id)
    }

    // MARK: Drag reorder (per-project, persisted)

    /// Reorder the visible tab row by visible-row indices. The row is the active
    /// project's session chips plus any open utility chips at their offsets —
    /// so every kind is draggable. Dragging a utility chip just records its new
    /// global offset; dragging a session chip reorders the sessions within
    /// the active project (other projects' order is preserved).
    public func moveTab(fromOffsets: IndexSet, toOffset: Int) {
        let before = visibleTabs
        var row = before
        row.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // A utility chip's offset always follows the moved row — including
        // when a SESSION was dragged across it. The drag gesture moves one slot
        // per swap, so "session crosses Settings" arrives as an adjacent
        // exchange; keeping Settings pinned made that exchange reconstruct the
        // original row (a silent no-op the drag's slot arithmetic then drifted
        // against), and no session could ever pass the Settings chip.
        for (offset, tab) in row.enumerated() where tab.isUtility {
            utilityRowOffsets[tab.kind] = offset
        }
        // Write the reordered session chips back into the master list, preserving
        // other projects' relative order.
        guard let project = activeProjectKey else { persist(); return }
        let newOrder = row.filter { $0.kind == .session }
        var iterator = newOrder.makeIterator()
        var reordered: [SessionTab] = []
        for tab in tabs {
            if tab.kind == .session && tab.projectKey == project {
                if let next = iterator.next() { reordered.append(next) }
            } else {
                reordered.append(tab)
            }
        }
        tabs = reordered
        persist()
    }

    // MARK: Project switching (the strip is scoped to one project)

    /// The projects you have sessions open in, in the order their first tab was
    /// opened. Deliberately not recency-ordered: a switcher whose entries
    /// reshuffle as you use it is one you can't build muscle memory for.
    public var openProjectKeys: [ProjectKey] {
        var seen = Set<ProjectKey>()
        return tabs.compactMap { tab in
            guard tab.kind == .session, seen.insert(tab.projectKey).inserted else { return nil }
            return tab.projectKey
        }
    }
    /// Compatibility for legacy callers. Presentation uses host-aware keys.
    private var lastActiveTabByProject: [ProjectKey: SessionTab.ID] = [:]
    public var projectKeysByRecency: [ProjectKey] {
        let open = Set(openProjectKeys)
        let recent = projectMRU.filter(open.contains)
        return recent + openProjectKeys.filter { !recent.contains($0) }
    }
    private var projectMRU: [ProjectKey] = []
    private func touchProject(_ key: ProjectKey) {
        projectMRU.removeAll { $0 == key }
        projectMRU.insert(key, at: 0)
    }
    public func activateProject(_ key: ProjectKey) {
        let inProject = tabs.filter { $0.kind == .session && $0.projectKey == key }
        guard let first = inProject.first else { return }
        let remembered = lastActiveTabByProject[key].flatMap { id in inProject.first { $0.id == id } }
        activate(remembered ?? first)
    }

    public func selectNextProject() { cycleProject(by: 1) }
    public func selectPreviousProject() { cycleProject(by: -1) }

    private func cycleProject(by delta: Int) {
        let list = openProjectKeys
        guard list.count > 1 else { return }
        let current = activeProjectKey.flatMap { list.firstIndex(of: $0) } ?? 0
        activateProject(list[(current + delta + list.count) % list.count])
    }

    // MARK: Keyboard switching

    /// ⌘1–9 within the active project (1-based, session tabs only).
    public func selectTab(index: Int) {
        let sessionTabs = tabs.filter { $0.kind == .session && $0.projectKey == activeProjectKey }
        guard index >= 1, index <= sessionTabs.count else { return }
        activate(sessionTabs[index - 1])
    }

    /// What the ⌃⇥ switcher walks: every open tab, most recently visited first
    /// (the active tab leads, mirroring `projectsByRecency`). Spans projects —
    /// the activation trail does too, and `activate` handles the project
    /// switch. Tabs never visited this run (relaunch-restored chips) follow in
    /// row order, so nothing open is unreachable.
    public var tabsByRecency: [SessionTab] {
        let visited = activationHistory.reversed().compactMap { id in tabs.first { $0.id == id } }
        let unvisited = tabs.filter { tab in !activationHistory.contains(tab.id) }
        return visited + unvisited
    }

    // MARK: Persistence & lazy restore (U2)

    /// Title churn persists on a trailing edge. Every retitle used to rewrite
    /// the whole tab set through the DB synchronously — once a second per
    /// WORKING agent, forever. A restore only needs the title to be roughly
    /// current, so batching loses nothing; structural changes (open, close,
    /// reorder, quit) still call `persist()` directly.
    var titlePersistDelay: TimeInterval = 2.0
    private var titlePersistTask: Task<Void, Never>?

    private func schedulePersistForTitleChurn() {
        guard titlePersistTask == nil else { return }
        titlePersistTask = Task { [weak self] in
            if let delay = self?.titlePersistDelay, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, !self.isQuitting else { return }
            self.titlePersistTask = nil
            self.persist()
        }
    }

    private func persist() {
        var restorable = tabs
            .filter { $0.kind == .session && !$0.isProvisional }
            .compactMap { tab -> PersistedTab? in
                guard let sid = tab.sessionID else { return nil }
                return PersistedTab(sessionID: sid, agent: tab.agent, projectPath: tab.projectPath,
                                    title: tab.title, isActive: tab.id == activeTabID)
            }
        // The ACTIVE project's tabs go first (within-project order preserved):
        // restore() derives the launch-time active project from the first
        // saved tab, so this is what makes a relaunch come back showing the
        // project you were last working in.
        if let active = activeProjectKey {
            let keys = Dictionary(tabs.compactMap { tab in tab.sessionID.map { ($0, tab.projectKey) } }, uniquingKeysWith: { first, _ in first })
            restorable = restorable.filter { keys[$0.sessionID] == active }
                + restorable.filter { keys[$0.sessionID] != active }
        }
        persistence.save(restorable)
    }

    /// Rebuild the per-project tab set + order as **inert chips** (no surface
    /// spawns until a chip is clicked). Call once at launch.
    public func restore() {
        let saved = persistence.load()
        guard !saved.isEmpty else { return }
        // Copying a row into a chip writes nothing (ADR-029): no join and no
        // "opened" here. A chip joins, and records that it was opened, when
        // it spawns. Where the row lacks a fact (a legacy row has no
        // directory until a transcript or a spawn supplies one), the tab's
        // own persisted fact stands in; `activate` re-reads the row first.
        tabs = saved.map { p in
            let row = sessionRow(p.sessionID)
            let agent = row?.agent ?? p.resolvedAgent
            let directory = row?.directory ?? p.projectPath
            return SessionTab(kind: .session, sessionID: p.sessionID, agent: agent,
                              projectPath: directory,
                              title: row.flatMap { $0.state.customName ?? $0.state.title } ?? p.title,
                              isResume: true, host: row?.host ?? .local)
        }
        // Restore active project context without spawning anything.
        activeProjectKey = tabs.first?.projectKey
        // Every other chip stays inert until clicked (lazy restore). The one the
        // user was looking at when they quit is the exception: reopening to the
        // launcher after a quit reads as "Temple lost my session", so that one
        // tab is activated — which resumes exactly one agent, not the whole set.
        guard let activeIndex = saved.firstIndex(where: \.isActive) else {
            activeTabID = nil
            return
        }
        let active = tabs[activeIndex]
        activate(active)
        if !active.hasSurface, active.launchPreparationError == Self.unknownDirectoryMessage {
            pendingRestoreActivation = active.id
        }
    }
}

// MARK: - TerminalSurfaceDelegate

extension OpenSessionsModel: TerminalSurfaceDelegate {
    public func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {
        guard let tab = tab(for: surface) else { return }
        // Quitting drains every agent, so every surface reports .exited on the way
        // out. Those exits are the app closing, NOT the agents finishing — acting
        // on them would close every tab and persist an empty set, and ⌘Q would
        // quietly erase the session list it is supposed to be saving.
        if isQuitting { return }
        switch state {
        case .running(let pid):
            tab.activity = .running
            if let sid = tab.sessionID { registry.register(pid: pid, sessionID: sid) }
        case .exited(let status):
            if let sid = tab.sessionID { touchHandler?(sid, tab.host, nil) }
            // Whatever the launch reported is read now, before deciding: a
            // launcher failure written just before the exit is not missed.
            tab.launchResult?.finish()
            tab.launchResult = nil
            let userClosed = closingTabIDs.remove(tab.id) != nil
            // The launcher said the agent never ran: that is the failure to
            // show, however long the process lived, and the command was not
            // at fault.
            if !userClosed, tab.launchFailure != nil {
                tab.commandWasSuspect = false
                tab.activity = .exited(status: status)
                return
            }
            // Tab == process (ADR-010): a finished agent auto-closes its tab.
            // Exception: a process that dies within seconds of spawning (and
            // that the user did not close) almost certainly failed to launch
            // (bad binary path, invalid session id, missing cwd) — keep the
            // tab so the terminal's error output is readable instead of
            // flashing and vanishing.
            let age = tab.spawnedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if !userClosed, age < earlyExitGraceSeconds {
                // Freeze the verdict WITH the failure. The header shows the argv this
                // tab launched with, so it must be judged by what we knew then — not
                // by settings the user edits afterwards.
                tab.commandWasSuspect = launcherForHost(tab.host)?.availability(tab.agent) != .available
                // Resumes only: a NEW tab's freshly minted id is legitimately
                // absent from the index, and its early exit (auth, config)
                // has nothing to do with id rotation.
                diagnoseExit(tab)
                tab.activity = .exited(status: status)
            } else {
                autoClose(surface: surface)
            }
        case .notStarted:
            break
        }
    }

    public func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {
        guard !isQuitting, let tab = tab(for: surface), !title.isEmpty else { return }
        if tab.title != title, let sid = tab.sessionID { touchHandler?(sid, tab.host, nil) }
        tab.title = title
        // Agents retitle themselves as the work moves on, and record that title
        // nowhere on disk — hand it up so the sidebar and ⌘K can keep it.
        if let sid = tab.sessionID { titleHandler?(sid, tab.host, title) }
        // Item E: a live-updating title means the agent is working — keep the
        // settle heuristic from prematurely idling it.
        lastTitleChange[tab.id] = Date()
        // The same signal promotes a RESTING tab back to running. Return was
        // the only way back before, and plenty of resumptions never send one
        // through this surface: a permission prompt answered with a single
        // key or a mouse click, or the agent waking itself (scheduled tasks,
        // background notifications) — the dot sat gray through all of them.
        // Two deliberate exclusions: inside the ring grace the change is the
        // agent's own finishing retitle, not new work; and `.needsAttention`
        // stays sticky — it means "wants you", and a title twitch must not
        // clear a prompt you haven't seen.
        if tab.activity == .idle,
           Date().timeIntervalSince(lastRing[tab.id] ?? .distantPast) > ringGraceSeconds {
            tab.activity = .running
            scheduleSettle(for: tab)
        }
        schedulePersistForTitleChurn()
    }

    /// A bell / OSC notification means the agent stopped working — it finished or
    /// is awaiting input (Item E). If you're watching the tab it settles to
    /// idle; if it's in the background it raises attention.
    public func surfaceDidRing(_ surface: TerminalSurface) {
        raiseAttention(surface, title: "", body: "Terminal bell")
    }

    public func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {
        raiseAttention(surface, title: title, body: body)
    }

    /// The user submitted a prompt (Return) → the agent is now working (Item E).
    public func surfaceDidSubmitInput(_ surface: TerminalSurface) {
        guard !isQuitting, let tab = tab(for: surface), tab.kind == .session else { return }
        tab.inputSubmitted = true
        if let sid = tab.sessionID { touchHandler?(sid, tab.host, nil) }
        tab.activity = .running
        // Restart the settle clock so it can decay again once work finishes.
        lastTitleChange[tab.id] = Date()
        scheduleSettle(for: tab)
    }

    // Find in terminal: the surface counts, the tab's find model shows.
    public func surface(_ surface: TerminalSurface, didStartSearch needle: String?) {
        tab(for: surface)?.find.surfaceDidStart(needle: needle)
    }

    public func surfaceDidEndSearch(_ surface: TerminalSurface) {
        tab(for: surface)?.find.surfaceDidEnd()
    }

    public func surface(_ surface: TerminalSurface, didUpdateSearchTotal total: Int?) {
        tab(for: surface)?.find.surfaceDidUpdate(total: total)
    }

    public func surface(_ surface: TerminalSurface, didUpdateSearchSelected selected: Int?) {
        tab(for: surface)?.find.surfaceDidUpdate(selected: selected)
    }

    private func raiseAttention(_ surface: TerminalSurface, title: String, body: String) {
        guard let tab = tab(for: surface) else { return }
        // The signal fired → the agent is no longer working. Cancel any pending
        // settle; this decides the resting state directly.
        cancelSettle(for: tab.id)
        lastRing[tab.id] = Date()
        if tab.id == activeTabID {
            // You're already looking at it — no attention, just at rest.
            tab.activity = .idle
        } else {
            tab.activity = .needsAttention
            attentionHandler?(tab, title, body)
        }
    }
}

/// A request to land the Settings page on one agent's section (or the top).
/// `serial` makes two requests for the same agent distinct, so a second click
/// on the same warning scrolls again.
public struct SettingsFocusRequest: Equatable, Sendable {
    public let agent: Agent?
    public let serial: Int
}
