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
    private let extraArgs: (Agent) -> [String]
    private let defaultAgent: () -> Agent
    /// "Is there anything wrong with how we'd launch this agent?" — asked at the
    /// moment a tab dies, never afterwards (see `SessionTab.commandWasSuspect`).
    private let canLaunch: (Agent) -> Bool

    /// U7 hook: fired when a non-active tab needs attention (bell / OSC / etc.).
    public var attentionHandler: ((SessionTab, _ title: String, _ body: String) -> Void)?
    /// The agent retitled itself (sessionID, title) — AppModel persists it so the
    /// sidebar/palette show it, live and after the session closes.
    public var titleHandler: ((_ sessionID: String, _ title: String) -> Void)?
    /// Does any transcript on disk carry this session id? Answered from the
    /// index (AppModel wires it); nil means "can't say yet" — the index is
    /// still loading — and no verdict is recorded. Only a provable absence
    /// annotates a failure; this can prove a missing target, never a good one.
    public var sessionKnown: (_ sessionID: String) -> Bool? = { _ in nil }

    public init(surfaceFactory: TerminalSurfaceFactory,
                appearanceProvider: @escaping () -> TerminalAppearance,
                runtime: SessionRuntimeController,
                registry: ProcessRegistry,
                reconciler: CodexAdopting? = nil,
                persistence: TabPersistence? = nil,
                binaryPath: @escaping (Agent) -> String = { $0.binaryName },
                extraArgs: @escaping (Agent) -> [String] = { _ in [] },
                defaultAgent: @escaping () -> Agent = { .claude },
                canLaunch: @escaping (Agent) -> Bool = { _ in true }) {
        self.surfaceFactory = surfaceFactory
        self.appearanceProvider = appearanceProvider
        self.runtime = runtime
        self.registry = registry
        self.reconciler = reconciler ?? NoopCodexReconciler()
        self.persistence = persistence ?? UserDefaultsTabPersistence()
        self.binaryPath = binaryPath
        self.extraArgs = extraArgs
        self.defaultAgent = defaultAgent
        self.canLaunch = canLaunch
        super.init()
    }

    // MARK: Derived

    public var activeTab: SessionTab? { tabs.first { $0.id == activeTabID } }

    public var settingsTab: SessionTab? { tabs.first { $0.kind == .settings } }

    /// Visible-row index of the project-agnostic Settings chip (its ORDER is
    /// user-controlled via drag). This is a single GLOBAL offset, not a
    /// per-project one: dragging Settings sets where it sits in the row, and
    /// switching projects keeps that offset, clamped to the new project's row
    /// length (so a short row can't push it off the end). `.max` means
    /// "trailing" — the default, matching the original append behavior.
    /// Runtime-only; not persisted across restarts (the Settings tab itself is
    /// never persisted — it's re-created on demand — so there's nothing to
    /// anchor a saved offset to).
    private var settingsRowOffset: Int = .max

    /// The chips shown in the header strip: the active project's session tabs, in
    /// order, with the project-agnostic Settings chip (if open) inserted at its
    /// user-controlled `settingsRowOffset` (clamped to the row length).
    public var visibleTabs: [SessionTab] {
        let sessions = tabs.filter { $0.kind == .session && $0.projectPath == activeProjectPath }
        guard let settings = settingsTab else { return sessions }
        var result = sessions
        result.insert(settings, at: min(max(settingsRowOffset, 0), sessions.count))
        return result
    }

    private func sessionTab(withSessionID id: String) -> SessionTab? {
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
            // Extra args right after the binary so they precede subcommands
            // (`codex <flags> resume <id>`); claude accepts them anywhere.
            command.argv.insert(contentsOf: extraArgs(session.agent), at: 1)
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
        var spec = SessionLauncher.newSession(
            agent: agent,
            projectPath: projectPath,
            claudePath: binaryPath(.claude),
            codexPath: binaryPath(.codex))
        if !spec.command.argv.isEmpty {
            spec.command.argv.insert(contentsOf: extraArgs(agent), at: 1)
        }
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
            let projectChanged = activeProjectPath != tab.projectPath
            activeProjectPath = tab.projectPath
            lastActiveTabByProject[tab.projectPath] = tab.id
            touchProject(tab.projectPath)
            ensureSurface(for: tab)
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
        do {
            try surface.start(command)
        } catch {
            TempleUILog.launch.error("spawn failed: agent=\(tab.agent.rawValue, privacy: .public) argv0=\(command.argv.first ?? "?", privacy: .public) cwd=\(command.cwd, privacy: .public) error=\(String(describing: error), privacy: .public)")
            // A surface that won't even start is always the command's problem.
            tab.commandWasSuspect = true
            tab.activity = .exited(status: -1)
            return
        }
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

    private func removeTab(_ tabID: SessionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        cancelSettle(for: tabID)
        if let sid = tab.sessionID { registry.unregister(sessionID: sid) }
        let wasActive = activeTabID == tabID
        tabs.remove(at: index)
        // A project with no tabs left is not switchable — forget it, or the MRU
        // list grows for the life of the run as folders come and go.
        if !tabs.contains(where: { $0.kind == .session && $0.projectPath == tab.projectPath }) {
            projectMRU.removeAll { $0 == tab.projectPath }
            lastActiveTabByProject.removeValue(forKey: tab.projectPath)
        }
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

    /// Reorder the visible tab row by visible-row indices. The row is the active
    /// project's session chips plus (if open) the Settings chip at its offset —
    /// so both kinds are draggable. Dragging Settings just records its new global
    /// `settingsRowOffset`; dragging a session chip reorders the sessions within
    /// the active project (other projects' order is preserved).
    public func moveTab(fromOffsets: IndexSet, toOffset: Int) {
        let before = visibleTabs
        var row = before
        row.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // Only a drag OF the Settings chip changes its offset; dragging a session
        // reorders sessions while Settings stays pinned at its current offset (it
        // doesn't jump aside as sessions shuffle underneath it).
        let movedSettings = fromOffsets.contains { before.indices.contains($0) && before[$0].kind == .settings }
        if movedSettings, let settings = settingsTab {
            settingsRowOffset = row.firstIndex { $0.id == settings.id } ?? settingsRowOffset
        }
        // Write the reordered session chips back into the master list, preserving
        // other projects' relative order.
        guard let project = activeProjectPath else { persist(); return }
        let newOrder = row.filter { $0.kind == .session }
        var iterator = newOrder.makeIterator()
        var reordered: [SessionTab] = []
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

    // MARK: Project switching (the strip is scoped to one project)

    /// The projects you have sessions open in, in the order their first tab was
    /// opened. Deliberately not recency-ordered: a switcher whose entries
    /// reshuffle as you use it is one you can't build muscle memory for.
    public var openProjects: [String] {
        var seen: Set<String> = []
        return tabs.compactMap { tab in
            guard tab.kind == .session, seen.insert(tab.projectPath).inserted else { return nil }
            return tab.projectPath
        }
    }

    /// The session last active in each project, so coming back to a project
    /// returns you to where you were, not to whichever chip happens to be first.
    private var lastActiveTabByProject: [String: SessionTab.ID] = [:]

    /// Projects most-recently-used first. The ⌘P switcher walks this, so one tap
    /// lands on the project you were just in — the reason ⌘⇥ is worth using. It
    /// is deliberately NOT the order the sidebar or the title-bar list uses:
    /// those must hold still while you read them, and this must not.
    public var projectsByRecency: [String] {
        let open = Set(openProjects)
        let recent = projectMRU.filter(open.contains)
        return recent + openProjects.filter { !recent.contains($0) }
    }

    private var projectMRU: [String] = []

    private func touchProject(_ path: String) {
        projectMRU.removeAll { $0 == path }
        projectMRU.insert(path, at: 0)
    }

    /// Switch the strip to `project` and re-activate its last-used session. The
    /// other projects' tabs stay alive (and their agents keep running) — they
    /// were only hidden.
    public func activateProject(_ path: String) {
        let inProject = tabs.filter { $0.kind == .session && $0.projectPath == path }
        guard let first = inProject.first else { return }
        let remembered = lastActiveTabByProject[path].flatMap { id in inProject.first { $0.id == id } }
        activate(remembered ?? first)
    }

    public func selectNextProject() { cycleProject(by: 1) }
    public func selectPreviousProject() { cycleProject(by: -1) }

    private func cycleProject(by delta: Int) {
        let list = openProjects
        guard list.count > 1 else { return }
        let current = activeProjectPath.flatMap { list.firstIndex(of: $0) } ?? 0
        activateProject(list[(current + delta + list.count) % list.count])
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
                return PersistedTab(sessionID: sid, agent: tab.agent, projectPath: tab.projectPath, title: tab.title)
            }
        // The ACTIVE project's tabs go first (within-project order preserved):
        // restore() derives the launch-time active project from the first
        // saved tab, so this is what makes a relaunch come back showing the
        // project you were last working in.
        if let active = activeProjectPath {
            restorable = restorable.filter { $0.projectPath == active }
                + restorable.filter { $0.projectPath != active }
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
            if !argv.isEmpty {
                argv[0] = binaryPath(agent)  // GUI PATH lacks `claude`/`codex`
                argv.insert(contentsOf: extraArgs(agent), at: 1)
            }
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
            // Tab == process (ADR-010): a finished agent auto-closes its tab.
            // Exception: a process that dies within seconds of spawning (and
            // that the user did not close) almost certainly failed to launch
            // (bad binary path, invalid session id, missing cwd) — keep the
            // tab so the terminal's error output is readable instead of
            // flashing and vanishing.
            let age = tab.spawnedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if closingTabIDs.remove(tab.id) == nil, age < earlyExitGraceSeconds {
                // Freeze the verdict WITH the failure. The header shows the argv this
                // tab launched with, so it must be judged by what we knew then — not
                // by settings the user edits afterwards.
                tab.commandWasSuspect = !canLaunch(tab.agent)
                if let sid = tab.sessionID {
                    tab.resumeTargetMissing = sessionKnown(sid) == false
                }
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
        // Agents retitle themselves as the work moves on, and record that title
        // nowhere on disk — hand it up so the sidebar and ⌘K can keep it.
        if let sid = tab.sessionID { titleHandler?(sid, title) }
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
