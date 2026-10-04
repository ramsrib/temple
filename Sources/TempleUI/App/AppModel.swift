import SwiftUI
import Combine
import AppKit
import TempleCore
import TempleTerminalAPI

/// Root coordinator: owns the index, settings, theme, open tabs, lifecycle,
/// notifications, and the seams to Tracks C/T. Everything the views observe
/// hangs off here.
@MainActor
public final class AppModel: ObservableObject {
    /// Default project limit exposed for future Settings integration; no
    /// Settings UI row is wired yet.
    public static let projectCap = 8

    // Data
    /// Member presentation, independent of transcript availability, in the
    /// order and grouping of the last build, with each row's current value.
    /// After the rank freeze, activity moves no row and the rail shows none:
    /// a recency-only change updates `presentedByID` alone — no build, no
    /// publish — and consumers that show recency (the palette, the picker,
    /// the launcher, the archive) read it here when they next draw.
    public var sessions: [Session] { builtSessions.map { presentedByID[$0.id] ?? $0 } }
    public var rowProjects: [SessionRowProject] {
        builtRowProjects.map { project in
            SessionRowProject(key: project.key, sessions: project.sessions.map { presentedByID[$0.id] ?? $0 })
        }
    }
    /// The last build's result. Published by hand, and only when a build
    /// changes it.
    private var builtSessions: [Session] = []
    private var builtRowProjects: [SessionRowProject] = []
    private var applyingEngineSnapshot = false
    private var ownershipChangedWhileApplying = false
    private var rowPresentationDirty = false
    /// Diagnostic work count, including builds whose values compare equal.
    private(set) var sessionPresentationBuildCount = 0
    private var rowPresentationScheduled = false
    private var presentedByID: [String: Session] = [:]
    private(set) var rowPresentationSortCount = 0
    private(set) var rowProjectBuildCount = 0

    private func scheduleRowPresentation() {
        guard !rowPresentationScheduled else { return }
        rowPresentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rowPresentationScheduled = false
                if self.rowPresentationDirty { self.rebuildSessions() }
            }
        }
    }

    private var latestEngineSnapshot: EngineSnapshot?

    func receiveEngineSnapshot(_ snapshot: EngineSnapshot) {
        if let latestEngineSnapshot, snapshot.generation < latestEngineSnapshot.generation { return }
        let resolutionsChanged = latestEngineSnapshot?.resolutions != snapshot.resolutions
        latestEngineSnapshot = snapshot
        applyingEngineSnapshot = true
        overlay.applyFacts(snapshot.facts)
        applyingEngineSnapshot = false
        // An ownership change seen while facts were being written is merged
        // now, never from inside the write (it may deliver a new snapshot).
        if ownershipChangedWhileApplying {
            ownershipChangedWhileApplying = false
            engineSet.ownershipChanged()
        }
        if rowPresentationDirty || resolutionsChanged { rebuildSessions() }
        if !sidebarRanksFrozen && builtSessions.allSatisfy({ row in
            switch snapshot.resolutions[row.id] {
            case .loaded, .confirmedAbsent, .unreadable, .mismatch: return true
            default: return false
            }
        }) { freezeSidebarRanks() }
        openSessions.refreshExitedResumeDiagnoses()
    }

    /// Facts, membership and resolution changes (and, before the freeze,
    /// activity) use a full recomputation. There is no incremental sorted
    /// sequence or project membership cache to maintain.
    private func rebuildSessions() {
        rowPresentationDirty = false
        sessionPresentationBuildCount += 1
        let rows = overlay.rows.values.map { Session(state: $0, resolution: latestEngineSnapshot?.resolutions[$0.id]) }
        rowPresentationSortCount += 1
        let next = rows.sorted(by: Self.moreRecentRow)
        let grouped = Dictionary(grouping: next.filter { $0.project != nil }) { $0.project! }
        rowProjectBuildCount += grouped.count
        rowPresentationSortCount += 1
        let projects = grouped.map { SessionRowProject(key: $0.key, sessions: $0.value) }
            .sorted(by: SessionRowProject.moreRecent)
        // Compared with what was last presented, current values included
        // (so before `presentedByID` moves on): a build that reproduces it
        // publishes nothing.
        let sessionsChanged = next != sessions
        let projectsChanged = projects != rowProjects
        if sessionsChanged || projectsChanged { objectWillChange.send() }
        presentedByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        builtSessions = next
        builtRowProjects = projects
        extendRowRanks()
        openSessions.rowsChanged()
        if sessionsChanged { history.rowsChanged() }
    }

    /// After the freeze, activity moves no row and nothing the rail draws
    /// shows it: the row's current value is kept for whoever reads it, and
    /// nothing is rebuilt or published. A row not yet presented waits for
    /// the build its own change already asked for.
    private func applyRecency(_ id: String) {
        guard presentedByID[id] != nil, let state = overlay.rows[id] else { return }
        presentedByID[id] = Session(state: state, resolution: latestEngineSnapshot?.resolutions[id])
    }

    private static func moreRecentRow(_ lhs: Session, _ rhs: Session) -> Bool {
        lhs.sortDate == rhs.sortDate ? lhs.id < rhs.id : lhs.sortDate > rhs.sortDate
    }

    private(set) var sidebarRanksFrozen = false
    private var sidebarRankingStarted = false
    /// A one-shot scheduler seam: tests deliver the deadline without waiting.
    var scheduleSidebarFreeze: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { action() } }
    }

    func beginSidebarRanking() {
        guard !sidebarRankingStarted else { return }
        sidebarRankingStarted = true
        scheduleSidebarFreeze(3) { [weak self] in self?.freezeSidebarRanks() }
    }

    private func freezeSidebarRanks() {
        guard !sidebarRanksFrozen else { return }
        if rowPresentationDirty { rebuildSessions() }
        sidebarRanksFrozen = true
        extendRowRanks()
        objectWillChange.send()
    }

    /// Row recency stays live until initial resolution completes or the
    /// startup deadline fires. A project or session first seen after that
    /// takes its place by recency among the frozen ones: a new session lands
    /// on top, but an old row that only now learned its folder does not.
    private var frozenProjectOrder: [ProjectKey] = []
    private var frozenSessionOrder: [ProjectKey: [String]] = [:]
    private var knownProjectKeys = Set<ProjectKey>()
    private var knownSessionIDs: [ProjectKey: Set<String>] = [:]

    private func extendRowRanks() {
        guard sidebarRanksFrozen else { return }
        let activity = Dictionary(rowProjects.map { ($0.key, $0.lastActivity) }, uniquingKeysWith: { first, _ in first })
        let keys = rowProjects.map(\.key).filter { !knownProjectKeys.contains($0) }
        Self.place(keys, into: &frozenProjectOrder) { activity[$0] ?? .distantPast }
        knownProjectKeys.formUnion(keys)
        for project in rowProjects {
            let known = knownSessionIDs[project.key] ?? []
            let ids = project.sessions.map(\.id).filter { !known.contains($0) }
            Self.place(ids, into: &frozenSessionOrder[project.key, default: []]) {
                presentedByID[$0]?.sortDate ?? .distantPast
            }
            knownSessionIDs[project.key, default: []].formUnion(ids)
        }
    }

    /// Each newcomer goes before the first frozen entry less recent than it.
    private static func place<Key>(_ newcomers: [Key], into order: inout [Key], date: (Key) -> Date) {
        for key in newcomers.sorted(by: { date($0) > date($1) }) {
            let when = date(key)
            order.insert(key, at: order.firstIndex { date($0) < when } ?? order.endIndex)
        }
    }

    public var visibleRows: [Session] {
        sessions.filter { !$0.state.archived && !($0.project.map { overlay.isProjectArchived($0) } ?? false) }
    }
    public var visibleRowProjects: [SessionRowProject] {
        rowProjects.compactMap { project in
            guard !overlay.isProjectArchived(project.key) else { return nil }
            let rows = project.sessions.filter { !$0.state.archived }
            return rows.isEmpty ? nil : SessionRowProject(key: project.key, sessions: rows)
        }.sorted(by: SessionRowProject.moreRecent)
    }

    private func orderedRowProjects(_ projects: [SessionRowProject]) -> [SessionRowProject] {
        let byKey = Dictionary(uniqueKeysWithValues: projects.map { ($0.key, $0) })
        let placed = Set(overlay.projectKeyOrder)
        let order = sidebarRanksFrozen ? frozenProjectOrder : projects.map(\.key)
        return order.filter { !placed.contains($0) }.compactMap { byKey[$0] }
            + overlay.projectKeyOrder.compactMap { byKey[$0] }
    }

    @Published public var isLoading = true

    // Sidebar UI state (U1)
    @Published public var searchText = ""
    @Published public var highlightedID: String?

    /// Restored from `UIStateStore` in `init` (property observers don't fire
    /// there, so the restore doesn't write itself straight back). Every later
    /// change persists — including the ones SwiftUI makes through the binding.
    @Published public var sidebarVisibility: NavigationSplitViewVisibility {
        didSet { uiState.setSidebarVisibility(sidebarVisibility) }
    }
    /// The one definition of what ⌘B does. Both callers — the key handler and
    /// the View menu item — go through here: when this lived inline in two
    /// places, both spelled the test as `== .all`, and both were wrong the same
    /// way (see `isSidebarHidden`). A second copy is a second chance to get it
    /// wrong, and neither copy was reachable from a test.
    public func toggleSidebar() {
        sidebarVisibility = sidebarVisibility.isSidebarHidden ? .all : .detailOnly
    }

    /// ⌘O: a folder Temple has never seen, opened as a new session with the
    /// default agent. The menu item, the key handler and the project
    /// switcher's "Open project…" all come through here.
    public func openProjectFolder() {
        chooseProjectFolder { project in
            openSessions.newSessionDefaultAgent(project: project)
        }
    }

    @Published public var commandPalettePresented = false
    @Published public var archivePresented = false
    @Published public var newSessionPickerPresented = false

    // ⌘P project switcher (ProjectSwitcherHUD) — modelled on ⌘⇥, not on ⌘K:
    // switching projects is picking from a handful you are holding in your head,
    // not searching. Hold ⌘, tap P to walk the most-recently-used list, release
    // to commit. Sessions get the search palette; projects get the switcher.
    @Published public var projectSwitcherPresented = false
    /// The highlighted project, held as a PATH rather than an index: a project's
    /// last tab can exit while the switcher is up, and an index into a list that
    /// shrank under you lands on the wrong project (or silently on none).
    @Published public var projectSwitcherKeySelection: ProjectKey?
    /// True when ⌘ was down as the switcher opened. Only then does releasing ⌘
    /// commit — otherwise opening it from the home page (mouse, no ⌘ held) would
    /// be committed by the next unrelated modifier press.
    private var switcherArmedByCommand = false

    // ⌃⇥ tab switcher (TabSwitcherHUD) — the same gesture one level down:
    // hold ⌃, tap ⇥ to walk the most-recently-visited tabs, release to land.
    // One tap-and-release bounces to the tab you were just on.
    @Published public var tabSwitcherPresented = false
    /// Held as a tab ID, not an index — a tab can close while the switcher is
    /// up, and an index into a list that shrank lands on the wrong tab.
    @Published public var tabSwitcherSelection: SessionTab.ID?
    /// Same arming rule as the ⌘P switcher, for ⌃.
    private var tabSwitcherArmedByControl = false
    @Published public var shortcutsPresented = false

    /// The find bar of the terminal on screen, if a terminal is showing
    /// (⌘F / ⌘G). Sidebar search has no shortcut — it is a click away.
    public var activeTerminalFind: TerminalFindModel? {
        guard let tab = openSessions.activeTab, tab.kind == .session, tab.hasSurface else { return nil }
        return tab.find
    }

    /// A floating panel is up (⌘K / ⌘⇧Y / ⌘N / ⌘/): it owns the keyboard,
    /// so find must not open — or claim focus — underneath it.
    public var panelPresented: Bool {
        commandPalettePresented || archivePresented
            || newSessionPickerPresented || shortcutsPresented
    }

    /// The History tab is on screen: ⌘F, ⌘R, ⌘A, arrows and Esc are its.
    public var historyActive: Bool {
        openSessions.activeTab?.kind == .history
    }

    /// ⌘F: the terminal's find bar — or, on the History tab (no terminal to
    /// find in), History's own search field.
    public func findInActiveTerminal() {
        guard !panelPresented else { return }
        if historyActive {
            history.requestSearchFocus()
            return
        }
        activeTerminalFind?.open()
    }

    /// Menu mirror of ⌘G / ⌘⇧G: acts only while the bar is open, exactly like
    /// the key handler, so the two paths never disagree.
    public func navigateActiveTerminalFind(_ direction: TerminalSearchDirection) {
        guard let find = activeTerminalFind, find.isPresented else { return }
        direction == .next ? find.next() : find.previous()
    }

    // Sub-models
    public let settings: SettingsStore
    let uiState: UIStateStore
    public let overlay: SessionOverlayStore
    public let openSessions: OpenSessionsModel
    public let notifications: NotificationController
    /// Subscription usage for the sidebar footer (see UsageMeterModel).
    /// Inert until start() — tests never hit the network.
    public let usage = UsageMeterModel()
    /// Which `claude`/`codex` this machine actually has, and which of them run.
    public let toolchain: ToolchainModel
    /// The History tab: every session on disk, read on demand (ADR-027).
    public let history: HistoryModel

    // Seams (Track C)
    /// Where the database lives; nil for an in-memory one. Startup
    /// housekeeping happens beside it and nowhere else.
    private let databaseDirectory: URL?
    /// One engine per registry host, merged by current row ownership.
    let engineSet: EngineSet
    public let hostRegistry: HostRegistry

    private var cancellables: Set<AnyCancellable> = []
    private var themeObserver: NSObjectProtocol?
    public init(surfaceFactory: TerminalSurfaceFactory = StubTerminalSurfaceFactory(),
                engines: [any HostEngine]? = nil,
                registry: ProcessRegistry? = nil,
                reconciler: CodexAdopting? = nil,
                persistence: TabPersistence? = nil,
                database: TempleDB,
                settings: SettingsStore? = nil,
                overlay: SessionOverlayStore? = nil,
                hostRegistry: HostRegistry? = nil) {
        // Defaults that touch @MainActor types are built here (not as default
        // arguments, which evaluate in a nonisolated context).
        let settings = settings ?? SettingsStore(defaults: SettingsKeysProbe.scratchDefaults() ?? .standard)
        let overlay = overlay ?? SessionOverlayStore(db: database)
        let uiState = UIStateStore(db: database)
        let registry = registry ?? DBProcessRegistry(db: database)
        let persistence = persistence ?? DBTabPersistence(db: database)
        let toolchain = ToolchainModel()
        toolchain.override = { [weak settings] in settings?.overridePath(for: $0) ?? "" }
        toolchain.arguments = { [weak settings] in settings?.extraArgs(for: $0) ?? [] }
        self.toolchain = toolchain

        let hosts = hostRegistry ?? HostRegistry(localLauncher: LocalHostLauncher(
            binaryPath: { toolchain.launchPath(for: $0) },
            extraArgs: { settings.extraArgs(for: $0) }, availability: { toolchain.launchAvailability($0) }))
        self.hostRegistry = hosts
        let engineSet = EngineSet(engines: engines ?? hosts.entries.map {
            SessionEngine(source: $0.source, database: database)
        })
        let reconciler = reconciler ?? CodexAdopter(registry: hosts)
        self.settings = settings
        self.overlay = overlay
        self.uiState = uiState
        self.sidebarVisibility = uiState.sidebarVisibility ?? .all
        self.engineSet = engineSet
        self.databaseDirectory = database.fileURL?.deletingLastPathComponent()
        self.notifications = NotificationController()
        self.history = HistoryModel(overlay: overlay, catalog: { hosts.catalog() },
            directoryEvidence: { key in await hosts.entry(for: key.host)?.source.directoryEvidence(key.path) ?? .unknown })


        let runtime = SessionRuntimeController()
        let settingsRef = settings
        // appearanceProvider is set after self is available (see wiring below).
        var resolveAppearance: () -> TerminalAppearance = { .default }
        self.openSessions = OpenSessionsModel(
            surfaceFactory: surfaceFactory,
            appearanceProvider: { resolveAppearance() },
            runtime: runtime,
            registry: registry,
            reconciler: reconciler,
            persistence: persistence,
            defaultAgent: { settingsRef.defaultAgent },
            launcherForHost: { hosts.entry(for: $0)?.launcher },
            directoryEvidence: { key in await hosts.entry(for: key.host)?.source.directoryEvidence(key.path) ?? .unknown })

        // Now self is fully initialized — finish wiring the closures & observers.
        resolveAppearance = { [weak self] in
            self?.currentAppearance() ?? .default
        }
        engineSet.owner = { [weak overlay] id in overlay?.rows[id]?.host }
        overlay.onOwnershipMismatch = { [weak engineSet] id, host in engineSet?.reconcileMembership(id, host: host) }
        rebuildSessions()
        overlay.rowChanges
            .sink { [weak self] change in
                guard let self else { return }
                if change.recencyOnly && self.sidebarRanksFrozen {
                    self.applyRecency(change.id)
                    return
                }
                self.rowPresentationDirty = true
                if !change.recencyOnly {
                    // A row joined, left or moved host: the merge follows it
                    // (after the facts being applied, if any).
                    if self.applyingEngineSnapshot { self.ownershipChangedWhileApplying = true }
                    else { self.engineSet.ownershipChanged() }
                }
                guard !self.applyingEngineSnapshot else { return }
                if change.recencyOnly {
                    self.scheduleRowPresentation()
                } else {
                    self.rebuildSessions()
                }
            }
            .store(in: &cancellables)
        wire()
        wireHistory(database: database)
        // NB: detection is NOT started here. It runs real binaries (`claude --version`),
        // and `AppModel` is constructed by tests — which must not shell out to whatever
        // CLIs happen to be on the machine. `RootView` starts it when the UI appears.
    }

    private func wire() {
        // U7: route attention → native notification.
        openSessions.attentionHandler = { [weak self] tab, title, body in
            guard let self else { return }
            let message = body.isEmpty ? title : body
            self.notifications.post(projectName: tab.projectKey.displayName,
                                    sessionTitle: overlayTitle(tab: tab),
                                    sessionID: tab.sessionID,
                                    body: message)
        }
        // U7: notification click → focus that session's tab.
        notifications.onActivateSession = { [weak self] sessionID in
            self?.openSession(id: sessionID)
        }
        // The agent renamed itself → remember it, so the sidebar and ⌘K track a
        // long session instead of showing the prompt it opened with an hour ago.
        openSessions.titleHandler = { [weak self] sessionID, host, title in
            self?.overlay.recordGeneratedTitle(title, for: sessionID, host: host)
        }
        // Whatever a tab runs is a Temple session from then on — including one
        // resumed from elsewhere, which is how it joins the sidebar.
        openSessions.openedHandler = { [weak self] open in
            guard let self else { return .joined }
            let result = self.overlay.join(open.id, via: open.via, agent: open.agent, locator: open.locator,
                                           core: SessionCore(host: open.host))
            guard result.conflict == nil else { return result }
            // Durably: History's Undo Import must keep a session that was
            // opened since, even once its tab is closed (TempleDB.leave
            // keeps a row with last_opened_at set).
            if open.via == .opened { self.overlay.recordOpened(open.id, host: open.host) }
            if let engine = self.engineSet.engine(for: open.host) {
                if case .loaded = engine.latestSnapshot?.resolutions[open.id] { return result }
                Task { await engine.requestResolution(open.id) }
            }
            return result
        }
        openSessions.touchHandler = { [weak self] id, host, at in self?.overlay.touch(id, host: host, at: at) }
        // ⌘T then close without typing: the minted id never got a transcript,
        // and its row would read "New Claude session" forever. The tab's
        // process is gone by now; only a fresh, completed absence from the
        // owning engine lets the row go — never a cached verdict. When in
        // doubt the stray row stays: deleting one the user cares about is
        // the worse mistake.
        openSessions.unstartedHandler = { [weak self] id, host in
            guard let self, self.overlay.rows[id]?.host == host,
                  let engine = self.engineSet.engine(for: host) else { return }
            Task { @MainActor [weak self] in
                guard await engine.confirmAbsence(id), let self,
                      self.overlay.discardUnstartedCreation(id, host: host) else { return }
                self.openSessions.forgetClosedTabs(sessionID: id)
            }
        }
        openSessions.launchDirectoryHandler = { [weak self] id, host, cwd in
            self?.overlay.observeLaunchDirectory(id, host: host, cwd)
        }
        // A resume failure uses this member's completed resolution. A newly
        // launched or unreadable transcript never acquires a missing verdict.
        openSessions.sessionKnown = { [weak self] sessionID in
            guard let self else { return nil }
            switch self.latestEngineSnapshot?.resolutions[sessionID] {
            case .loaded: return true
            case .confirmedAbsent: return false
            default: return nil
            }
        }
        openSessions.sessionRow = { [weak self] id in
            self?.presentedByID[id]
        }

        // Sidebar highlight follows the active tab (UX "Select vs. open").
        openSessions.$activeTabID
            .receive(on: RunLoop.main)
            .sink { [weak self] tabID in
                // Resolve the EMITTED id, not `activeTab`: delivery is a run-loop
                // turn late, and two activations in one turn (open A, land on B)
                // would both see B — leaving A archived and B untouched.
                guard let self, let tabID,
                      let tab = self.openSessions.tabs.first(where: { $0.id == tabID })
                else { return }
                if let sid = tab.sessionID {
                    self.highlightedID = sid
                    // Opening is the one thing that un-hides: you went looking
                    // for it, so it belongs back in the rail. Disk activity
                    // does NOT — a session resumed in another terminal must
                    // stay put away.
                    if self.overlay.isArchived(sid) {
                        self.overlay.setArchived(false, sessionID: sid)
                    }
                }
                if self.overlay.isProjectArchived(tab.projectKey) {
                    self.overlay.setProjectArchived(false, key: tab.projectKey)
                }
            }
            .store(in: &cancellables)
        // Live appearance (U9/U10), from the settings that change it and nothing
        // else. Re-applying is a config rewrite pushed to every terminal, and it
        // used to run on *any* settings change, so each key typed in an agent's
        // Command or Arguments field re-tinted every open terminal and
        // re-rendered the whole window. The Settings page observes the store
        // itself; the rest of the app hears only what it reads. The font family
        // is a text field: apply it once typing pauses, not per letter.
        // (`$x` fires on willSet; the main-loop hop reads the new value.)
        Publishers.Merge3(
            settings.$fontSize.removeDuplicates().dropFirst().map { _ in () },
            settings.$theme.removeDuplicates().dropFirst().map { _ in () },
            settings.$fontFamily.removeDuplicates().dropFirst()
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAppearance()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        settings.$defaultAgent.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Pins / renames re-publish so the computed sidebar views refresh.
        overlay.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        openSessions.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Detection lands asynchronously — Settings and the launcher banner want it.
        toolchain.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The History tab's hands: how it opens a row and what it must not undo
    /// out from under a tab. Its view state lives as long as the tab does.
    private func wireHistory(database: TempleDB) {
        history.openSession = { [weak self] session in
            self?.openSessions.openSession(session)
        }
        history.hasOpenTab = { [weak self] key in
            self?.openSessions.openTab(forSessionID: key.sessionID)?.host == key.host
        }
        history.memberRows = { [weak self] in self?.sessions ?? [] }
        history.archiveMember = { [weak self] in self?.archiveSession($0, undoManager: $1) }
        history.openMember = { [weak self] in self?.openSessions.openSession($0) }
        var historyWasOpen = false
        openSessions.$tabs
            .sink { [weak self] tabs in
                let open = tabs.contains { $0.kind == .history }
                if historyWasOpen, !open { self?.history.reset() }
                historyWasOpen = open
            }
            .store(in: &cancellables)
    }

    /// ⌘K's dead end points at the door: the palette's "Search history for
    /// …" row opens History already narrowed to the query.
    public func searchHistory(_ query: String) {
        commandPalettePresented = false
        history.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        openSessions.openHistory()
    }

    /// Asks the sidebar to scroll a row into view. A serial, so asking for
    /// the same row twice scrolls twice (the user may have scrolled away).
    public struct SidebarReveal: Equatable {
        public let sessionID: String
        let serial: Int
    }
    @Published public private(set) var sidebarReveal: SidebarReveal?

    /// History's "Show in Sidebar": light the row in the rail and scroll it
    /// into view, opening the rail if it is hidden. The user stays where they
    /// are.
    public func showInSidebar(_ id: String) {
        highlightedID = id
        let request = SidebarReveal(sessionID: id, serial: (sidebarReveal?.serial ?? 0) + 1)
        guard sidebarVisibility.isSidebarHidden else {
            sidebarReveal = request
            return
        }
        sidebarVisibility = .all
        // A scroll inside a column still sliding in does not take; ask once
        // it is there (the sidebar search's reveal waits the same way).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.sidebarReveal = request
        }
    }

    private func overlayTitle(tab: SessionTab) -> String { sessionTabTitle(tab) }

    /// A session tab's name in chrome: the user's rename, then the title the
    /// row recorded, then the tab's own title — which for a restored chip is
    /// the title it was saved with, and for a new tab says what it is. The
    /// row's placeholder ("New Claude session") never beats a real title.
    private func sessionTabTitle(_ tab: SessionTab) -> String {
        if let sid = tab.sessionID, let row = presentedByID[sid],
           let title = row.state.customName ?? row.state.title { return title }
        return tab.title
    }

    // MARK: Lifecycle

    public func start() {
        beginSidebarRanking()
        applyAppearance()
        openSessions.restore()
        retireIndexCacheOnce()
        engineSet.start { [weak self] snapshot in
            // Every snapshot lands here; republishing an unchanged flag
            // re-renders everything that observes the model.
            if self?.isLoading == true { self?.isLoading = false }
            self?.receiveEngineSnapshot(snapshot)
        }
        // U10: follow macOS appearance live when theme == .system.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyAppearance() }
            }
    }

    /// The pre-ADR-029 launch cache is obsolete: rows in SQLite are the launch
    /// path. It is removed once, not on every launch — an older Temple still
    /// installed beside this one rebuilds and relies on it, and deleting it
    /// each time would cold-start that build on every one of its launches.
    /// It lives beside the database, so a model on an in-memory database
    /// (every test that does not ask for a file) touches no state directory.
    private func retireIndexCacheOnce() {
        guard let directory = databaseDirectory else { return }
        let marker = directory.appendingPathComponent(".index-cache-retired")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("index-cache.json"))
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    /// App-quit drain (ADR-010) → returns true once all surfaces are down.
    public func drainForQuit(completion: @escaping () -> Void) {
        // The last title an agent gave itself may still be coalescing.
        overlay.flushPendingTitles()
        overlay.flushPendingTouches()
        // Freeze the open-tab set BEFORE the agents start dying, so their exits
        // can't be mistaken for "the agent finished" and close the tabs we are
        // meant to reopen next launch.
        openSessions.prepareForQuit()
        SessionRuntimeController().drainAll(openSessions.allSurfaces) { [self] in
            // Final barrier for writes queued while the processes drained.
            overlay.flushPendingTitles()
            overlay.flushPendingTouches()
            engineSet.stop()
            // Nothing from the stopped engines is written after this.
            overlay.applyFacts([:])
            completion()
        }
    }

    // MARK: Theme (U10)

    /// Resolve the effective light/dark scheme (System → the live macOS value).
    public func resolvedScheme() -> TerminalAppearance.ColorScheme {
        switch effectiveTheme {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let name = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return name == .darkAqua ? .dark : .light
        }
    }

    public func currentAppearance() -> TerminalAppearance {
        settings.appearance(scheme: resolvedScheme())
    }

    /// The theme in force: the user's setting, unless a dev-only snapshot run
    /// forces one. `TEMPLE_SNAPSHOT_APPEARANCE=dark|light` is read once and
    /// never persisted — the setting would write the real UserDefaults domain
    /// (AGENTS.md). Every appearance path resolves through here, so the
    /// override cannot be undone by the next `applyAppearance()` or by
    /// RootView's `preferredColorScheme`, both of which read the setting.
    public var effectiveTheme: ThemePreference { Self.forcedTheme ?? settings.theme }

    private static let forcedTheme: ThemePreference? = {
        let env = ProcessInfo.processInfo.environment
        guard env["TEMPLE_SNAPSHOT_DIR"] != nil else { return nil }
        switch env["TEMPLE_SNAPSHOT_APPEARANCE"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }()

    /// Push the theme to AppKit chrome + every open terminal surface.
    public func applyAppearance() {
        NSApplication.shared.appearance = effectiveTheme.nsAppearance
        let appearance = currentAppearance()
        for surface in openSessions.allSurfaces {
            surface.apply(appearance)
        }
    }

    public func transcriptURL(for id: String) -> URL? {
        presentedByID[id]?.transcript?.localURL
    }

    public func resumeArgv(for tab: SessionTab) -> [String] {
        guard let id = tab.sessionID else { return [] }
        if let row = presentedByID[id] { return SessionLauncher.resumeArgv(row) }
        return tab.agent.resumeArgv(sessionID: id)
    }

    // MARK: Opening by id (palette / notifications)

    public func openSession(id: String) {
        if let row = presentedByID[id] {
            openSessions.openSession(row)
            return
        }
        let host = overlay.rows[id]?.host ?? openSessions.sessionTab(withSessionID: id)?.host ?? .local
        let engine = engineSet.engine(for: host)
        if let tab = openSessions.sessionTab(withSessionID: id) {
            if let engine { Task { await engine.requestResolution(id) } }
            openSessions.activate(tab)
            return
        }
        if overlay.isTempleSession(id), let engine { Task { await engine.requestResolution(id) } }
    }

    /// Catalog actions prefer durable row facts when the session is a member.
    public func resumeArgv(for session: TranscriptSummary) -> [String] {
        if let row = presentedByID[session.id] {
            return SessionLauncher.resumeArgv(row)
        }
        return session.agent.resumeArgv(sessionID: session.id)
    }

    /// The project the launcher should default to (last active, else first indexed).
    public var launcherDefaultProjectKey: ProjectKey? {
        openSessions.activeProjectKey
            ?? visibleRowProjects.first?.key
    }

    // MARK: Sidebar data (U1)

    public func displayTitle(_ session: Session) -> String { session.displayTitle }
    public func resumeArgv(for session: Session) -> [String] { SessionLauncher.resumeArgv(session) }

    public func displayTitle(_ session: TranscriptSummary) -> String {
        overlay.displayTitle(for: session)
    }

    /// A tab's display title everywhere chrome shows one (chips, ⌃⇥ switcher):
    /// the user's custom name wins; provisional tabs say they are starting.
    public func tabDisplayTitle(_ tab: SessionTab) -> String {
        if let utility = tab.kind.utilityTitle { return utility }
        let title = sessionTabTitle(tab)
        return tab.isProvisional ? "\(title) (starting…)" : title
    }

    public func projectName(_ key: ProjectKey) -> String { key.displayName }

    public func projectName(_ path: String) -> String {
        path.isEmpty ? "—" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// Projects for the sidebar (in-memory search over the cached non-noise
    /// set), sessions in the launch-frozen order — not live recency.
    public var displayProjects: [SessionRowProject] {
        sidebarProjects(matching: searchText.trimmingCharacters(in: .whitespaces))
    }

    private func sidebarProjects(matching q: String) -> [SessionRowProject] {
        let projects = sidebarRanksFrozen ? rowProjects : visibleRowProjects
        return orderedRowProjects(projects.compactMap { project in
            guard !overlay.isProjectArchived(project.key) else { return nil }
            let ordered = sidebarRanksFrozen
                ? (frozenSessionOrder[project.key] ?? []).compactMap { presentedByID[$0] }.filter { $0.project == project.key }
                : project.sessions
            let rows = ordered.filter { !$0.state.archived && (q.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(q)) }
            return rows.isEmpty ? nil : SessionRowProject(key: project.key, sessions: rows)
        })
    }

    /// The sidebar's project order ignoring the search field — what the Move
    /// items in a project's context menu act on. Reordering while a search
    /// hides half the rail must not persist an order derived from that
    /// half-list.
    public var orderedVisibleProjectKeys: [ProjectKey] { sidebarProjects(matching: "").map(\.key) }

    /// The project header being dragged, from grab to drop. Drop targets read
    /// it to refuse a project dropped onto itself; the header in hand dims.
    @Published public private(set) var draggedProjectKey: ProjectKey?
    private var projectDragWatch: Timer?

    /// A header drag begins. SwiftUI's drop delegates report enters, moves and
    /// drops — but nothing for a drag that ENDS elsewhere: released over the
    /// terminal, or cancelled with Escape. Left alone, the insertion line and
    /// the "a drag is in flight" flag outlive the drag. So the drag is watched
    /// from the source side: the button coming up, wherever that happens, ends
    /// it. Common modes, because AppKit runs a drag in the event-tracking mode.
    public func beginProjectDrag(_ key: ProjectKey) {
        endProjectDrag()
        draggedProjectKey = key
        let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                self.endProjectDrag()
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        projectDragWatch = watch
    }

    /// Drop landed, drag cancelled, or button released off any target: all
    /// three come here, so no state can survive the gesture.
    public func endProjectDrag() {
        projectDragWatch?.invalidate()
        projectDragWatch = nil
        draggedProjectKey = nil
        projectDropOwner = nil
        if projectDropSlot != nil { projectDropSlot = nil }
    }

    /// Where the dragged project would land if released now — ONE slot for the
    /// whole rail, not a flag per project. Per-row state left lines behind: a
    /// row that never got its exit callback (rows re-created under the pointer
    /// as the drop reorders them) kept drawing its line after the drop.
    public struct ProjectDropSlot: Equatable {
        public let key: ProjectKey
        public var path: String { key.path }
        public let edge: Edge
        public init(key: ProjectKey, edge: Edge) { self.key = key; self.edge = edge }
    }
    @Published public var projectDropSlot: ProjectDropSlot?
    /// Which drop target row last wrote the slot. Every row of a project shares
    /// the project's path, and a row's exit callback can arrive AFTER the next
    /// row's enter — so exits clear the slot only if they still own it.
    public var projectDropOwner: String?

    /// Drop on a project's header: the dragged project lands just above it.
    public func moveProject(_ key: ProjectKey, before target: ProjectKey) { place(key) { $0.firstIndex(of: target) } }
    public func moveProject(_ key: ProjectKey, after target: ProjectKey) { place(key) { $0.firstIndex(of: target).map { $0 + 1 } } }
    private func place(_ key: ProjectKey, slot: ([ProjectKey]) -> Int?) {
        var keys = orderedVisibleProjectKeys
        guard let from = keys.firstIndex(of: key) else { return }
        keys.remove(at: from)
        guard let to = slot(keys), to != from else { return }
        keys.insert(key, at: to)
        overlay.setProjectKeyOrder(Self.merge(visibleOrder: keys, into: overlay.projectKeyOrder))
    }

    /// Persist the WHOLE visible list — a move is a statement about where this
    /// project sits relative to all the others, and leaving half of them
    /// unplaced would let the frozen order pull them back past it — but never
    /// at the expense of projects the user can't see right now. An archived
    /// project keeps the slot it was placed in: the visible paths
    /// are rewritten in their new order through the slots they already hold,
    /// hidden paths stay where they are, and visible paths placed for the first
    /// time go on the end. Otherwise archiving a project and moving any other
    /// would silently un-place it, and it would come back "new", on top.
    static func merge<Key: Hashable>(visibleOrder: [Key], into stored: [Key]) -> [Key] {
        let visible = Set(visibleOrder)
        var next = visibleOrder.makeIterator()
        var merged = stored.map { visible.contains($0) ? next.next()! : $0 }
        while let remaining = next.next() { merged.append(remaining) }
        return merged
    }

    /// Projects rendered in the collapsed sidebar. Search bypasses the cap, and
    /// an active project outside it is appended so an opened session stays visible.
    public var cappedDisplayProjects: [SessionRowProject] { capped(displayProjects) }

    /// Cap applied to an already-computed `displayProjects` — the sidebar body
    /// computes that list ONCE and derives everything from it, because each
    /// `displayProjects` access refilters and resorts every session and view
    /// bodies re-evaluate on every publish.
    public func capped(_ all: [SessionRowProject]) -> [SessionRowProject] {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return all
        }
        var projects = Array(all.prefix(Self.projectCap))
        if let activeKey = openSessions.activeProjectKey,
           !projects.contains(where: { $0.key == activeKey }),
           let activeProject = all.first(where: { $0.key == activeKey }) {
            projects.append(activeProject)
        }
        return projects
    }

    /// Number of projects hidden by the default cap; search always reports zero.
    public var hiddenProjectsCount: Int { hiddenCount(displayProjects) }

    public func hiddenCount(_ all: [SessionRowProject]) -> Int {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return max(0, all.count - Self.projectCap)
    }

    /// Pinned section: user-pinned sessions, search filtered (pins are in-memory).
    public var pinnedSessions: [Session] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return visibleRows.filter { $0.project != nil && $0.state.pinned && (q.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(q)) }
    }

    public var highlightableSessions: [Session] {
        pinnedSessions + displayProjects.flatMap(\.sessions)
    }

    public func moveHighlight(by delta: Int) {
        let list = highlightableSessions
        guard !list.isEmpty else { return }
        if let current = highlightedID, let idx = list.firstIndex(where: { $0.id == current }) {
            let next = max(0, min(list.count - 1, idx + delta))
            highlightedID = list[next].id
        } else {
            highlightedID = delta >= 0 ? list.first?.id : list.last?.id
        }
    }

    /// Enter / double-click: open the highlighted session (UX "Select vs. open").
    public func openHighlighted() {
        guard let id = highlightedID,
              let session = highlightableSessions.first(where: { $0.id == id }) else { return }
        openSessions.openSession(session)
    }

    // MARK: Command palette (U8)

    /// Empty query = a switcher over the OPEN sessions only, most recent
    /// activity first (live recency, unlike the launch-frozen sidebar).
    /// Browsing everything on disk is the History tab's job (⌘Y). Typing
    /// searches every Temple session.
    public func paletteResults(_ query: String) -> [Session] {
        let rows = visibleRows
        let open = Set(openSessions.openSessionIDsInTabOrder)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rows.filter { open.contains($0.id) }.sorted(by: Self.moreRecentRow)
        }
        let ranked = SessionRowSearch.rank(rows, query: query)
        return ranked.filter { open.contains($0.id) } + ranked.filter { !open.contains($0.id) }
    }

    /// A palette row can open when its tab is already there or its row knows
    /// the agent and folder to resume in.
    public func canOpenFromPalette(_ session: Session) -> Bool {
        openSessions.openTab(forSessionID: session.id) != nil || session.canResume
    }

    /// Return on a palette row. A row with no folder cannot be resumed — it
    /// used to close the palette and do nothing — so it goes to History,
    /// narrowed to that one session, where it can be seen and archived.
    public func openPaletteResult(_ session: Session) {
        commandPalettePresented = false
        if let tab = openSessions.openTab(forSessionID: session.id) {
            openSessions.activate(tab)
        } else if session.canResume {
            openSessions.openSession(session)
        } else {
            history.query = session.id
            openSessions.openHistory()
        }
    }

    /// The index can surface the same session id under more than one project
    /// (the pre-recency palette silently uniqued through a Dictionary). Lists
    /// keyed by id — ForEach identity, selection maps — must never see a
    /// duplicate, so they dedupe up front, first occurrence wins.
    // MARK: Archive browser (⌘⇧Y)

    /// Whether the user has ever arranged the sidebar by hand.
    public var hasManualProjectOrder: Bool { !overlay.projectKeyOrder.isEmpty }

    /// Archive from the sidebar is one click with no confirmation, so it must be
    /// one keystroke to take back: ⌘Z through the window's undo manager (Edit ▸
    /// Undo Archive Session), with redo registered as the undo runs. The pin the
    /// archive dropped comes back with the session.
    public func archiveSession(_ id: String, undoManager: UndoManager?) {
        let wasPinned = overlay.isPinned(id)
        overlay.setArchived(true, sessionID: id)
        registerUndo(undoManager, name: "Archive Session") { [overlay] in
            overlay.setArchived(false, sessionID: id)
            if wasPinned, !overlay.isPinned(id) { overlay.togglePin(id) }
        } redo: { [overlay] in
            overlay.setArchived(true, sessionID: id)
        }
    }

    public func archiveProject(_ key: ProjectKey, undoManager: UndoManager?) {
        overlay.setProjectArchived(true, key: key)
        registerUndo(undoManager, name: "Archive Project") { [overlay] in
            overlay.setProjectArchived(false, key: key)
        } redo: { [overlay] in
            overlay.setProjectArchived(true, key: key)
        }
    }

    /// Restore is one click too, from a panel whose first row is lit on open —
    /// so it undoes the same way archive does.
    public func restoreSession(_ id: String, undoManager: UndoManager?) {
        overlay.setArchived(false, sessionID: id)
        registerUndo(undoManager, name: "Restore Session") { [overlay] in
            overlay.setArchived(true, sessionID: id)
        } redo: { [overlay] in
            overlay.setArchived(false, sessionID: id)
        }
    }

    public func restoreProject(_ key: ProjectKey, undoManager: UndoManager?) {
        overlay.setProjectArchived(false, key: key)
        registerUndo(undoManager, name: "Restore Project") { [overlay] in
            overlay.setProjectArchived(true, key: key)
        } redo: { [overlay] in
            overlay.setProjectArchived(false, key: key)
        }
    }

    /// Undo and redo as a pair that re-register each other, so ⌘Z / ⌘⇧Z can
    /// bounce as many times as the user likes.
    private func registerUndo(_ undoManager: UndoManager?, name: String,
                              undo: @escaping @MainActor () -> Void,
                              redo: @escaping @MainActor () -> Void) {
        guard let undoManager else { return }
        // Weak: the manager retains this handler, so a strong capture of the
        // manager here would keep it — and the overlay — alive for good.
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                undo()
                guard let undoManager else { return }
                model.registerUndo(undoManager, name: name, undo: redo, redo: undo)
            }
        }
        undoManager.setActionName(name)
    }

    /// Archived projects, newest activity first. Nothing archive-related lives
    /// in the sidebar, so this panel is the only way back.
    public var archivedProjects: [SessionRowProject] {
        rowProjects.filter { overlay.isProjectArchived($0.key) }
            .map { SessionRowProject(key: $0.key, sessions: $0.sessions.sorted(by: Self.moreRecentRow)) }
            .sorted(by: SessionRowProject.moreRecent)
    }

    public func archivedProjectResults(_ query: String) -> [SessionRowProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return archivedProjects.filter { q.isEmpty || $0.path.localizedCaseInsensitiveContains(q) || !SessionRowSearch.rank($0.sessions, query: q).isEmpty }
    }

    public func archivedSessionResults(_ query: String) -> [Session] {
        let rows = sessions.filter { $0.state.archived && !($0.project.map { overlay.isProjectArchived($0) } ?? false) }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rows.sorted(by: Self.moreRecentRow) : SessionRowSearch.rank(rows, query: query)
    }

    public struct ArchiveGroup: Identifiable, Equatable {
        public let project: SessionRowProject
        public let wholeProject: Bool
        /// An archive header for directoryless rows, never a session directory.
        public let directoryless: Bool
        public var id: ProjectKey { project.key }
        public var name: String { directoryless ? "No project" : project.name }
    }

    public func archiveGroups(_ query: String) -> [ArchiveGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matching(_ project: SessionRowProject) -> [Session] {
            if q.isEmpty || project.path.localizedCaseInsensitiveContains(q) { return project.sessions }
            return SessionRowSearch.rank(project.sessions, query: q)
        }
        let whole = archivedProjects.compactMap { project -> ArchiveGroup? in
            let rows = matching(project)
            return rows.isEmpty ? nil : ArchiveGroup(project: SessionRowProject(key: project.key, sessions: rows), wholeProject: true, directoryless: false)
        }
        // Directoryless members remain archivable and restorable. The empty
        // path is a header identity only; the underlying Session stays nil.
        let partialRows = archivedSessionResults("")
        let grouped = Dictionary(grouping: partialRows) { $0.project ?? ProjectKey(host: $0.host, path: "") }
        let partialProjects: [SessionRowProject] = grouped.map { SessionRowProject(key: $0.key, sessions: $0.value) }
        let ordered = partialProjects.sorted { $0.lastActivity == $1.lastActivity ? $0.key.path < $1.key.path : $0.lastActivity > $1.lastActivity }
        let partial: [ArchiveGroup] = ordered.compactMap { project -> ArchiveGroup? in
                let rows = matching(project)
                return rows.isEmpty ? nil : ArchiveGroup(project: SessionRowProject(key: project.key, sessions: rows), wholeProject: false, directoryless: rows.allSatisfy { $0.project == nil })
            }
        return whole + partial
    }

    public func toggleArchive() {
        let presenting = !archivePresented
        archivePresented = presenting
        guard presenting else { return }
        commandPalettePresented = false
        newSessionPickerPresented = false
        shortcutsPresented = false
        cancelProjectSwitcher()
        cancelTabSwitcher()
    }

    /// ⌘Y and View ▸ Session History: open or focus the History tab; pressed
    /// while it is the active tab, back to the tab before it (History stays
    /// open). A floating panel is put away first, as every presenter does —
    /// and when one was up over History, putting it away is all ⌘Y does:
    /// the user is already where ⌘Y goes, and leaving too would be a second
    /// act they did not ask for.
    public func toggleHistory() {
        let panelWasUp = panelPresented || projectSwitcherPresented || tabSwitcherPresented
        commandPalettePresented = false
        newSessionPickerPresented = false
        shortcutsPresented = false
        archivePresented = false
        cancelProjectSwitcher()
        cancelTabSwitcher()
        if panelWasUp, historyActive { return }
        openSessions.openOrLeaveHistory()
    }

    public func toggleCommandPalette() {
        let presenting = !commandPalettePresented
        commandPalettePresented = presenting
        guard presenting else { return }
        newSessionPickerPresented = false
        shortcutsPresented = false
        archivePresented = false
        cancelProjectSwitcher()
        cancelTabSwitcher()
    }

    /// Which agent the ⌘N picker will launch — set at present time, so the
    /// panel can label itself and the open action needs no extra state.
    public private(set) var newSessionPickerAgent: Agent = .claude

    /// ⌘/ — the shortcuts card, exclusive with the other panels like all of
    /// them. Every presenter (key monitor, menu bar, launcher row) must come
    /// through here, or a click can stack two panels.
    public func toggleShortcuts() {
        let presenting = !shortcutsPresented
        shortcutsPresented = presenting
        guard presenting else { return }
        commandPalettePresented = false
        newSessionPickerPresented = false
        archivePresented = false
        cancelProjectSwitcher()
        cancelTabSwitcher()
    }

    /// ⌘N — pick a project, start a new session in it with the default agent.
    /// ⌘⇧N (`alternateAgent`) — same picker, the OTHER agent: shift scales the
    /// verb from "my usual" to "the other one" without a settings trip.
    public func toggleNewSessionPicker(alternateAgent: Bool = false) {
        let agent = alternateAgent
            ? (Agent.allCases.first { $0 != settings.defaultAgent } ?? settings.defaultAgent)
            : settings.defaultAgent
        // Re-invoking while up: same agent dismisses (a toggle); the other
        // shortcut retargets the open panel instead of blinking it.
        if newSessionPickerPresented, newSessionPickerAgent == agent {
            newSessionPickerPresented = false
            return
        }
        newSessionPickerAgent = agent
        newSessionPickerPresented = true
        commandPalettePresented = false
        shortcutsPresented = false
        archivePresented = false
        cancelProjectSwitcher()
        cancelTabSwitcher()
    }

    /// Projects for the ⌘N picker: every non-noise project in scope, most recent
    /// activity first (live recency, like the palettes); typing filters on
    /// the folder name or any path component.
    public func projectPickerResults(_ query: String) -> [SessionRowProject] {
        let projects = visibleRowProjects
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.path.localizedCaseInsensitiveContains(q) }
    }

    // MARK: ⌘P project switcher

    /// What the switcher walks: the projects you have work open in, most recently
    /// used first — the same set the app switcher shows for running apps.
    public var switchableProjectKeys: [ProjectKey] { openSessions.projectKeysByRecency }

    /// ⌘P pressed. First press opens the switcher already on the PREVIOUS project,
    /// so a tap-and-release bounces between two projects the way ⌘⇥ does; further
    /// presses walk the list while ⌘ stays down.
    public func advanceProjectSwitcher(by delta: Int, heldCommand: Bool = true) {
        let projects = switchableProjectKeys
        guard projects.count > 1 else { return }

        if projectSwitcherPresented {
            let current = projectSwitcherKeySelection.flatMap { projects.firstIndex(of: $0) } ?? 0
            projectSwitcherKeySelection = projects[(current + delta + projects.count) % projects.count]
        } else {
            // Panels are mutually exclusive (same rule as ⌘K/⌘N/⌘/): the
            // HUD must not stack over an open palette.
            commandPalettePresented = false
            archivePresented = false
            newSessionPickerPresented = false
            shortcutsPresented = false
            cancelTabSwitcher()
            deferredLanding = nil
            projectSwitcherPresented = true
            switcherArmedByCommand = heldCommand
            projectSwitcherKeySelection = projects[delta > 0 ? 1 : projects.count - 1]
        }
    }

    /// ⌘ came back up. Only lands the switcher if ⌘ is what opened it.
    public func commandReleasedForSwitcher() {
        guard projectSwitcherPresented, switcherArmedByCommand else { return }
        commitProjectSwitcher()
    }

    /// Go where the highlight is (⌘ released, Return, or a click on a tile).
    public func commitProjectSwitcher() {
        guard projectSwitcherPresented else { return }
        let selection = projectSwitcherKeySelection
        cancelProjectSwitcher()
        // The project may have closed its last tab while the switcher was up.
        guard let selection, openSessions.openProjectKeys.contains(selection) else { return }
        land(releasing: .command) { [openSessions] in
            guard openSessions.openProjectKeys.contains(selection) else { return }
            openSessions.activateProject(selection)
        }
    }

    // MARK: Landing a switcher (balanced modifier delivery)

    /// A landing parked because the arming modifier was still physically held
    /// at commit time (Return, or a click on a row). Moving focus right then
    /// would send the modifier's eventual release to the DESTINATION surface,
    /// leaving the source terminal holding a press it never sees released —
    /// so the activation waits for the physical release instead.
    private var deferredLanding: (flag: NSEvent.ModifierFlags, land: () -> Void)?

    /// Seam: physical modifier state (tests inject; real code asks AppKit).
    var heldModifiers: () -> NSEvent.ModifierFlags = {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    private func land(releasing flag: NSEvent.ModifierFlags, _ activate: @escaping () -> Void) {
        if heldModifiers().contains(flag) {
            deferredLanding = (flag, activate)
        } else {
            activate()
        }
    }

    /// Every flagsChanged passes through here (after the release event has
    /// been dispatched): performs a parked landing once its modifier is up.
    public func flagsChangedForDeferredLanding(_ flags: NSEvent.ModifierFlags) {
        guard let deferred = deferredLanding, !flags.contains(deferred.flag) else { return }
        deferredLanding = nil
        deferred.land()
    }

    /// The app deactivated mid-hold: the release will never reach our monitor,
    /// but the user did choose a destination — land it now rather than lose it.
    public func performDeferredLandingNow() {
        guard let deferred = deferredLanding else { return }
        deferredLanding = nil
        deferred.land()
    }

    public func cancelProjectSwitcher() {
        projectSwitcherPresented = false
        projectSwitcherKeySelection = nil
        switcherArmedByCommand = false
    }

    // MARK: ⌃⇥ tab switcher

    /// What the switcher walks: every open tab, most recently visited first.
    public var switchableTabs: [SessionTab] {
        openSessions.tabsByRecency
    }

    /// ⌃⇥ pressed. First press opens the switcher already on the PREVIOUS tab,
    /// so a tap-and-release bounces between two tabs the way ⌘⇥ does; further
    /// presses walk the list while ⌃ stays down.
    public func advanceTabSwitcher(by delta: Int, heldControl: Bool = true) {
        let list = switchableTabs
        // On the home page no tab is active, so list[0] is not "where we
        // are" — it IS the last-visited tab, the bounce target. Anchoring on
        // a live active tab keeps both cases honest: from a tab, slot 0 is
        // the current tab and the walk starts at slot 1; from home, slot 0
        // is the destination — and a single open tab is then enough to go.
        let anchor = openSessions.activeTabID == nil ? 0 : 1
        guard list.count > anchor else { return }

        if tabSwitcherPresented {
            let current = tabSwitcherSelection.flatMap { sel in list.firstIndex { $0.id == sel } } ?? 0
            tabSwitcherSelection = list[(current + delta + list.count) % list.count].id
        } else {
            // Panels are mutually exclusive (same rule as ⌘K/⌘N/⌘/).
            commandPalettePresented = false
            archivePresented = false
            newSessionPickerPresented = false
            shortcutsPresented = false
            cancelProjectSwitcher()
            // A fresh walk supersedes a landing still parked on a held
            // modifier — committing both would activate two tabs in a row.
            deferredLanding = nil
            tabSwitcherPresented = true
            tabSwitcherArmedByControl = heldControl
            // A fresh press opens on the previously visited tab regardless of
            // direction: a quick tap of ⌃⇥ OR ⌃⇧⇥ must bounce between the two
            // most recent tabs (⌃⇧⇥ starting at the list's tail sent a tap to
            // the OLDEST tab, reshuffling recency on every landing). Direction
            // only matters for later presses while ⌃ holds the switcher open —
            // where stepping back onto the current tab and releasing is a
            // deliberate no-op, the ⌘⇥ way of bailing out of a walk.
            tabSwitcherSelection = list[anchor].id
        }
    }

    /// ⌃ came back up. Only lands the switcher if ⌃ is what opened it.
    public func controlReleasedForTabSwitcher() {
        guard tabSwitcherPresented, tabSwitcherArmedByControl else { return }
        commitTabSwitcher()
    }

    /// Go where the highlight is (⌃ released, Return, or a click on a row).
    public func commitTabSwitcher() {
        guard tabSwitcherPresented else { return }
        let selection = tabSwitcherSelection
        cancelTabSwitcher()
        // The tab may have closed while the switcher was up.
        guard let selection,
              openSessions.tabs.contains(where: { $0.id == selection }) else { return }
        land(releasing: .control) { [openSessions] in
            // ...and it can close again between parking and landing.
            guard let tab = openSessions.tabs.first(where: { $0.id == selection }) else { return }
            openSessions.activate(tab)
        }
    }

    public func cancelTabSwitcher() {
        tabSwitcherPresented = false
        tabSwitcherSelection = nil
        tabSwitcherArmedByControl = false
    }

}
