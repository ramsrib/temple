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
    @Published public var index = SessionIndex(projects: []) {
        didSet {
            recomputeNoise()
            extendFrozenProjectOrder()
        }
    }

    /// Sidebar project order is frozen at launch: recency decides it once (at
    /// the first index publish), then it stays put for the rest of the run so
    /// projects don't shuffle underfoot as sessions update. Genuinely new
    /// projects surface at the top; existing ones never move relative to each
    /// other. Recomputed fresh next launch.
    private var frozenProjectRank: [String: Int] = [:]

    private func extendFrozenProjectOrder() {
        let newPaths = index.projects.map(\.path).filter { frozenProjectRank[$0] == nil }
        guard !newPaths.isEmpty else { return }
        for key in frozenProjectRank.keys { frozenProjectRank[key]! += newPaths.count }
        for (offset, path) in newPaths.enumerated() { frozenProjectRank[path] = offset }
    }
    // (recomputeNoise refreshes the cached non-noise set below.)
    @Published public var isLoading = true

    // Sidebar UI state (U1)
    @Published public var searchText = ""
    @Published public var highlightedID: AgentSession.ID?
    @Published public var showNoise = false { didSet { recomputeNoise() } }

    // The disk-I/O noise stage is cached (recomputed only when the index or the
    // toggle changes) so it never runs during view body. Search + pins are
    // applied cheaply in-memory on top (below).
    private var noiseFilteredProjects: [Project] = []
    @Published public var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published public var commandPalettePresented = false
    /// ⌘N / "+ New session": show the launcher even when a tab is active.
    @Published public var launcherPresented = false
    /// Pulsed to move keyboard focus into the sidebar search field (⌘F).
    @Published public var focusSearchToken = 0

    // Sub-models
    public let settings: SettingsStore
    public let overlay: SessionOverlayStore
    public let openSessions: OpenSessionsModel
    public let notifications: NotificationController

    // Seams (Track C)
    private let indexSource: IndexSource
    private let search: SessionSearch
    private let noiseFilter: NoiseFilter
    private let cacheURL: URL

    private var cancellables: Set<AnyCancellable> = []
    private var themeObserver: NSObjectProtocol?
    private var lastIndexSignature = ""
    /// A cached snapshot is replaced unconditionally by the first live index.
    private(set) var isIndexStale = false

    /// Cheap change-detection so duplicate watcher events do not re-filter an
    /// unchanged index.
    private static func signature(of index: SessionIndex) -> String {
        var count = 0
        var latest: TimeInterval = 0
        for project in index.projects {
            count += project.sessions.count
            if let m = project.sessions.map(\.updatedAt).max()?.timeIntervalSince1970, m > latest { latest = m }
        }
        return "\(index.projects.count)-\(count)-\(latest)"
    }

    public init(surfaceFactory: TerminalSurfaceFactory = StubTerminalSurfaceFactory(),
                indexSource: IndexSource? = nil,
                search: SessionSearch = CoreSessionSearch(),
                noiseFilter: NoiseFilter = CoreNoiseFilter(),
                registry: ProcessRegistry? = nil,
                reconciler: CodexAdopting? = nil,
                persistence: TabPersistence? = nil,
                database: TempleDB? = nil,
                settings: SettingsStore? = nil,
                overlay: SessionOverlayStore? = nil,
                cacheURL: URL = CachedIndexStore.defaultURL) {
        // Defaults that touch @MainActor types are built here (not as default
        // arguments, which evaluate in a nonisolated context).
        let database = database ?? Self.openDefaultDatabase()
        let settings = settings ?? SettingsStore()
        let overlay = overlay ?? SessionOverlayStore(db: database)
        let registry = registry ?? DBProcessRegistry(db: database)
        let persistence = persistence ?? DBTabPersistence(db: database)
        let resolvedIndexSource = indexSource ?? WatcherIndexSource(cacheURL: cacheURL)
        let reconciler = reconciler ?? (resolvedIndexSource as? WatcherIndexSource).map {
            WatcherCodexReconciler(indexSource: $0)
        } ?? NoopCodexReconciler()
        self.settings = settings
        self.overlay = overlay
        self.search = search
        self.noiseFilter = noiseFilter
        self.indexSource = resolvedIndexSource
        self.cacheURL = cacheURL
        self.notifications = NotificationController()

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
            binaryPath: { settingsRef.binaryPath(for: $0) },
            defaultAgent: { settingsRef.defaultAgent })

        // Now self is fully initialized — finish wiring the closures & observers.
        resolveAppearance = { [weak self] in
            self?.currentAppearance() ?? .default
        }
        wire()
    }

    private static func openDefaultDatabase() -> TempleDB {
        if let db = try? TempleDB(path: TempleDB.defaultPath()) { return db }
        return try! TempleDB.inMemory()
    }

    private func wire() {
        // U7: route attention → native notification.
        openSessions.attentionHandler = { [weak self] tab, title, body in
            guard let self else { return }
            let message = body.isEmpty ? title : body
            self.notifications.post(projectName: self.projectName(tab.projectPath),
                                    sessionTitle: overlayTitle(tab: tab),
                                    sessionID: tab.sessionID,
                                    body: message)
        }
        // U7: notification click → focus that session's tab.
        notifications.onActivateSession = { [weak self] sessionID in
            self?.openSession(id: sessionID)
        }
        // Sidebar highlight follows the active tab (UX "Select vs. open").
        openSessions.$activeTabID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if let sid = self.openSessions.activeTab?.sessionID {
                    self.highlightedID = sid
                }
            }
            .store(in: &cancellables)
        // Live appearance: any settings change re-tints app + open surfaces (U9/U10).
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyAppearance()
                self?.objectWillChange.send()
            }
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
    }

    private func overlayTitle(tab: SessionTab) -> String {
        if let sid = tab.sessionID, let name = overlay.customName(for: sid) { return name }
        return tab.title
    }

    // MARK: Lifecycle

    public func start() {
        applyAppearance()
        openSessions.restore()
        if let cachedIndex = CachedIndexStore.load(from: cacheURL) {
            index = cachedIndex
            isLoading = false
            isIndexStale = true
            Self.log("cached index published")
        }
        var isFirstLiveIndex = true
        indexSource.start { [weak self] index in
            guard let self else { return }
            self.isLoading = false
            self.isIndexStale = false
            if isFirstLiveIndex {
                Self.log("live index published")
                isFirstLiveIndex = false
            }
            // Skip the recompute (disk-stat) storm when nothing actually changed.
            let signature = Self.signature(of: index)
            guard signature != self.lastIndexSignature else { return }
            self.lastIndexSignature = signature
            self.index = index
        }
        // U10: follow macOS appearance live when theme == .system.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyAppearance() }
            }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("Temple: \(message)\n".utf8))
    }

    /// App-quit drain (ADR-010) → returns true once all surfaces are down.
    public func drainForQuit(completion: @escaping () -> Void) {
        SessionRuntimeController().drainAll(openSessions.allSurfaces, completion: completion)
    }

    // MARK: Theme (U10)

    /// Resolve the effective light/dark scheme (System → the live macOS value).
    public func resolvedScheme() -> TerminalAppearance.ColorScheme {
        switch settings.theme {
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

    /// Push theme to AppKit chrome + every open terminal surface.
    public func applyAppearance() {
        NSApplication.shared.appearance = settings.theme.nsAppearance
        let appearance = currentAppearance()
        for surface in openSessions.allSurfaces {
            surface.apply(appearance)
        }
    }

    // MARK: Opening by id (palette / notifications)

    public func openSession(id: String) {
        guard let session = index.allSessions.first(where: { $0.id == id }) else { return }
        openSessions.openSession(session)
    }

    public func presentLauncher() { launcherPresented = true }

    /// The project the launcher should default to (last active, else first indexed).
    public var launcherDefaultProject: String? {
        openSessions.activeProjectPath ?? index.projects.first?.path
    }

    // MARK: Sidebar data (U1)

    public func displayTitle(_ session: AgentSession) -> String {
        overlay.displayTitle(for: session)
    }

    public func projectName(_ path: String) -> String {
        path.isEmpty ? "—" : URL(fileURLWithPath: path).lastPathComponent
    }

    private func matches(_ session: AgentSession) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        // Search custom name too (title-only per UX, but the custom name IS the title).
        return displayTitle(session).localizedCaseInsensitiveContains(q)
    }

    /// Disk stage: drop noise. Runs only when the index or the toggle changes,
    /// never during view body. Publishes so the computed views below refresh.
    private func recomputeNoise() {
        noiseFilteredProjects = index.projects.compactMap { project in
            let sessions = showNoise ? project.sessions
                                     : project.sessions.filter { !noiseFilter.isNoise($0) }
            return sessions.isEmpty ? nil : Project(path: project.path, sessions: sessions)
        }
        objectWillChange.send()
    }

    /// Projects for the sidebar (in-memory search over the cached non-noise
    /// set), in the launch-frozen order — not live recency.
    public var displayProjects: [Project] {
        noiseFilteredProjects.compactMap { project -> Project? in
            let sessions = project.sessions.filter(matches)
            return sessions.isEmpty ? nil : Project(path: project.path, sessions: sessions)
        }
        .sorted {
            (frozenProjectRank[$0.path] ?? .max) < (frozenProjectRank[$1.path] ?? .max)
        }
    }

    /// Projects rendered in the collapsed sidebar. Search bypasses the cap, and
    /// an active project outside it is appended so an opened session stays visible.
    public var cappedDisplayProjects: [Project] {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return displayProjects
        }
        var projects = Array(displayProjects.prefix(Self.projectCap))
        if let activePath = openSessions.activeProjectPath,
           !projects.contains(where: { $0.path == activePath }),
           let activeProject = displayProjects.first(where: { $0.path == activePath }) {
            projects.append(activeProject)
        }
        return projects
    }

    /// Number of projects hidden by the default cap; search always reports zero.
    public var hiddenProjectsCount: Int {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return max(0, displayProjects.count - Self.projectCap)
    }

    /// Pinned section: user-pinned sessions, search filtered (pins are in-memory).
    public var pinnedSessions: [AgentSession] {
        noiseFilteredProjects
            .flatMap(\.sessions)
            .filter { overlay.isPinned($0.id) && matches($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The flat, ordered list of sessions the sidebar renders (for arrow-key
    /// highlight movement). Pinned first, then per project.
    public var highlightableSessions: [AgentSession] {
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

    public func paletteResults(_ query: String) -> [AgentSession] {
        // Rank over the cached non-noise set (respects the noise toggle).
        search.rank(noiseFilteredProjects.flatMap(\.sessions), query: query)
    }
}
