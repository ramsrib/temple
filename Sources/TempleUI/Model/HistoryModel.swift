import Foundation
import Combine
import TempleCore

/// The History tab's state: every session Temple or the disk knows about,
/// one status per row, and the page's view state over it (search, scope,
/// filters, selection, the import in flight).
///
/// Two lifetimes. **Data** outlives the tab: the projection
/// (`HistoryProjector`) keeps the catalog rows, the members and the
/// prepared rows, and the last snapshot stays installed, so reopening
/// History shows them at once and refreshes underneath. **View state** is
/// the tab's: `reset()` clears search, scope, filters, the chip, selection
/// and notices when it closes. Filters are a question, not a setting, and
/// are never persisted.
///
/// The main actor never sorts, filters, groups or formats rows. Every input
/// (catalog batches, members, archived projects, open tabs, the query) goes
/// to the projection as a value; it answers with one coherent
/// `HistorySnapshot`, which is installed in one assignment, then the
/// selection is reconciled against its index. A snapshot built for a query
/// that has since changed never lands (`generation`).
///
/// The live index holds Temple's sessions only (ADR-027), so the disk is
/// read through the host catalog when the tab is shown and on Refresh, never
/// watched. Members come from SQLite rows, so they (archived ones included)
/// are on the page before any disk read.
@MainActor
public final class HistoryModel: ObservableObject {

    public enum ReadState: Equatable, Sendable {
        /// No read has run since the tab opened (or the last one was cancelled).
        case idle
        /// Files consumed so far; `total` is nil until the stores are listed.
        case reading(read: Int, total: Int?)
        case done
    }

    public struct StoreFailure: Hashable, Sendable {
        public let host: HostID
        public let agent: Agent
        public let message: String
        public init(host: HostID, agent: Agent, message: String) {
            self.host = host; self.agent = agent; self.message = message
        }
    }

    /// What the confirmation sheet says and imports. Built when asked, so the
    /// copy names exactly the rows that will join.
    public struct ImportRequest: Identifiable, Equatable {
        public let id = UUID()
        public let sessions: [TranscriptSummary]
        public let title: String
        public let message: String
        public let confirmLabel: String
    }

    public struct ImportFailure: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    /// The selection bar's transient line after an import, a restore or an
    /// archive, or their undo.
    public struct Notice: Equatable {
        public let text: String
        public let offersUndo: Bool
    }

    public enum EscapeOutcome: Equatable {
        case clearedSearch, clearedChip, clearedSelection, leave
    }

    /// What floats over the bottom of the page: the transient line after an
    /// import or its undo, else the selection bar (two or more selected). It
    /// is page chrome, not part of the list — an import can empty the view it
    /// was made from ("Not in Temple", everything imported), and its Undo has
    /// to survive that.
    public enum BottomBar: Equatable {
        case notice(Notice)
        case selection(count: Int)
    }

    public typealias ProjectCount = TempleUI.ProjectCount

    /// A command on the page's selection, from a key or the selection bar.
    public enum Command: Equatable {
        case moveCursor(by: Int, extend: Bool)
        case moveToEnd(top: Bool, extend: Bool)
        case moveByDay(forward: Bool, extend: Bool)
        case selectAll
        case open
        case archiveSelection
        case restoreSelection
        case importSelection
    }

    /// What the selection bar says and offers, counted once per selection or
    /// snapshot change rather than per render.
    public struct SelectionSummary: Equatable {
        public var count = 0
        /// Outside rows Import would bring in.
        public var importable = 0
        public var archived = 0
        /// Every selected row can be archived (as last projected).
        public var archivable = false
        public var allArchived: Bool { count > 0 && archived == count }
    }

    /// The "Archived just now" chip: a filter over exactly the sidebar
    /// notice's memberships.
    public struct JustArchivedChip: Equatable {
        public let memberships: Set<MembershipRef>
        public var count: Int { memberships.count }
    }

    // MARK: Dependencies

    private let overlay: SessionOverlayStore
    /// The owning host's folder evidence for the noise check: asked once per
    /// project a read, before a batch is classified.
    private let directoryEvidence: @Sendable (ProjectKey) async -> DirectoryEvidence
    private let now: () -> Date
    /// The full-disk read of every host. Replaceable so tests feed events by hand.
    var catalog: () -> AsyncStream<HostCatalogEvent>
    /// Open (or focus) a session in a tab. Opening an outside session joins it
    /// as `opened` on the way (ADR-023).
    var openSession: (TranscriptSummary) -> Void = { _ in }
    var archiveMember: (String, UndoManager?) -> Void = { _, _ in }
    /// Archive several members as one undoable step. `changed` hears each
    /// undo (false) and redo (true), so the page can say what happened.
    var archiveMembers: ([String], UndoManager?, _ changed: @escaping @MainActor (Bool) -> Void) -> Void = { _, _, _ in }
    /// Restore these memberships as one undoable step (ADR-031), reporting
    /// what the write did; `changed` hears each undo and redo.
    var restoreMembers: ([MembershipRef], UndoManager?, _ changed: @escaping @MainActor (AppModel.RestoreChange) -> Void)
        -> AppModel.RestoreReport = { _, _, _ in AppModel.RestoreReport(restored: 0, undoable: false) }
    var restoreProjectAction: (ProjectKey, UndoManager?) -> Void = { _, _ in }
    var showInSidebar: (String) -> Void = { _ in }
    /// Whether a session runs in an open tab on the row's host, asked live
    /// when an action runs: undoing an import or archiving must not pull a
    /// session out from under its tab.
    var hasOpenTab: (HistoryKey) -> Bool = { _ in false }
    /// Temple's own rows, with the engine's verdicts.
    var memberRows: () -> [Session] = { [] }
    var openMember: (Session) -> Void = { _ in }

    // MARK: Data

    let projector: HistoryProjector
    /// The page as last projected. Retained when the tab closes.
    @Published public private(set) var snapshot: HistorySnapshot = .empty
    /// Each open tab's activity, by session and host: the dots. A change
    /// re-renders the rows whose dot changed, nothing else.
    @Published public private(set) var activity: [SessionKey: ActivityState] = [:]

    @Published public private(set) var readState: ReadState = .idle
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var storeFailures: [StoreFailure] = []

    public var allRows: [HistoryRow] { snapshot.allRows }
    /// `allRows` through scope, filters, chip and search, in the same order.
    public var visibleRows: [HistoryRow] { snapshot.visibleRows }
    public var groups: [HistoryRowDayGroup] { snapshot.groups }
    /// In Temple and not archived.
    public var inTempleCount: Int { snapshot.counts.inTemple }
    public var archivedCount: Int { snapshot.counts.archived }
    /// Members nothing on disk backs (`HistoryRow.transcriptMissing`).
    public var transcriptMissingCount: Int { snapshot.counts.transcriptMissing }
    public var agentCounts: [Agent: Int] { snapshot.counts.agents }
    /// Projects for the popup, by row count, most first.
    public var projects: [ProjectCount] { snapshot.projects }

    // MARK: View state

    /// The search field's text, as typed. It reaches `query` — and the list —
    /// `queryDebounce` after the last keystroke; Esc and Return flush it
    /// first, so neither acts on the query from before the typing.
    @Published public var draft = "" { didSet { if draft != oldValue { draftChanged() } } }
    /// The applied search. Setting it (the ⌘K bridge) brings the field along.
    /// Any assignment — an unchanged one too — brings the field along and
    /// ends a pending debounce: a bridge that sets the query must not have
    /// the old typing land on its page a moment later.
    @Published public var query = "" {
        didSet {
            debounceTask?.cancel()
            debounceTask = nil
            if draft != query { draft = query }
            guard query != oldValue else { return }
            filtersChanged()
        }
    }
    @Published public var scope: HistoryScope = .all { didSet { if scope != oldValue { filtersChanged() } } }
    @Published public var agentFilter: Agent? { didSet { if agentFilter != oldValue { filtersChanged() } } }
    @Published public var projectKeyFilter: ProjectKey? { didSet { if projectKeyFilter != oldValue { filtersChanged() } } }
    @Published public var justArchivedChip: JustArchivedChip? { didSet { if justArchivedChip != oldValue { filtersChanged() } } }

    @Published public private(set) var selection: Set<HistoryKey> = [] { didSet { refreshSelectionSummary() } }
    /// The row the keyboard is on: arrows move from it, ⇧ extends to it.
    @Published public private(set) var cursorID: HistoryKey?
    /// Where a ⇧-extension is measured from.
    private var anchorID: HistoryKey?
    /// Bumped when the list should bring the cursor into view.
    @Published public private(set) var scrollRequest = 0
    /// Bumped by ⌘F: the view moves keyboard focus into the search field.
    @Published public private(set) var focusSearchRequest = 0
    /// History's own search field holds keyboard focus. The view keeps it
    /// current; the key router reads it to tell this field from any other
    /// (sidebar search, a chip being renamed), whose keys are not History's.
    /// Not published: nothing on screen draws from it.
    public var searchFieldFocused = false
    @Published public private(set) var selectionSummary = SelectionSummary()

    @Published public var pendingImport: ImportRequest?
    @Published public var importFailure: ImportFailure?
    @Published public private(set) var notice: Notice?
    /// Rows whose status column reads "Imported" for a moment.
    @Published public private(set) var justImported: Set<HistoryKey> = []

    /// Select the first row once there is one — on open, and after a filter
    /// change: arrows and Return work without a click.
    private var wantsInitialSelection = true
    private var readTask: Task<Void, Never>?
    private var readID = 0
    private var readProgress: [HostID: (read: Int, total: Int?)] = [:]
    private var readFailures: [StoreFailure] = []
    private var readAwaitsFirstSnapshot = false
    /// Catalog rows handed to the pump and not yet taken by a projection.
    /// Over `catalogBacklogLimit`, a read's lanes wait (lossless
    /// backpressure, `HistoryCatalogRead`) and the backlog goes at once.
    private var pendingCatalogRows = 0
    private var backlogWaiters: [CheckedContinuation<Void, Never>] = []
    var catalogBacklogLimit = 2_000
    /// Catalog rows waiting for the pump (for tests).
    var catalogBacklog: Int { pendingCatalogRows }
    /// Progress lands at most every `coalesceInterval`, the latest always
    /// last: a re-render of the page per batch is work for a counter.
    private var lastProgressPublish: Date?
    private var progressTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var importedTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var rebuildScheduled = false
    /// Snapshots installed. Diagnostic: an unchanged projection installs none.
    private(set) var rebuildCount = 0
    /// Main-actor time spent installing snapshots, for measurement.
    private(set) var installDurations: [TimeInterval] = []
    /// Overlay reads made by the page's own derived state; the row inputs
    /// and the selection bar make none (a test counts this).
    private(set) var overlayLookups = 0

    /// The tab is on screen. Off screen, a member change only marks the page
    /// dirty: it is projected when the page is next shown.
    private var isActive = false
    private var membersDirty = true
    private var openTabKeys: Set<SessionKey> = []
    private var cancellables: Set<AnyCancellable> = []

    // The projection pump: one at a time, in order, coalesced.
    private var pending = HistoryProjectionInput()
    private var pendingUrgent = false
    private var pumpTask: Task<Void, Never>?
    private var coalesceWait: Task<Void, Never>?
    private var lastInstall: Date?
    /// Bumped by every change to the question the page asks.
    private(set) var generation: UInt64 = 0
    /// Test seam: awaited between a projection's return and its install.
    var beforeInstall: (@MainActor () async -> Void)?
    /// The generations installed, in order (diagnostic).
    private(set) var installedGenerations: [UInt64] = []

    // Commands on the selection: one rule (ADR-031).
    //
    // - Every command (arrows, ⌘A, Return, ⌘⌫, Restore N, the selection's
    //   Import) comes in through `issue`, unconditionally: whoever issues it
    //   checks nothing.
    // - Accepting a command first applies what is typed (a pending debounce),
    //   and only then. If the page answering the current input is installed
    //   and nothing is recorded, it runs now; otherwise it is recorded with
    //   the generation it targets.
    // - Any newer input cancels every recorded command: a keystroke that
    //   changes the search, a scope, filter or chip change, Esc, the tab
    //   leaving, a bridge into History.
    // - When the targeted generation installs, recorded commands run one at a
    //   time; before each, the generation and a cancellation token are
    //   checked, and the first mismatch drops the rest. A command runs against
    //   the installed page and checks there whether it applies; one that does
    //   not does nothing. Running a command never applies typing and never
    //   records a command.
    // - A command that leaves the page or puts something in front of it
    //   (Return that opens a tab, Import that asks with its sheet) is
    //   terminal: once it runs, every command still recorded is cancelled, in
    //   the same call. A command never runs while a sheet or alert is up: it
    //   does nothing and cancels the rest. The app cancels too, at once,
    //   whenever its active tab moves off History.
    private var recordedCommands: [(target: UInt64, command: Command, undoManager: UndoManager?)] = []
    private var commandToken = 0

    var noticeDuration: TimeInterval = 4
    var importedDuration: TimeInterval = 2
    var queryDebounce: TimeInterval = 0.12
    /// Catalog batches after the first land at most this often.
    var coalesceInterval: TimeInterval = 0.1

    /// `catalog` and `directoryEvidence` are the host registry's (AppModel
    /// wires them); `pathExists` is a test's stand-in for this Mac's
    /// directory evidence. With neither, every folder is unknown, never
    /// missing.
    init(overlay: SessionOverlayStore,
         catalog: @escaping () -> AsyncStream<HostCatalogEvent>,
         pathExists: (@Sendable (String) -> Bool)? = nil,
         directoryEvidence: (@Sendable (ProjectKey) async -> DirectoryEvidence)? = nil,
         now: @escaping @Sendable () -> Date = Date.init,
         notificationCenter: NotificationCenter = .default) {
        self.overlay = overlay
        self.catalog = catalog
        self.directoryEvidence = directoryEvidence ?? { key in
            guard key.host.isLocal, let pathExists else { return .unknown }
            return pathExists(key.path) ? .exists : .missing
        }
        self.now = now
        self.projector = HistoryProjector(now: now)
        // Membership, renames, retitles and archive state all show on the
        // page. A burst (a bulk import, live retitles) is one projection.
        overlay.objectWillChange
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        // Activity publishes nothing (`SessionOverlayStore.rows`), but a
        // member standing alone shows its own activity time: the projection
        // decides whether the page changed.
        overlay.rowChanges
            .filter(\.recencyOnly)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        // A new day retitles "Today"; a new zone or locale moves every row's
        // day and time text. Each re-formats the page even when nothing else
        // arrives, with a fresh calendar and fresh formatters.
        Publishers.MergeMany([Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                              NSLocale.currentLocaleDidChangeNotification].map {
                notificationCenter.publisher(for: $0)
            })
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if note.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                self?.enqueue(HistoryProjectionInput(rebuildAll: true), urgent: true)
            }
            .store(in: &cancellables)
    }

    func rowsChanged() { scheduleRebuild() }

    /// The header's counts: what the page lists, not what is on disk. The
    /// three narrow scopes partition the total, and the line says only that;
    /// a condition (no transcript, no folder) is the row's tag and the
    /// sidebar notice's, not the header's.
    public var countsLine: String {
        let counts = snapshot.counts
        return "\(counts.all.formatted()) sessions · \(counts.inTemple.formatted()) in Temple"
            + " · \(counts.archived.formatted()) archived"
    }

    private var currentMembers: [Session] {
        let supplied = memberRows()
        return supplied.isEmpty ? overlay.rows.values.map { Session(state: $0) } : supplied
    }

    // MARK: Lifecycle

    /// The tab came on screen (opened, or switched back to). The retained
    /// snapshot is already on the page; members are caught up from SQLite
    /// (before any disk read), then a fresh read runs underneath.
    public func activate() {
        isActive = true
        if selection.isEmpty { wantsInitialSelection = true }
        sendMembers(urgent: true)
        reconcileSelection()
        refresh()
    }

    /// The tab left the screen: stop reading for nobody.
    public func deactivate() {
        isActive = false
        cancelPendingCommands()
        guard readTask != nil else { return }
        readTask?.cancel()
        readTask = nil
        readID += 1
        releaseBacklog()
        if case .reading = readState { readState = lastUpdated == nil ? .idle : .done }
    }

    /// The tab closed: its view state goes with it. The rows stay — the
    /// projection keeps them, and the page shows them at once next time.
    public func reset() {
        deactivate()
        pendingImport = nil
        importFailure = nil
        dismissNotice()
        justImported = []
        selection = []
        cursorID = nil
        anchorID = nil
        wantsInitialSelection = true
        debounceTask?.cancel()
        debounceTask = nil
        cancelPendingCommands()
        draft = ""
        query = ""; scope = .all; agentFilter = nil; projectKeyFilter = nil; justArchivedChip = nil
    }

    /// ⌘R, and every activation. A read already running is replaced.
    /// Every host is read at once (`HistoryCatalogRead`); progress is the sum
    /// over the hosts heard from, and a host that fails says so for itself
    /// only. Rows already on the page stay while it reads.
    public func refresh() {
        readTask?.cancel()
        readID += 1
        releaseBacklog()
        let id = readID
        progressTask?.cancel()
        progressTask = nil
        lastProgressPublish = nil
        readState = .reading(read: 0, total: nil)
        readProgress = [:]
        readFailures = []
        readAwaitsFirstSnapshot = true
        let stream = catalog()
        let evidence = directoryEvidence
        var memberFolders: [HostID: Set<ProjectKey>] = [:]
        for member in currentMembers { if let project = member.project { memberFolders[project.host, default: []].insert(project) } }
        let folders = memberFolders
        readTask = Task { [weak self] in
            let completion = await HistoryCatalogRead.run(stream, memberFolders: folders, directoryEvidence: evidence) {
                [weak self] event in await self?.receive(event, read: id)
            }
            guard let self, let completion, !Task.isCancelled, id == self.readID else { return }
            // Gone from disk since the last read: dropped now the read is
            // whole. The read is done when the page shows all of it.
            self.enqueue(HistoryProjectionInput(catalog: [.complete(completion)]), urgent: true)
            while let pump = self.pumpTask { await pump.value }
            guard !Task.isCancelled, id == self.readID else { return }
            self.progressTask?.cancel()
            self.progressTask = nil
            self.storeFailures = self.readFailures
            self.lastUpdated = self.now()
            self.readState = .done
            self.readTask = nil
        }
    }

    private func receive(_ event: HistoryCatalogRead.Event, read id: Int) async {
        guard id == readID else { return }
        switch event {
        case .progress(let host, let read, let total):
            readProgress[host] = (read, total)
            let sum = readProgress.values.reduce(0) { $0 + $1.read }
            let whole: Int? = readProgress.values.contains { $0.total == nil } ? nil
                : readProgress.values.reduce(0) { $0 + ($1.total ?? 0) }
            publishProgress(.reading(read: sum, total: whole), read: id)
        case .failed(let failure, _):
            readFailures.append(failure)
            storeFailures = readFailures
        case .delta(let delta):
            // The first batch of a read lands at once; later ones coalesce,
            // unless the backlog is over its bound.
            pendingCatalogRows += delta.rowCount
            enqueue(HistoryProjectionInput(catalog: [delta]),
                    urgent: readAwaitsFirstSnapshot || pendingCatalogRows >= catalogBacklogLimit)
            readAwaitsFirstSnapshot = false
            while pendingCatalogRows >= catalogBacklogLimit, id == readID {
                await withCheckedContinuation { backlogWaiters.append($0) }
            }
        }
    }

    private func publishProgress(_ state: ReadState, read id: Int) {
        let wait = lastProgressPublish.map { coalesceInterval - Date().timeIntervalSince($0) } ?? 0
        guard wait > 0 else {
            progressTask?.cancel()
            progressTask = nil
            lastProgressPublish = Date()
            if readState != state { readState = state }
            return
        }
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, id == self.readID, case .reading = self.readState else { return }
            self.lastProgressPublish = Date()
            if self.readState != state { self.readState = state }
        }
    }

    /// The one folder the noise check asks about for a summary.
    nonisolated static func noiseKey(_ session: TranscriptSummary) -> ProjectKey {
        ProjectKey(host: session.locator.host, path: session.cwd ?? session.directoryHint ?? "")
    }

    /// Splits a batch into rows and noise (`SessionFilter.isNoise`), carrying
    /// the per-project existence answers so far in and out.
    nonisolated static func classify(_ sessions: [TranscriptSummary], exists: [ProjectKey: DirectoryEvidence],
                                     directoryEvidence: (ProjectKey) -> DirectoryEvidence)
        -> (kept: [TranscriptSummary], noise: [HistoryKey], exists: [ProjectKey: DirectoryEvidence]) {
        var exists = exists
        var kept: [TranscriptSummary] = []
        var noise: [HistoryKey] = []
        for session in sessions {
            let isNoise = SessionFilter.isNoise(session) { path in
                let key = ProjectKey(host: session.locator.host, path: path)
                if let hit = exists[key] { return hit != .missing }
                let result = directoryEvidence(key)
                exists[key] = result
                return result != .missing
            }
            if isNoise { noise.append(HistoryKey(session)) } else { kept.append(session) }
        }
        return (kept, noise, exists)
    }

    // MARK: Inputs to the projection

    /// The tabs open now, with their activity (AppModel keeps this current).
    func openTabsChanged(_ tabs: [SessionKey: ActivityState]) {
        if activity != tabs { activity = tabs }
        let keys = Set(tabs.keys)
        guard keys != openTabKeys else { return }
        openTabKeys = keys
        enqueue(HistoryProjectionInput(openTabs: keys), urgent: true)
    }

    private func sendMembers(urgent: Bool) {
        membersDirty = false
        enqueue(HistoryProjectionInput(members: currentMembers, archivedProjects: overlay.archivedProjectKeys,
                                       openTabs: openTabKeys), urgent: urgent)
    }

    /// A member, a title or an archive flag changed. objectWillChange fires
    /// before the change lands, so this looks a turn later; off screen it
    /// only marks the members dirty.
    private func scheduleRebuild() {
        guard isActive else { membersDirty = true; return }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                guard self.isActive else { self.membersDirty = true; return }
                self.sendMembers(urgent: true)
            }
        }
    }

    private var currentQuery: HistoryQuery {
        HistoryQuery(scope: scope, agent: agentFilter, project: projectKeyFilter,
                     search: normalizedQuery, justArchived: justArchivedChip?.memberships)
    }

    private func enqueue(_ input: HistoryProjectionInput, urgent: Bool) {
        pending.merge(input)
        if urgent {
            pendingUrgent = true
            coalesceWait?.cancel()
        }
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.runPump() }
    }

    /// One projection at a time, in order. Catalog batches after a read's
    /// first wait out `coalesceInterval` since the last install; anything
    /// the user did (a query, a restore) goes at once. The projection runs
    /// on its own actor; only the install comes back here.
    private func runPump() async {
        while !pending.isEmpty {
            if !pendingUrgent, let last = lastInstall {
                let wait = coalesceInterval - Date().timeIntervalSince(last)
                if wait > 0 {
                    let sleeper = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    coalesceWait = sleeper
                    await sleeper.value
                    coalesceWait = nil
                }
            }
            var input = pending
            pending = HistoryProjectionInput()
            pendingUrgent = false
            releaseBacklog()
            input.generation = generation
            guard let next = await projector.apply(input) else { continue }
            if let beforeInstall { await beforeInstall() }
            // Superseded: the query changed while this was built, and the
            // input that changed it is already pending.
            guard next.generation == generation else { continue }
            install(next)
        }
        pumpTask = nil
    }

    /// The main actor's whole share of a projection: one assignment, the
    /// selection checked against the snapshot's index, and anything waiting
    /// for this query's answer.
    private func install(_ next: HistorySnapshot) {
        let started = Date()
        snapshot = next
        rebuildCount += 1
        installedGenerations.append(next.generation)
        lastInstall = Date()
        reconcileSelection()
        drainRecordedCommands()
        installDurations.append(Date().timeIntervalSince(started))
    }

    /// A selected row that left the view is not selected: nothing hidden can
    /// be imported or archived by a key press.
    private func reconcileSelection() {
        let index = snapshot.indexByKey
        if selection.contains(where: { index[$0] == nil }) {
            selection = selection.filter { index[$0] != nil }
        } else {
            refreshSelectionSummary()
        }
        if let cursorID, index[cursorID] == nil { self.cursorID = nil }
        if let anchorID, index[anchorID] == nil { self.anchorID = nil }
        if wantsInitialSelection, selection.isEmpty, snapshot.generation == generation,
           let first = snapshot.visibleRows.first {
            wantsInitialSelection = false
            select(only: first.id)
        }
    }

    /// Waits until every input so far is projected and installed, the
    /// overlay's deferred member check included. For tests and tools.
    func settle() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            pendingUrgent = true
            coalesceWait?.cancel()
            while let pump = pumpTask { await pump.value }
        }
    }

    /// The same as the old synchronous rebuild, for callers that only need
    /// the page caught up: members re-sent, then everything settled.
    func rebuild() async {
        sendMembers(urgent: true)
        await settle()
    }

    // MARK: Derived

    /// The row is a member's: its catalog entry (if any) matched the
    /// member's host and agent.
    public func isInTemple(_ row: HistoryRow) -> Bool { row.isMember }

    /// In Temple and put away (the session, or its whole project), as
    /// projected.
    public func isArchived(_ row: HistoryRow) -> Bool { row.isArchived }

    /// How a catalog entry stands against Temple's membership, which is
    /// keyed by the session id alone.
    enum Standing: Equatable {
        case outside
        case member
        case conflict(JoinConflict)
    }

    /// A member attaches to a catalog entry only when the host and the
    /// member's known agent both match. An agentless (legacy) member on the
    /// same host attaches when exactly one agent lists the id there; when
    /// two do, which one it is cannot be told, so neither attaches.
    nonisolated static func standing(of key: HistoryKey, member: SessionState?, otherAgentListed: Bool) -> Standing {
        guard let member else { return .outside }
        guard member.host == key.host else { return .conflict(.host(member.host)) }
        if let agent = member.agent {
            return key.agent == nil || key.agent == agent ? .member : .conflict(.agent(agent))
        }
        return otherAgentListed ? .conflict(.host(member.host)) : .member
    }

    /// The live answer for an import: against the rows as they are now,
    /// not as the page last drew them. Only a session with no row at all is
    /// outside: a member, on whatever host or agent, never is (`standing`).
    private func isImportable(_ summary: TranscriptSummary) -> Bool {
        overlayLookups += 1
        return overlay.rows[summary.id] == nil
    }

    /// Search, a filter or the chip is narrowing the page ("Showing 47 of 3,810").
    public var isNarrowed: Bool { !currentQuery.isDefault }

    public var isReading: Bool {
        if case .reading = readState { return true }
        return false
    }

    public var bottomBar: BottomBar? {
        if let notice { return .notice(notice) }
        if selection.count >= 2 { return .selection(count: selection.count) }
        return nil
    }

    /// The project filter names a project that is archived: the page offers
    /// Restore project under the toolbar.
    public var filteredProjectIsArchived: Bool {
        projectKeyFilter.map { snapshot.archivedProjects.contains($0) } ?? false
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every filter change — search included — clears the selection and puts
    /// the cursor on the first row of the new view.
    private func filtersChanged() {
        cancelPendingCommands()
        selection = []
        cursorID = nil
        anchorID = nil
        wantsInitialSelection = true
        generation += 1
        enqueue(HistoryProjectionInput(query: currentQuery), urgent: true)
    }

    private func draftChanged() {
        // A keystroke is newer input: what was recorded before it goes.
        cancelPendingCommands()
        debounceTask?.cancel()
        debounceTask = nil
        guard draft != query else { return }
        let delay = queryDebounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushQuery()
        }
    }

    /// Apply what is typed now, without waiting out the debounce.
    public func flushQuery() {
        debounceTask?.cancel()
        debounceTask = nil
        if query != draft { query = draft }
    }

    /// The field's ×, the empty state's Clear search, Esc's first rung.
    public func clearSearch() {
        draft = ""
        flushQuery()
    }

    /// The scope control. Picking any segment clears the chip.
    public func pickScope(_ next: HistoryScope) {
        justArchivedChip = nil
        scope = next
    }

    public func clearChip() { justArchivedChip = nil }

    // MARK: Selection

    public enum ClickModifier { case none, command, shift }

    /// Accepts a command: applies what is typed, then runs it now if the page
    /// answers the current input, else records it for the generation it
    /// targets (see the rule above).
    public func issue(_ command: Command, undoManager: UndoManager? = nil) {
        flushQuery()
        if snapshot.generation == generation, recordedCommands.isEmpty {
            perform(command, undoManager: undoManager)
        } else {
            recordedCommands.append((generation, command, undoManager))
        }
    }

    /// Withdraws every recorded command: newer input arrived.
    public func cancelPendingCommands() {
        recordedCommands = []
        commandToken += 1
    }

    /// Runs the recorded commands for the page just installed, one at a time,
    /// stopping at the first that no longer targets it or was cancelled.
    private func drainRecordedCommands() {
        let token = commandToken
        while let next = recordedCommands.first {
            guard token == commandToken, next.target == generation, next.target == snapshot.generation else {
                recordedCommands = []
                return
            }
            recordedCommands.removeFirst()
            perform(next.command, undoManager: next.undoManager)
        }
    }

    /// A sheet or alert is in front of the page.
    private var modalUp: Bool { pendingImport != nil || importFailure != nil }

    /// Commands recorded and not yet run.
    var waitingCommandCount: Int { recordedCommands.count }

    private func perform(_ command: Command, undoManager: UndoManager?) {
        guard !modalUp else { return cancelPendingCommands() }
        var terminal = false
        switch command {
        case .moveCursor(let delta, let extend): performMoveCursor(by: delta, extend: extend)
        case .moveToEnd(let top, let extend): performMoveToEnd(top: top, extend: extend)
        case .moveByDay(let forward, let extend): performMoveByDay(forward: forward, extend: extend)
        case .selectAll: performSelectAll()
        case .open: terminal = performOpen(undoManager: undoManager)
        case .archiveSelection: performArchiveSelection(undoManager: undoManager)
        case .restoreSelection: performRestoreSelection(undoManager: undoManager)
        case .importSelection: performImportSelection()
        }
        // It left the page, or put something in front of it: nothing
        // recorded after it may act on a page the user is no longer on.
        if terminal || modalUp { cancelPendingCommands() }
    }

    /// The pump took the backlog (or the read ended): a waiting lane goes on.
    private func releaseBacklog() {
        pendingCatalogRows = 0
        let waiters = backlogWaiters
        backlogWaiters = []
        waiters.forEach { $0.resume() }
    }

    public func click(_ id: HistoryKey, modifier: ClickModifier = .none) {
        wantsInitialSelection = false
        switch modifier {
        case .none:
            select(only: id)
        case .command:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
            cursorID = id
        case .shift:
            selection = range(from: anchorID ?? cursorID ?? id, to: id)
            cursorID = id
        }
    }

    private func select(only id: HistoryKey) {
        selection = [id]
        anchorID = id
        cursorID = id
    }

    private func range(from start: HistoryKey, to end: HistoryKey) -> Set<HistoryKey> {
        let index = snapshot.indexByKey
        guard let a = index[start], let b = index[end] else { return [end] }
        return Set(snapshot.visibleRows[min(a, b)...max(a, b)].map(\.id))
    }

    /// ↑/↓ (⇧ extends from the anchor).
    public func moveCursor(by delta: Int, extend: Bool = false) { issue(.moveCursor(by: delta, extend: extend)) }

    private func performMoveCursor(by delta: Int, extend: Bool) {
        let rows = snapshot.visibleRows
        guard !rows.isEmpty else { return }
        let target: Int
        if let cursorID, let index = snapshot.indexByKey[cursorID] {
            target = max(0, min(rows.count - 1, index + delta))
        } else {
            target = delta >= 0 ? 0 : rows.count - 1
        }
        moveCursor(to: rows[target].id, extend: extend)
    }

    /// ⌘↑/⌘↓.
    public func moveCursorToEnd(top: Bool, extend: Bool = false) { issue(.moveToEnd(top: top, extend: extend)) }

    private func performMoveToEnd(top: Bool, extend: Bool) {
        guard let id = top ? visibleRows.first?.id : visibleRows.last?.id else { return }
        moveCursor(to: id, extend: extend)
    }

    /// ⌥↑/⌥↓: the first row of the previous / next day. Up from inside a day
    /// lands on that day's first row first, like a paragraph jump.
    public func moveCursorByDay(forward: Bool, extend: Bool = false) { issue(.moveByDay(forward: forward, extend: extend)) }

    private func performMoveByDay(forward: Bool, extend: Bool) {
        let starts = snapshot.groupStarts
        guard !starts.isEmpty else { return }
        let position = cursorID.flatMap { snapshot.indexByKey[$0] }
        let current = position.map { index in (starts.lastIndex { $0 <= index }) ?? 0 }
        let target: Int
        if let current, let position {
            if forward {
                target = min(starts.count - 1, current + 1)
            } else if starts[current] != position {
                target = current
            } else {
                target = max(0, current - 1)
            }
        } else {
            target = forward ? 0 : starts.count - 1
        }
        moveCursor(to: snapshot.visibleRows[starts[target]].id, extend: extend)
    }

    private func moveCursor(to id: HistoryKey, extend: Bool) {
        wantsInitialSelection = false
        if extend {
            selection = range(from: anchorID ?? cursorID ?? id, to: id)
            cursorID = id
        } else {
            select(only: id)
        }
        scrollRequest += 1
    }

    /// ⌘A: everything in the current view — search and filters applied.
    public func selectAll() { issue(.selectAll) }

    private func performSelectAll() {
        wantsInitialSelection = false
        selection = Set(visibleRows.map(\.id))
        if cursorID == nil { cursorID = visibleRows.first?.id }
        anchorID = anchorID ?? visibleRows.first?.id
    }

    public func clearSelection() {
        wantsInitialSelection = false
        selection = []
        anchorID = nil
    }

    /// The selected rows in page order.
    public var selectedRows: [HistoryRow] {
        let index = snapshot.indexByKey
        return selection.compactMap { index[$0] }.sorted().map { snapshot.visibleRows[$0] }
    }

    /// Everything a row view draws from: its prepared row and the three small
    /// inputs that change on their own. Reads no overlay, no tab list, no
    /// formatter; the activity is one lookup in a small map.
    struct RowInputs: Equatable {
        let row: HistoryRow
        let selected: Bool
        let justImported: Bool
        /// The open tab's activity; nil when the session has no tab on the
        /// row's host (another host's or agent's row is not that session).
        let activity: ActivityState?
    }

    func rowInputs(_ row: HistoryRow) -> RowInputs {
        RowInputs(row: row, selected: selection.contains(row.id), justImported: justImported.contains(row.id),
                  activity: row.isMember ? activity[SessionKey(id: row.sessionID, host: row.host)] : nil)
    }

    /// What the bulk Import would bring in.
    public var selectedOutsideRows: [TranscriptSummary] {
        selectedRows.filter(\.canImport).compactMap(\.catalog)
    }

    private func refreshSelectionSummary() {
        let index = snapshot.indexByKey
        var summary = SelectionSummary()
        var archivable = true
        for key in selection {
            guard let position = index[key] else { continue }
            let row = snapshot.visibleRows[position]
            summary.count += 1
            if row.canImport { summary.importable += 1 }
            if row.isArchived { summary.archived += 1 }
            if !row.canArchive { archivable = false }
        }
        summary.archivable = summary.count > 0 && archivable
        if summary != selectionSummary { selectionSummary = summary }
    }

    /// Esc: clear search → clear the chip → clear selection → leave (the
    /// caller goes back to the previous tab; History stays open).
    public func escape() -> EscapeOutcome {
        // A Return (or anything else) still recorded is withdrawn first.
        cancelPendingCommands()
        // Esc straight after typing still clears the search: the ladder reads
        // what is in the field, not what the list has caught up to.
        flushQuery()
        if !query.isEmpty {
            clearSearch()
            return .clearedSearch
        }
        if justArchivedChip != nil {
            clearChip()
            return .clearedChip
        }
        if !selection.isEmpty {
            clearSelection()
            return .clearedSelection
        }
        return .leave
    }

    public func requestSearchFocus() { focusSearchRequest += 1 }

    // MARK: Opening and restoring

    /// Return. A tab is a process, so with two or more rows selected Return
    /// opens nothing, but when every one is archived it restores them:
    /// Restore starts nothing. With a query still being answered, Return
    /// waits for the answer, so typing then Return opens the first match.
    public func openSelected(undoManager: UndoManager? = nil) { issue(.open, undoManager: undoManager) }

    /// Returns whether it opened (or focused) a tab.
    private func performOpen(undoManager: UndoManager?) -> Bool {
        if selection.count >= 2 {
            if selectionSummary.allArchived { performRestoreSelection(undoManager: undoManager) }
            return false
        }
        guard selection.count == 1, let id = selection.first,
              let position = snapshot.indexByKey[id] else { return false }
        return primaryAction(snapshot.visibleRows[position], undoManager: undoManager)
    }

    /// A row's primary action: Open (which restores an archived session on
    /// the way, ADR-017's one implicit unarchive), or for an archived row
    /// that cannot resume, Restore.
    /// Returns whether it opened (or focused) a tab.
    @discardableResult
    public func primaryAction(_ row: HistoryRow, undoManager: UndoManager? = nil) -> Bool {
        if row.isArchived, !row.canResume {
            restore([row], undoManager: undoManager)
            return false
        }
        return open(row)
    }

    /// The live check an action makes: in Temple, not archived now, and no
    /// tab open on it now.
    public func canArchive(_ row: HistoryRow) -> Bool {
        guard let member = row.member else { return false }
        overlayLookups += 1
        let archived = overlay.isArchived(member.id)
            || (row.project.map { overlay.isProjectArchived($0) } ?? false)
        return !archived && !hasOpenTab(row.id)
    }

    public func archive(_ row: HistoryRow, undoManager: UndoManager?) {
        guard canArchive(row), let member = row.member else { return }
        archiveMember(member.id, undoManager)
    }

    /// Archive N, and ⌘⌫, act only when they would archive every selected
    /// row: a bulk verb that silently skips some is worse than none. Checked
    /// live; the bar shows `selectionSummary.archivable`.
    public var canArchiveSelection: Bool {
        let rows = selectedRows
        return !rows.isEmpty && rows.allSatisfy(canArchive)
    }

    /// The selection bar's Archive N and ⌘⌫. One undo step, with the same
    /// notice and Undo the import uses.
    public func archiveSelected(undoManager: UndoManager?) { issue(.archiveSelection, undoManager: undoManager) }

    private func performArchiveSelection(undoManager: UndoManager?) {
        guard canArchiveSelection else { return }
        let ids = selectedRows.compactMap { $0.member?.id }
        clearSelection()
        archiveMembers(ids, undoManager) { [weak self] archived in
            self?.showNotice(Notice(text: archived ? Self.archivedNotice(ids.count) : Self.archiveUndoneNotice(ids.count),
                                    offersUndo: archived && undoManager != nil))
        }
        showNotice(Notice(text: Self.archivedNotice(ids.count), offersUndo: undoManager != nil))
    }

    static func archivedNotice(_ count: Int) -> String {
        count == 1 ? "1 session archived" : "\(count) sessions archived"
    }

    static func archiveUndoneNotice(_ count: Int) -> String {
        count == 1 ? "Archive undone" : "\(count) archives undone"
    }

    /// Restore brings each session back on its own (ADR-031): one in an
    /// archived project comes back without the rest of it. One undo step.
    /// It restores the memberships the rows show (id, host, incarnation): a
    /// session that left and joined again since the page was drawn is not
    /// the one restored.
    public func restore(_ rows: [HistoryRow], undoManager: UndoManager?) {
        let refs = rows.filter(\.isArchived).compactMap { row -> MembershipRef? in
            guard let state = row.member?.state, let incarnation = state.incarnation else { return nil }
            return MembershipRef(id: state.id, host: state.host, incarnation: incarnation)
        }
        guard !refs.isEmpty else { return }
        let report = restoreMembers(refs, undoManager) { [weak self] change in
            switch change {
            case .undone: self?.showNotice(Notice(text: "Restore undone", offersUndo: false))
            case .redone(let report): self?.announce(report)
            }
        }
        announce(report)
    }

    /// What a Restore did, in its own numbers. Undo only for a step this
    /// operation put on the stack: otherwise ⌘Z would undo something else.
    private func announce(_ report: AppModel.RestoreReport) {
        guard report.restored > 0 else {
            showNotice(Notice(text: Self.nothingRestoredNotice, offersUndo: false))
            return
        }
        showNotice(Notice(text: Self.restoredNotice(report.restored), offersUndo: report.undoable))
    }

    static let nothingRestoredNotice = "Nothing to restore; it changed since the list loaded."

    /// The bar's Restore N, and Return on an all-archived selection.
    public func restoreSelected(undoManager: UndoManager?) { issue(.restoreSelection, undoManager: undoManager) }

    private func performRestoreSelection(undoManager: UndoManager?) {
        let rows = selectedRows.filter(\.isArchived)
        guard !rows.isEmpty else { return }
        clearSelection()
        restore(rows, undoManager: undoManager)
    }

    /// Restore project: the mask comes off, and every session in it that is
    /// not archived itself comes back with it.
    public func restoreProject(_ key: ProjectKey, undoManager: UndoManager?) {
        restoreProjectAction(key, undoManager)
        showNotice(Notice(text: "\(key.displayName) restored", offersUndo: undoManager != nil))
    }

    static func restoredNotice(_ count: Int) -> String {
        count == 1 ? "1 session restored" : "\(count) sessions restored"
    }

    /// Opens (or focuses) the row's session in a tab; returns whether it did.
    @discardableResult
    public func open(_ row: HistoryRow) -> Bool {
        guard row.canResume else { return false }
        if let member = row.member { openMember(member) }
        else if let catalog = row.catalog { openSession(catalog) }
        else { return false }
        return true
    }

    public func open(_ session: TranscriptSummary) { openSession(session) }
    public func requestImport(_ rows: [HistoryRow]) { requestImport(rows.filter(\.canImport).compactMap(\.catalog)) }

    public func showOnly(project key: ProjectKey) { projectKeyFilter = key }

    // MARK: Import

    /// ⌘I, the bar's Import, a row's Import: ask first. Rows already in
    /// Temple are left out of the count and the copy; nothing to import, no
    /// sheet.
    public func requestImport(_ sessions: [TranscriptSummary]? = nil) {
        // The selection's Import is a command; a row's own acts on its row.
        guard let sessions else { return issue(.importSelection) }
        askToImport(sessions)
    }

    private func performImportSelection() { askToImport(selectedOutsideRows) }

    private func askToImport(_ sessions: [TranscriptSummary]) {
        let candidates = sessions.filter(isImportable)
        guard !candidates.isEmpty else { return }
        pendingImport = makeImportRequest(for: candidates)
    }

    /// The copy in the words the page shows: display titles, and where each
    /// project's rows will actually be listed.
    func makeImportRequest(for sessions: [TranscriptSummary]) -> ImportRequest {
        Self.importRequest(for: sessions,
                           title: { [overlay] in overlay.displayTitle(for: $0) },
                           isProjectArchived: { [overlay] in overlay.isProjectArchived($0) })
    }

    public func cancelImport() { pendingImport = nil }

    /// A project that is archived lists its sessions in History's Archived
    /// scope, not the sidebar — so the copy says so rather than promise a
    /// sidebar row that never appears. Projects are keyed by the host the
    /// session lives on: the same path on another host is another project.
    static func importRequest(for sessions: [TranscriptSummary],
                              title: (TranscriptSummary) -> String = { $0.catalogTitle },
                              isProjectArchived: (ProjectKey) -> Bool = { _ in false }) -> ImportRequest {
        var counts: [ProjectKey: Int] = [:]
        for session in sessions {
            counts[ProjectKey(host: session.locator.host, path: session.catalogDirectory), default: 0] += 1
        }
        let keys = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            let (left, right) = (projectName(lhs.key.path), projectName(rhs.key.path))
            guard left == right else { return left < right }
            return lhs.key.path == rhs.key.path ? lhs.key.host.rawValue < rhs.key.host.rawValue : lhs.key.path < rhs.key.path
        }.map(\.key)
        let sidebar = keys.filter { !isProjectArchived($0) }.map { projectName($0.path) }
        let archive = keys.filter(isProjectArchived).map { projectName($0.path) }
        var places: [String] = []
        if !sidebar.isEmpty { places.append("in the sidebar under \(projectList(sidebar))") }
        if !archive.isEmpty {
            places.append("in History under Archived, because \(projectList(archive)) \(archive.count == 1 ? "is" : "are") archived")
        }
        let destination = places.joined(separator: ", and ")
        if sessions.count == 1, let session = sessions.first {
            return ImportRequest(
                sessions: sessions,
                title: "Import “\(title(session))” into Temple?",
                message: "It will appear \(destination). Nothing runs until you open it, and the session file on disk is not changed.",
                confirmLabel: "Import")
        }
        return ImportRequest(
            sessions: sessions,
            title: "Import \(sessions.count) sessions into Temple?",
            message: "They will appear \(destination). Nothing runs until you open one, and the session files on disk are not changed.",
            confirmLabel: "Import \(sessions.count)")
    }

    /// "raven", "raven and dotfiles", "raven, dotfiles and mentes-ai",
    /// "raven, dotfiles and 3 more projects".
    static func projectList(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more projects"
        }
    }

    static func projectName(_ path: String) -> String {
        path.isEmpty ? "—" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// The sheet's Import. Joins each as `.imported`, clears the selection,
    /// says what happened with an Undo, and leaves the user on History.
    /// `request` is the one the sheet was showing: the sheet's dismissal can
    /// clear `pendingImport` before its button's action runs.
    public func confirmImport(_ request: ImportRequest? = nil, undoManager: UndoManager?) async {
        guard let request = request ?? pendingImport else { return }
        pendingImport = nil
        let sessions = request.sessions.filter(isImportable)
        guard !sessions.isEmpty else { return }
        finishImport(sessions, undoManager: undoManager)
        await settle()
    }

    private func finishImport(_ sessions: [TranscriptSummary], undoManager: UndoManager?) {
        // Redo replays rows captured earlier: skip any that joined since.
        let attempted = sessions.filter { !overlay.isTempleSession($0.id) }
        guard !attempted.isEmpty else { return }
        // One outcome per row: two rows sharing an id (two hosts, two
        // agents) are not both imported — the second is refused, with why.
        let outcomes = overlay.import(attempted)
        var imported: [HistoryKey] = []
        var incarnations: [HistoryKey: String] = [:]
        var failed: [(TranscriptSummary, Error)] = []
        for (session, outcome) in zip(attempted, outcomes) {
            switch outcome {
            case .joined(let incarnation):
                imported.append(HistoryKey(session))
                incarnations[HistoryKey(session)] = incarnation
            case .skipped: break
            case .failed(let error): failed.append((session, error))
            }
        }
        clearSelection()
        if !imported.isEmpty {
            let importedKeys = Set(imported)
            markJustImported(imported)
            showNotice(Notice(text: imported.count == 1 ? "1 session imported" : "\(imported.count) sessions imported",
                              offersUndo: undoManager != nil))
            registerUndo(undoManager, imported: imported, incarnations: incarnations,
                         sessions: attempted.filter { importedKeys.contains(HistoryKey($0)) })
        }
        if !failed.isEmpty {
            let failedTitles = failed.map { overlay.displayTitle(for: $0.0) }
            let errors = Set(failed.map { $0.1.localizedDescription }).sorted()
            var lines = errors + [failedTitles.joined(separator: " · ")]
            if !imported.isEmpty {
                lines.append(imported.count == 1 ? "The other one was imported." : "The other \(imported.count) were imported.")
            }
            importFailure = ImportFailure(
                title: Self.importFailureTitle(failed: failed.count, attempted: attempted.count,
                                               onlyTitle: failedTitles.first ?? ""),
                message: lines.joined(separator: "\n"))
        }
        sendMembers(urgent: true)
    }

    /// "Couldn't import 1 of 1 sessions" said less than the title would:
    /// when nothing was imported, name the one session or count them all.
    static func importFailureTitle(failed: Int, attempted: Int, onlyTitle: String) -> String {
        guard failed == attempted else { return "Couldn't import \(failed) of \(attempted) sessions" }
        return attempted == 1 ? "Couldn't import “\(onlyTitle)”" : "Couldn't import \(attempted) sessions"
    }

    /// Undo removes exactly the rows this import wrote — each by its id and
    /// the host it was imported from — and only while each is still an
    /// untouched import not running in a tab (`TempleDB.leave`). Redo imports
    /// what the undo removed. The pair re-registers itself, so ⌘Z / ⌘⇧Z
    /// bounce as often as the user likes.
    private func registerUndo(_ undoManager: UndoManager?, imported keys: [HistoryKey], incarnations: [HistoryKey: String],
                              sessions: [TranscriptSummary]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                let left = Set(model.undoImport(keys, incarnations: incarnations))
                guard let undoManager, !left.isEmpty else { return }
                let back = sessions.filter { left.contains(HistoryKey($0)) }
                undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
                    MainActor.assumeIsolated {
                        // Redo must register its inverse synchronously inside UndoManager's
                        // callback. The catalog rows captured by the original import carry
                        // the same facts it committed.
                        model.finishImport(back, undoManager: undoManager)
                    }
                }
                undoManager.setActionName("Import")
            }
        }
        undoManager.setActionName("Import")
    }

    /// Returns the rows whose sessions left Temple. Each leave names the
    /// membership the import made — its host, agent and incarnation — so a
    /// row another host holds under the same id, or one that left and joined
    /// again since (another agent's file, or a re-import), is never the one
    /// removed. A committed leave tells the live engine itself
    /// (`TempleDB.observeLeaves`); nothing to re-read here.
    @discardableResult
    func undoImport(_ keys: [HistoryKey], incarnations: [HistoryKey: String] = [:]) -> [HistoryKey] {
        let open = Set(keys.filter { hasOpenTab($0) })
        let candidates = keys.filter { !open.contains($0) }
        let left = Set(overlay.leave(candidates.map {
            SessionOverlayStore.ImportedMembership(key: SessionKey(id: $0.sessionID, host: $0.host),
                                                   agent: $0.agent, incarnation: incarnations[$0])
        }))
        let leftKeys = candidates.filter { left.contains($0.sessionID) }
        justImported.subtract(leftKeys)
        showNotice(Notice(text: Self.undoNotice(total: keys.count, left: leftKeys.count,
                                                open: open.count, changed: candidates.count - leftKeys.count),
                          offersUndo: false))
        sendMembers(urgent: true)
        return leftKeys
    }

    /// What the undo did, and why anything it did not undo stayed: running in
    /// a tab, or changed since (pinned, named, opened…).
    static func undoNotice(total: Int, left: Int, open: Int, changed: Int) -> String {
        guard open + changed > 0 else {
            return left == 1 ? "Import undone" : "\(left) imports undone"
        }
        if total == 1 {
            return open > 0 ? "Import not undone · open in a tab" : "Import not undone · changed since"
        }
        var reasons: [String] = []
        if open > 0 { reasons.append("\(open) open in a tab") }
        if changed > 0 { reasons.append("\(changed) changed since") }
        let head = left == 0 ? "No imports undone" : "\(left) of \(total) imports undone"
        return "\(head) · \(reasons.joined(separator: ", ")), kept"
    }

    private func markJustImported(_ ids: [HistoryKey]) {
        justImported.formUnion(ids)
        importedTask?.cancel()
        let delay = importedDuration
        importedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.justImported = []
        }
    }

    private func showNotice(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        let delay = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    public func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}
