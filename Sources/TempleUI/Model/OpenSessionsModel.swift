import SwiftUI
import TempleCore
import TempleTerminalAPI

/// The set of open tabs and the active one (U2). Each session tab owns a
/// `TerminalSurface` from the injected factory; reuse-or-focus prevents
/// duplicates; the active project (derived from the active session tab) scopes
/// the per-project horizontal tab bar.
@MainActor
public final class OpenSessionsModel: NSObject, ObservableObject {
    @Published public private(set) var tabs: [SessionTab] = []
    @Published public private(set) var activeTabID: SessionTab.ID?
    /// Derived from the active *session* tab; the Settings tab never changes it.
    @Published public private(set) var activeProjectPath: String?

    // Dependencies (injected; all swappable for Track C/T).
    private let surfaceFactory: TerminalSurfaceFactory
    private let appearanceProvider: () -> TerminalAppearance
    private let runtime: SessionRuntimeController
    private let registry: ProcessRegistry
    private let reconciler: CodexAdopting
    private let persistence: TabPersistence
    private let binaryPath: (Agent) -> String
    private let defaultAgent: () -> Agent

    /// U7 hook: fired when a non-active tab needs attention (bell / OSC / etc.).
    public var attentionHandler: ((SessionTab, _ title: String, _ body: String) -> Void)?

    public init(surfaceFactory: TerminalSurfaceFactory,
                appearanceProvider: @escaping () -> TerminalAppearance,
                runtime: SessionRuntimeController,
                registry: ProcessRegistry,
                reconciler: CodexAdopting? = nil,
                persistence: TabPersistence? = nil,
                binaryPath: @escaping (Agent) -> String = { $0.rawValue == "codex" ? "codex" : "claude" },
                defaultAgent: @escaping () -> Agent = { .claude }) {
        self.surfaceFactory = surfaceFactory
        self.appearanceProvider = appearanceProvider
        self.runtime = runtime
        self.registry = registry
        self.reconciler = reconciler ?? NoopCodexReconciler()
        self.persistence = persistence ?? UserDefaultsTabPersistence()
        self.binaryPath = binaryPath
        self.defaultAgent = defaultAgent
        super.init()
    }

    // MARK: Derived

    public var activeTab: SessionTab? { tabs.first { $0.id == activeTabID } }

    public var settingsTab: SessionTab? { tabs.first { $0.kind == .settings } }

    /// The chips shown in the header strip: the active project's session tabs, in
    /// order, plus the Settings tab (if open) which is project-agnostic.
    public var visibleTabs: [SessionTab] {
        var result = tabs.filter { $0.kind == .session && $0.projectPath == activeProjectPath }
        if let settings = settingsTab { result.append(settings) }
        return result
    }

    private func sessionTab(withSessionID id: String) -> SessionTab? {
        tabs.first { $0.kind == .session && $0.sessionID == id }
    }

    /// The open tab for a session id, if any (used by the sidebar for open/activity state).
    public func openTab(forSessionID id: String) -> SessionTab? {
        sessionTab(withSessionID: id)
    }

    private func tab(for surface: TerminalSurface) -> SessionTab? {
        tabs.first { $0.surface === surface }
    }

    public var allSurfaces: [TerminalSurface] {
        tabs.compactMap { $0.surface }
    }

    // MARK: Open / reuse-or-focus

    /// Click a sidebar session → focus its tab if open, else open a new one.
    /// Either way the session's project becomes active (UX "Open an existing
    /// session").
    public func openSession(_ session: AgentSession) {
        if let existing = sessionTab(withSessionID: session.id) {
            activate(existing)
            return
        }
        // Resolve the bare agent binary to the configured absolute path — a
        // Finder-launched app has a minimal PATH, so `claude`/`codex` alone
        // fails to spawn (instant exit → the tab would vanish).
        var command = SessionLauncher.resume(session)
        if !command.argv.isEmpty {
            command.argv[0] = binaryPath(session.agent)
        }
        let tab = SessionTab(
            kind: .session,
            sessionID: session.id,
            agent: session.agent,
            projectPath: session.projectPath,
            title: session.title,
            command: command)
        tabs.append(tab)
        activate(tab)
        persist()
    }

    // MARK: New session (U4)

    /// New empty session in a project with an explicit agent (`+` menu).
    @discardableResult
    public func newSession(agent: Agent, projectPath: String) -> SessionTab {
        let spec = SessionLauncher.newSession(
            agent: agent,
            projectPath: projectPath,
            claudePath: binaryPath(.claude),
            codexPath: binaryPath(.codex))
        let tab = SessionTab(
            kind: .session,
            sessionID: spec.sessionID,
            agent: spec.agent,
            projectPath: spec.projectPath,
            title: spec.title,
            command: spec.command,
            isProvisional: spec.isProvisional)
        tabs.append(tab)
        activate(tab)
        if spec.isProvisional {
            // Codex: adopt the real id once its rollout file appears (ADR-008).
            reconciler.reconcile(projectPath: projectPath, startedAt: Date()) { [weak self, weak tab] id in
                guard let self, let tab else { return }
                self.adopt(sessionID: id, for: tab.id)
            }
        }
        persist()
        return tab
    }

    /// ⌘T / empty-tab: new session in the current (or given) project with the
    /// configured default agent (UX keyboard path — no menu).
    @discardableResult
    public func newSessionDefaultAgent(projectPath: String? = nil) -> SessionTab? {
        guard let path = projectPath ?? activeProjectPath else { return nil }
        return newSession(agent: defaultAgent(), projectPath: path)
    }

    /// Codex reconcile seam (ADR-008): rebind a provisional tab to its real id.
    public func adopt(sessionID: String, for tabID: SessionTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.sessionID = sessionID
        tab.isProvisional = false
        if case .running(let pid) = tab.surface?.processState ?? .notStarted {
            registry.register(pid: pid, sessionID: sessionID)
        }
        persist()
    }

    // MARK: Activation & lazy surface spawn

    public func activate(_ tab: SessionTab) {
        activeTabID = tab.id
        if tab.kind == .session {
            activeProjectPath = tab.projectPath
            ensureSurface(for: tab)
            // Viewing a tab that was waiting for you clears its attention. The
            // agent already stopped working (that's what rang), so it settles to
            // idle rather than back to running (Item E).
            if tab.activity == .needsAttention { tab.activity = .idle }
        }
        tab.surface?.focus()
    }

    public func activate(tabID: SessionTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        activate(tab)
    }

    /// ⌘N / "return home": deactivate to the empty-state launcher without
    /// closing any tab. The launcher IS the new-session entry point (UX §New
    /// session) — there is no modal duplicate. Clicking a chip reactivates.
    public func showHome() {
        activeTabID = nil
    }

    /// Spawn the surface for a session tab on first activation (lazy restore).
    private func ensureSurface(for tab: SessionTab) {
        guard tab.kind == .session, tab.surface == nil, let command = tab.command else { return }
        let surface = surfaceFactory.makeSurface(appearance: appearanceProvider())
        surface.delegate = self
        tab.attach(surface: surface)
        try? surface.start(command)
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

    // MARK: Activity settle (Item E)

    /// How long after spawn (or the last title change) a still-`.running`, never-
    /// rung session decays to `.idle`. Overridable so tests exercise it fast.
    var settleDelaySeconds: TimeInterval = 15
    /// A session whose title changed within this window is treated as actively
    /// working (Claude Code live-updates its title while thinking).
    var titleQuietWindow: TimeInterval = 4

    /// Last time each tab's title changed — feeds the settle heuristic.
    private var lastTitleChange: [SessionTab.ID: Date] = [:]
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
    }

    // MARK: Settings (U9) — singleton utility tab

    public func openSettings() {
        if let settings = settingsTab {
            activeTabID = settings.id
            return
        }
        let tab = SessionTab(kind: .settings, sessionID: nil, agent: .claude,
                             projectPath: "", title: "Settings", command: nil)
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
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
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

    public func closeActiveTab() {
        if let id = activeTabID { closeTab(id) }
    }

    private func removeTab(_ tabID: SessionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        cancelSettle(for: tabID)
        if let sid = tab.sessionID { registry.unregister(sessionID: sid) }
        let wasActive = activeTabID == tabID
        tabs.remove(at: index)
        if wasActive { selectNeighbor(removedIndex: index, removedProject: tab.projectPath, wasUtility: tab.isUtility) }
        persist()
    }

    private func selectNeighbor(removedIndex: Int, removedProject: String, wasUtility: Bool) {
        // Prefer another tab in the same project; else any session tab; else nil.
        let sameProject = tabs.filter { $0.kind == .session && $0.projectPath == removedProject }
        if let next = sameProject.first {
            activate(next)
        } else if let anySession = tabs.first(where: { $0.kind == .session }) {
            activate(anySession)
        } else if let settings = settingsTab {
            activeTabID = settings.id
        } else {
            activeTabID = nil
            // Keep activeProjectPath so the launcher defaults to the last project.
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

    /// Move a tab within its project (visible-order indices).
    public func moveTab(fromOffsets: IndexSet, toOffset: Int) {
        guard let project = activeProjectPath else { return }
        var projectTabs = tabs.filter { $0.kind == .session && $0.projectPath == project }
        projectTabs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // Rebuild the master list preserving other projects' relative order.
        var reordered: [SessionTab] = []
        var iterator = projectTabs.makeIterator()
        for tab in tabs {
            if tab.kind == .session && tab.projectPath == project {
                if let next = iterator.next() { reordered.append(next) }
            } else {
                reordered.append(tab)
            }
        }
        tabs = reordered
        persist()
    }

    // MARK: Keyboard switching

    /// ⌘1–9 within the active project (1-based, session tabs only).
    public func selectTab(index: Int) {
        let sessionTabs = tabs.filter { $0.kind == .session && $0.projectPath == activeProjectPath }
        guard index >= 1, index <= sessionTabs.count else { return }
        activate(sessionTabs[index - 1])
    }

    public func selectNextTab() { cycle(by: 1) }
    public func selectPreviousTab() { cycle(by: -1) }

    private func cycle(by delta: Int) {
        let list = visibleTabs
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == activeTabID } ?? 0
        let next = (current + delta + list.count) % list.count
        activate(list[next])
    }

    // MARK: Persistence & lazy restore (U2)

    private func persist() {
        let restorable = tabs
            .filter { $0.kind == .session && !$0.isProvisional }
            .compactMap { tab -> PersistedTab? in
                guard let sid = tab.sessionID else { return nil }
                return PersistedTab(sessionID: sid, agent: tab.agent, projectPath: tab.projectPath, title: tab.title)
            }
        persistence.save(restorable)
    }

    /// Rebuild the per-project tab set + order as **inert chips** (no surface
    /// spawns until a chip is clicked). Call once at launch.
    public func restore() {
        let saved = persistence.load()
        guard !saved.isEmpty else { return }
        tabs = saved.map { p in
            let agent = p.resolvedAgent
            var argv = agent.resumeArgv(sessionID: p.sessionID)
            if !argv.isEmpty { argv[0] = binaryPath(agent) }  // GUI PATH lacks `claude`/`codex`
            let command = TerminalCommand(argv: argv, cwd: p.projectPath)
            return SessionTab(kind: .session, sessionID: p.sessionID, agent: agent,
                              projectPath: p.projectPath, title: p.title, command: command)
        }
        // Restore active project context without spawning anything.
        activeProjectPath = tabs.first?.projectPath
        // No active tab → launcher shows until the user clicks a chip.
        activeTabID = nil
    }
}

// MARK: - TerminalSurfaceDelegate

extension OpenSessionsModel: TerminalSurfaceDelegate {
    public func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {
        guard let tab = tab(for: surface) else { return }
        switch state {
        case .running(let pid):
            tab.activity = .running
            if let sid = tab.sessionID { registry.register(pid: pid, sessionID: sid) }
        case .exited(let status):
            // Tab == process (ADR-010): a finished agent auto-closes its tab.
            // Exception: a process that dies within seconds of spawning (and
            // that the user did not close) almost certainly failed to launch
            // (bad binary path, invalid session id, missing cwd) — keep the
            // tab so the terminal's error output is readable instead of
            // flashing and vanishing.
            let age = tab.spawnedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if closingTabIDs.remove(tab.id) == nil, age < earlyExitGraceSeconds {
                tab.activity = .exited(status: status)
            } else {
                autoClose(surface: surface)
            }
        case .notStarted:
            break
        }
    }

    public func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {
        guard let tab = tab(for: surface), !title.isEmpty else { return }
        tab.title = title
        // Item E: a live-updating title means the agent is working — keep the
        // settle heuristic from prematurely idling it.
        lastTitleChange[tab.id] = Date()
        persist()
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
        guard let tab = tab(for: surface), tab.kind == .session else { return }
        tab.activity = .running
        // Restart the settle clock so it can decay again once work finishes.
        lastTitleChange[tab.id] = Date()
        scheduleSettle(for: tab)
    }

    private func raiseAttention(_ surface: TerminalSurface, title: String, body: String) {
        guard let tab = tab(for: surface) else { return }
        // The signal fired → the agent is no longer working. Cancel any pending
        // settle; this decides the resting state directly.
        cancelSettle(for: tab.id)
        if tab.id == activeTabID {
            // You're already looking at it — no attention, just at rest.
            tab.activity = .idle
        } else {
            tab.activity = .needsAttention
            attentionHandler?(tab, title, body)
        }
    }
}
