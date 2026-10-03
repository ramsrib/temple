import Foundation
import Combine
import TempleCore

/// The segmented control: which side of the Temple line a row must be on.
public enum HistoryScope: String, CaseIterable, Identifiable, Sendable {
    case all, inTemple, notInTemple

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .inTemple: "In Temple"
        case .notInTemple: "Not in Temple"
        }
    }
}

/// The History tab's state: a snapshot of every session on disk, joined with
/// what Temple knows of each, and the page's view state over it (search,
/// filters, selection, the import in flight).
///
/// The live index holds Temple's sessions only (ADR-027), so this reads the
/// disk itself, through `SessionCatalog`, when the tab is shown and on
/// Refresh — never watched. The tab's view state lives as long as the tab:
/// `reset()` runs when it closes. Filters are a question, not a setting, and
/// are never persisted.
@MainActor
public final class HistoryModel: ObservableObject {

    public enum ReadState: Equatable, Sendable {
        /// No read has run since the tab opened (or the last one was cancelled).
        case idle
        /// Files consumed so far; `total` is nil until the stores are listed.
        case reading(read: Int, total: Int?)
        case done
    }

    public struct StoreFailure: Equatable, Sendable {
        public let agent: Agent
        public let message: String
    }

    /// What the confirmation sheet says and imports. Built when asked, so the
    /// copy names exactly the rows that will join.
    public struct ImportRequest: Identifiable, Equatable {
        public let id = UUID()
        public let sessions: [AgentSession]
        public let title: String
        public let message: String
        public let confirmLabel: String
    }

    public struct ImportFailure: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    /// The selection bar's transient line after an import or its undo.
    public struct Notice: Equatable {
        public let text: String
        public let offersUndo: Bool
    }

    public enum EscapeOutcome: Equatable {
        case clearedSearch, clearedSelection, leave
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

    /// A project in the popup, with how many sessions on disk it holds.
    public struct ProjectCount: Equatable, Sendable {
        public let key: ProjectKey
        public var path: String { key.path }
        public let count: Int
    }

    // MARK: Dependencies

    private let overlay: SessionOverlayStore
    /// Runs off the main actor: the noise check stats each project once a read.
    private let pathExists: @Sendable (String) -> Bool
    private let now: () -> Date
    /// The full-disk read. Replaceable so tests feed events by hand.
    var catalog: () -> AsyncStream<SessionCatalog.Event>
    /// Open (or focus) a session in a tab. Opening an outside session joins it
    /// as `opened` on the way (ADR-023).
    var openSession: (AgentSession) -> Void = { _ in }
    /// Whether a session runs in an open tab: undoing its import must not
    /// pull it out from under that tab.
    var hasOpenTab: (String) -> Bool = { _ in false }

    // MARK: Snapshot

    /// The disk as last read: deduped by id, first (newest) file wins.
    private var diskByID: [String: AgentSession] = [:]
    /// Temple's own copies come from the live index — fresher titles and
    /// times. Kept as delivered; keyed by id only when a rebuild needs it.
    var memberRows: () -> [Session] = { [] }
    var openMember: (Session) -> Void = { _ in }
    private var noiseIDs: Set<String> = []
    private var joinedByID: [String: SessionState] = [:]

    @Published public private(set) var readState: ReadState = .idle
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var storeFailures: [StoreFailure] = []

    /// Every non-noise session on disk, newest first.
    @Published public private(set) var allRows: [HistoryRow] = []
    /// `allRows` through search and filters, in the same order.
    @Published public private(set) var visibleRows: [HistoryRow] = []
    @Published public private(set) var groups: [HistoryRowDayGroup] = []
    @Published public private(set) var inTempleCount = 0
    @Published public private(set) var agentCounts: [Agent: Int] = [:]
    /// Projects for the popup, by session count, most first.
    @Published public private(set) var projects: [ProjectCount] = []

    // MARK: View state

    /// The search field's text, as typed. It reaches `query` — and the list —
    /// `queryDebounce` after the last keystroke; Esc and Return flush it
    /// first, so neither acts on the query from before the typing.
    @Published public var draft = "" { didSet { if draft != oldValue { draftChanged() } } }
    /// The applied search. Setting it (the ⌘K bridge) brings the field along.
    @Published public var query = "" {
        didSet {
            guard query != oldValue else { return }
            if draft != query { draft = query }
            filtersChanged()
        }
    }
    @Published public var scope: HistoryScope = .all { didSet { if scope != oldValue { filtersChanged() } } }
    @Published public var agentFilter: Agent? { didSet { if agentFilter != oldValue { filtersChanged() } } }
    @Published public var projectKeyFilter: ProjectKey? { didSet { if projectKeyFilter != oldValue { filtersChanged() } } }
    public var projectFilter: String? {
        get { projectKeyFilter?.path }
        set { projectKeyFilter = newValue.map { ProjectKey(host: .local, path: $0) } }
    }


    @Published public private(set) var selection: Set<String> = []
    /// The row the keyboard is on: arrows move from it, ⇧ extends to it.
    @Published public private(set) var cursorID: String?
    /// Where a ⇧-extension is measured from.
    private var anchorID: String?
    /// Bumped when the list should bring the cursor into view.
    @Published public private(set) var scrollRequest = 0
    /// Bumped by ⌘F: the view moves keyboard focus into the search field.
    @Published public private(set) var focusSearchRequest = 0
    /// History's own search field holds keyboard focus. The view keeps it
    /// current; the key router reads it to tell this field from any other
    /// (sidebar search, a chip being renamed), whose keys are not History's.
    /// Not published: nothing on screen draws from it.
    public var searchFieldFocused = false

    @Published public var pendingImport: ImportRequest?
    @Published public var importFailure: ImportFailure?
    @Published public private(set) var notice: Notice?
    /// Rows whose status column reads "Imported" for a moment.
    @Published public private(set) var justImported: Set<String> = []

    /// Select the first row once there is one — on open, and after a filter
    /// change: arrows and Return work without a click.
    private var wantsInitialSelection = true
    private var readTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var importedTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var rebuildScheduled = false
    /// The tab is on screen. Off screen, a change only marks the page dirty:
    /// re-sorting a few thousand rows for a page nobody is looking at, on
    /// every membership or live-index change, is work for nothing.
    private var isActive = false
    private var needsRebuild = false
    private var cancellables: Set<AnyCancellable> = []

    var noticeDuration: TimeInterval = 4
    var importedDuration: TimeInterval = 2
    var queryDebounce: TimeInterval = 0.12

    init(overlay: SessionOverlayStore,
         catalog: @escaping () -> AsyncStream<SessionCatalog.Event> = { SessionCatalog().stream() },
         pathExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         now: @escaping () -> Date = Date.init) {
        self.overlay = overlay
        self.catalog = catalog
        self.pathExists = pathExists
        self.now = now
        // Membership, renames, retitles and archive state all show on the
        // page. A burst (a bulk import, live retitles) is one rebuild.
        overlay.objectWillChange
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
    }

    func rowsChanged() { scheduleRebuild() }

    private var currentMembers: [Session] {
        let supplied = memberRows()
        return supplied.isEmpty ? overlay.rows.values.map { Session(state: $0) } : supplied
    }

    // MARK: Lifecycle

    /// The tab came on screen (opened, or switched back to): catch up on what
    /// changed while it was away, then take a fresh snapshot. Rows already on
    /// the page stay while it reads.
    public func activate() {
        isActive = true
        if selection.isEmpty { wantsInitialSelection = true }
        rebuild()
        refresh()
    }

    /// The tab left the screen: stop reading for nobody, and stop rebuilding.
    public func deactivate() {
        isActive = false
        guard readTask != nil else { return }
        readTask?.cancel()
        readTask = nil
        if case .reading = readState { readState = lastUpdated == nil ? .idle : .done }
    }

    /// The tab closed: its view state goes with it.
    public func reset() {
        deactivate()
        diskByID = [:]
        noiseIDs = []
        joinedByID = [:]
        storeFailures = []
        lastUpdated = nil
        readState = .idle
        pendingImport = nil
        importFailure = nil
        notice = nil
        justImported = []
        selection = []
        cursorID = nil
        anchorID = nil
        wantsInitialSelection = true
        debounceTask?.cancel()
        debounceTask = nil
        draft = ""
        query = ""; scope = .all; agentFilter = nil; projectKeyFilter = nil
        // Directly, not through `invalidate()`: the tab is gone, and its page
        // must open empty next time rather than flash the old snapshot.
        rebuild()
    }

    /// ⌘R, and every activation. A read already running is replaced.
    public func refresh() {
        readTask?.cancel()
        readState = .reading(read: 0, total: nil)
        let stream = catalog()
        let pathExists = pathExists
        readTask = Task { [weak self] in
            var seen: Set<String> = []
            var failures: [StoreFailure] = []
            var exists: [String: Bool] = [:]
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .listed(let total):
                    self.readState = .reading(read: 0, total: total)
                case .storeFailed(let agent, let message):
                    failures.append(StoreFailure(agent: agent, message: message))
                    self.storeFailures = failures
                case .sessions(let batch, let read, let total):
                    // First (newest) file wins. The noise check — a stat per
                    // project, memoised across the read — runs off the main
                    // actor, a batch at a time so the order is kept.
                    let fresh = batch.filter { seen.insert($0.id).inserted }
                    let known = exists
                    let sorted = await Task.detached(priority: .userInitiated) {
                        Self.classify(fresh, exists: known, pathExists: pathExists)
                    }.value
                    guard !Task.isCancelled else { return }
                    exists = sorted.exists
                    for session in fresh {
                        self.diskByID[session.id] = session
                        self.noiseIDs.remove(session.id)
                    }
                    self.noiseIDs.formUnion(sorted.noise)
                    self.readState = .reading(read: read, total: total)
                    self.rebuild()
                }
            }
            guard let self, !Task.isCancelled else { return }
            // Gone from disk since the last read: drop it now the read is whole.
            self.diskByID = self.diskByID.filter { seen.contains($0.key) }
            self.storeFailures = failures
            self.joinedByID = Dictionary(self.currentMembers.map { ($0.id, $0.state) },
                                         uniquingKeysWith: { first, _ in first })
            self.lastUpdated = self.now()
            self.readState = .done
            self.readTask = nil
            self.rebuild()
        }
    }

    /// Splits a batch into rows and noise (`SessionFilter.isNoise`), carrying
    /// the per-project existence answers so far in and out.
    nonisolated static func classify(_ sessions: [AgentSession], exists: [String: Bool],
                                     pathExists: (String) -> Bool)
        -> (kept: [AgentSession], noise: [String], exists: [String: Bool]) {
        var exists = exists
        var kept: [AgentSession] = []
        var noise: [String] = []
        for session in sessions {
            let isNoise = SessionFilter.isNoise(session) { path in
                if let hit = exists[path] { return hit }
                let result = pathExists(path)
                exists[path] = result
                return result
            }
            if isNoise { noise.append(session.id) } else { kept.append(session) }
        }
        return (kept, noise, exists)
    }

    // MARK: Derived

    public func isInTemple(_ id: String) -> Bool { overlay.rows[id] != nil }

    /// In Temple and put away (the session, or its whole project).
    public func isArchived(_ session: HistoryRow) -> Bool {
        isInTemple(session.id)
            && (overlay.isArchived(session.id) || (session.project.map { overlay.isProjectArchived($0) } ?? false))
    }

    public func joinedState(_ id: String) -> SessionState? { joinedByID[id] }

    /// Search or a filter is narrowing the page ("Showing 47 of 3,810").
    public var isNarrowed: Bool {
        !normalizedQuery.isEmpty || scope != .all || agentFilter != nil || projectKeyFilter != nil
    }

    public var isReading: Bool {
        if case .reading = readState { return true }
        return false
    }

    public var bottomBar: BottomBar? {
        if let notice { return .notice(notice) }
        if selection.count >= 2 { return .selection(count: selection.count) }
        return nil
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something the page shows changed: rebuild now if it is on screen,
    /// else when it next is.
    private func invalidate() {
        if isActive { rebuild() } else { needsRebuild = true }
    }

    private func scheduleRebuild() {
        guard isActive else { needsRebuild = true; return }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // objectWillChange fires BEFORE the change lands: rebuild a turn later.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                self.invalidate()
            }
        }
    }

    /// Recompute every derived list from the snapshot. A few thousand structs:
    /// cheap, and never run from a view body. Each published value is
    /// assigned only when it changed, so a write the page does not show (a
    /// title arriving for some open tab) re-renders nothing.
    func rebuild() {
        needsRebuild = false
        let members = Dictionary(currentMembers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let temple = Set(members.keys)
        var rows = diskByID.values.compactMap { disk -> HistoryRow? in
            if let member = members[disk.id] { return HistoryRow(member: member, catalog: disk) }
            return noiseIDs.contains(disk.id) ? nil : HistoryRow(catalog: disk)
        }
        rows += members.values.filter { diskByID[$0.id] == nil }.map { HistoryRow(member: $0) }
        joinedByID = Dictionary(members.values.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        rows.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        assign(\.allRows, rows)
        assign(\.inTempleCount, rows.reduce(0) { $0 + (temple.contains($1.id) ? 1 : 0) })
        var agents: [Agent: Int] = [:]
        var projectCounts: [ProjectKey: Int] = [:]
        for row in rows {
            if let agent = row.agent { agents[agent, default: 0] += 1 }
            if let project = row.project { projectCounts[project, default: 0] += 1 }
        }
        assign(\.agentCounts, agents)
        assign(\.projects, projectCounts
            .map { ProjectCount(key: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.path < $1.path : $0.count > $1.count })

        let needle = normalizedQuery
        let visible = rows.filter { session in
            switch scope {
            case .all: break
            case .inTemple: if !temple.contains(session.id) { return false }
            case .notInTemple: if temple.contains(session.id) { return false }
            }
            if let agentFilter, session.agent != agentFilter { return false }
            if let projectKeyFilter, session.project != projectKeyFilter { return false }
            return needle.isEmpty || Self.matches(session, needle)
        }
        assign(\.visibleRows, visible)
        assign(\.groups, HistoryRowGrouping.groups(visible, now: now()))

        // A selected row that left the view is not selected: nothing hidden
        // can be imported by a key press.
        let visibleIDs = Set(visible.map(\.id))
        let kept = selection.intersection(visibleIDs)
        if kept != selection { selection = kept }
        if let cursorID, !visibleIDs.contains(cursorID) { self.cursorID = nil }
        if let anchorID, !visibleIDs.contains(anchorID) { self.anchorID = nil }
        if wantsInitialSelection, selection.isEmpty, let first = visible.first {
            wantsInitialSelection = false
            select(only: first.id)
        }
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HistoryModel, Value>,
                                          _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// Case-insensitive substring over everything the row shows or hides in
    /// its tooltip, plus an id prefix (a pasted id from a log finds its row).
    /// No ranking: order is chronology.
    static func matches(_ session: HistoryRow, _ needle: String) -> Bool {
        if session.title.localizedCaseInsensitiveContains(needle) { return true }
        if session.projectPath.localizedCaseInsensitiveContains(needle) { return true }
        if let branch = session.gitBranch, branch.localizedCaseInsensitiveContains(needle) { return true }
        if let preview = session.lastMessagePreview, preview.localizedCaseInsensitiveContains(needle) { return true }
        return session.id.lowercased().hasPrefix(needle.lowercased())
    }

    /// Every filter change — search included — clears the selection and puts
    /// the cursor on the first row of the new view.
    private func filtersChanged() {
        selection = []
        cursorID = nil
        anchorID = nil
        wantsInitialSelection = true
        invalidate()
    }

    private func draftChanged() {
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

    // MARK: Selection

    public enum ClickModifier { case none, command, shift }

    public func click(_ id: String, modifier: ClickModifier = .none) {
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

    private func select(only id: String) {
        selection = [id]
        anchorID = id
        cursorID = id
    }

    private func range(from start: String, to end: String) -> Set<String> {
        let ids = visibleRows.map(\.id)
        guard let a = ids.firstIndex(of: start), let b = ids.firstIndex(of: end) else { return [end] }
        return Set(ids[min(a, b)...max(a, b)])
    }

    /// ↑/↓ (⇧ extends from the anchor).
    public func moveCursor(by delta: Int, extend: Bool = false) {
        let ids = visibleRows.map(\.id)
        guard !ids.isEmpty else { return }
        let target: Int
        if let cursorID, let index = ids.firstIndex(of: cursorID) {
            target = max(0, min(ids.count - 1, index + delta))
        } else {
            target = delta >= 0 ? 0 : ids.count - 1
        }
        moveCursor(to: ids[target], extend: extend)
    }

    /// ⌘↑/⌘↓.
    public func moveCursorToEnd(top: Bool, extend: Bool = false) {
        guard let id = top ? visibleRows.first?.id : visibleRows.last?.id else { return }
        moveCursor(to: id, extend: extend)
    }

    /// ⌥↑/⌥↓: the first row of the previous / next day. Up from inside a day
    /// lands on that day's first row first, like a paragraph jump.
    public func moveCursorByDay(forward: Bool, extend: Bool = false) {
        guard !groups.isEmpty else { return }
        let current = cursorID.flatMap { id in groups.firstIndex { $0.sessions.contains { $0.id == id } } }
        let target: Int
        if let current {
            if forward {
                target = min(groups.count - 1, current + 1)
            } else if groups[current].sessions.first?.id != cursorID {
                target = current
            } else {
                target = max(0, current - 1)
            }
        } else {
            target = forward ? 0 : groups.count - 1
        }
        guard let id = groups[target].sessions.first?.id else { return }
        moveCursor(to: id, extend: extend)
    }

    private func moveCursor(to id: String, extend: Bool) {
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
    public func selectAll() {
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
        visibleRows.filter { selection.contains($0.id) }
    }

    /// What the bulk Import would bring in.
    public var selectedOutsideRows: [AgentSession] {
        selectedRows.filter { !isInTemple($0.id) }.compactMap(\.catalog)
    }

    /// Esc: clear search → clear selection → leave (the caller goes back to
    /// the previous tab; History stays open).
    public func escape() -> EscapeOutcome {
        // Esc straight after typing still clears the search: the ladder reads
        // what is in the field, not what the list has caught up to.
        flushQuery()
        if !query.isEmpty {
            clearSearch()
            return .clearedSearch
        }
        if !selection.isEmpty {
            clearSelection()
            return .clearedSelection
        }
        return .leave
    }

    public func requestSearchFocus() { focusSearchRequest += 1 }

    // MARK: Opening

    /// Return / double-click. A tab is a process, so with two or more rows
    /// selected Return opens nothing — Import is the only bulk verb.
    public func openSelected() {
        // Typing then Return at once opens the first match, not the row that
        // was selected before the typing.
        flushQuery()
        guard selection.count == 1, let id = selection.first,
              let session = visibleRows.first(where: { $0.id == id }) else { return }
        open(session)
    }

    public func open(_ session: HistoryRow) {
        guard session.canResume else { return }
        if let member = session.member { openMember(member) }
        else if let catalog = session.catalog { openSession(catalog) }
    }

    public func open(_ session: AgentSession) { openSession(session) }
    public func requestImport(_ rows: [HistoryRow]) { requestImport(rows.compactMap(\.catalog)) }


    public func showOnly(project key: ProjectKey) { projectKeyFilter = key }
    public func showOnly(project path: String) { showOnly(project: ProjectKey(host: .local, path: path)) }

    // MARK: Import

    /// ⌘I, the bar's Import, a row's Import: ask first. Rows already in
    /// Temple are left out of the count and the copy; nothing to import, no
    /// sheet.
    public func requestImport(_ sessions: [AgentSession]? = nil) {
        let candidates = (sessions ?? selectedRows.compactMap(\.catalog)).filter { !isInTemple($0.id) }
        guard !candidates.isEmpty else { return }
        pendingImport = makeImportRequest(for: candidates)
    }

    /// The copy in the words the page shows: display titles, and where each
    /// project's rows will actually be listed.
    func makeImportRequest(for sessions: [AgentSession]) -> ImportRequest {
        Self.importRequest(for: sessions,
                           title: { [overlay] in overlay.displayTitle(for: $0) },
                           isProjectArchived: { [overlay] in overlay.isProjectArchived($0) })
    }

    public func cancelImport() { pendingImport = nil }

    /// A project that is archived lists its sessions in the archive (⌘⇧Y),
    /// not the sidebar — so the copy says so rather than promise a sidebar
    /// row that never appears.
    static func importRequest(for sessions: [AgentSession],
                              title: (AgentSession) -> String = { $0.title },
                              isProjectArchived: (String) -> Bool = { _ in false }) -> ImportRequest {
        var counts: [String: Int] = [:]
        for session in sessions { counts[session.projectPath, default: 0] += 1 }
        let paths = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return projectName(lhs.key) == projectName(rhs.key) ? lhs.key < rhs.key
                : projectName(lhs.key) < projectName(rhs.key)
        }.map(\.key)
        let sidebar = paths.filter { !isProjectArchived($0) }.map(projectName)
        let archive = paths.filter(isProjectArchived).map(projectName)
        var places: [String] = []
        if !sidebar.isEmpty { places.append("in the sidebar under \(projectList(sidebar))") }
        if !archive.isEmpty {
            places.append("in the archive under \(projectList(archive)), which \(archive.count == 1 ? "is" : "are") archived")
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
        let sessions = request.sessions.filter { !isInTemple($0.id) }
        guard !sessions.isEmpty else { return }
        let entries = await overlay.prepareImports(sessions)
        finishImport(entries, sessions: sessions, undoManager: undoManager)
    }

    private func finishImport(_ prepared: [PreparedSessionImport], sessions: [AgentSession], undoManager: UndoManager?) {
        // A session may have been opened or imported while parsing was in flight.
        let entries = prepared.filter { !overlay.isTempleSession($0.id) }
        let ids = Set(entries.map(\.id))
        let sessions = sessions.filter { ids.contains($0.id) }
        guard !sessions.isEmpty else { return }
        let failures = overlay.importPreparedSessions(entries)
        let imported = sessions.map(\.id).filter { failures[$0] == nil }
        refreshJoinedStates()
        clearSelection()
        if !imported.isEmpty {
            markJustImported(imported)
            showNotice(Notice(text: imported.count == 1 ? "1 session imported" : "\(imported.count) sessions imported",
                              offersUndo: undoManager != nil))
            registerUndo(undoManager, imported: imported, sessions: sessions, entries: entries)
        }
        if !failures.isEmpty {
            let failedTitles = sessions.filter { failures[$0.id] != nil }.map(overlay.displayTitle(for:))
            let errors = Set(failures.values.map { $0.localizedDescription }).sorted()
            var lines = errors + [failedTitles.joined(separator: " · ")]
            if !imported.isEmpty {
                lines.append(imported.count == 1 ? "The other one was imported." : "The other \(imported.count) were imported.")
            }
            importFailure = ImportFailure(
                title: "Couldn't import \(failures.count) of \(sessions.count) sessions",
                message: lines.joined(separator: "\n"))
        }
        invalidate()
    }

    /// Undo removes exactly the rows this import wrote, and only while each is
    /// still an untouched import not running in a tab (`TempleDB.leave`).
    /// Redo imports what the undo removed. The pair re-registers itself, so
    /// ⌘Z / ⌘⇧Z bounce as often as the user likes.
    private func registerUndo(_ undoManager: UndoManager?, imported ids: [String], sessions: [AgentSession], entries: [PreparedSessionImport]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                let left = model.undoImport(ids)
                guard let undoManager, !left.isEmpty else { return }
                let back = sessions.filter { left.contains($0.id) }
                undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
                    MainActor.assumeIsolated {
                        // Redo must register its inverse synchronously inside UndoManager's
                        // callback. Reuse the facts captured by the original import.
                        model.finishImport(entries.filter { left.contains($0.id) },
                                           sessions: back, undoManager: undoManager)
                    }
                }
                undoManager.setActionName("Import")
            }
        }
        undoManager.setActionName("Import")
    }

    /// Returns the ids that left Temple. A committed leave tells the live
    /// engine itself (`TempleDB.observeLeaves`); nothing to re-read here.
    @discardableResult
    func undoImport(_ ids: [String]) -> [String] {
        let open = Set(ids.filter { hasOpenTab($0) })
        let candidates = ids.filter { !open.contains($0) }
        let left = overlay.leave(candidates)
        refreshJoinedStates()
        justImported.subtract(left)
        showNotice(Notice(text: Self.undoNotice(total: ids.count, left: left.count,
                                                open: open.count, changed: candidates.count - left.count),
                          offersUndo: false))
        invalidate()
        return left
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

    private func refreshJoinedStates() {
        joinedByID = Dictionary(currentMembers.map { ($0.id, $0.state) },
                                uniquingKeysWith: { first, _ in first })
    }

    private func markJustImported(_ ids: [String]) {
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
