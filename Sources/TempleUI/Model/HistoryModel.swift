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

    // MARK: Dependencies

    private let overlay: SessionOverlayStore
    private let pathExists: (String) -> Bool
    private let now: () -> Date
    /// The full-disk read. Replaceable so tests feed events by hand.
    var catalog: () -> AsyncStream<SessionCatalog.Event>
    /// How each Temple session joined, for the gate mark's tooltip.
    var memberStates: () -> [SessionState] = { [] }
    /// Open (or focus) a session in a tab. Opening an outside session joins it
    /// as `opened` on the way (ADR-023).
    var openSession: (AgentSession) -> Void = { _ in }
    /// Whether a session runs in an open tab: undoing its import must not
    /// pull it out from under that tab.
    var hasOpenTab: (String) -> Bool = { _ in false }
    /// Membership shrank (an import was undone): the live engine re-reads it.
    var onMembershipShrunk: () -> Void = {}

    // MARK: Snapshot

    /// The disk as last read: deduped by id, first (newest) file wins.
    private var diskByID: [String: AgentSession] = [:]
    /// Temple's own copies from the live index — fresher titles and times.
    private var liveByID: [String: AgentSession] = [:]
    private var joinedByID: [String: SessionState] = [:]

    @Published public private(set) var readState: ReadState = .idle
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var storeFailures: [StoreFailure] = []

    /// Every non-noise session on disk, newest first.
    @Published public private(set) var allRows: [AgentSession] = []
    /// `allRows` through search and filters, in the same order.
    @Published public private(set) var visibleRows: [AgentSession] = []
    @Published public private(set) var groups: [HistoryDayGroup] = []
    @Published public private(set) var inTempleCount = 0
    @Published public private(set) var agentCounts: [Agent: Int] = [:]
    /// Projects for the popup, by session count, most first.
    @Published public private(set) var projects: [(path: String, count: Int)] = []

    // MARK: View state

    /// The applied search (the field debounces into it).
    @Published public var query = "" { didSet { if query != oldValue { filtersChanged() } } }
    @Published public var scope: HistoryScope = .all { didSet { if scope != oldValue { filtersChanged() } } }
    @Published public var agentFilter: Agent? { didSet { if agentFilter != oldValue { filtersChanged() } } }
    @Published public var projectFilter: String? { didSet { if projectFilter != oldValue { filtersChanged() } } }

    @Published public private(set) var selection: Set<String> = []
    /// The row the keyboard is on: arrows move from it, ⇧ extends to it.
    @Published public private(set) var cursorID: String?
    /// Where a ⇧-extension is measured from.
    private var anchorID: String?
    /// Bumped when the list should bring the cursor into view.
    @Published public private(set) var scrollRequest = 0
    /// Bumped by ⌘F: the view moves keyboard focus into the search field.
    @Published public private(set) var focusSearchRequest = 0

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
    private var rebuildScheduled = false
    private var cancellables: Set<AnyCancellable> = []

    var noticeDuration: TimeInterval = 4
    var importedDuration: TimeInterval = 2

    init(overlay: SessionOverlayStore,
         catalog: @escaping () -> AsyncStream<SessionCatalog.Event> = { SessionCatalog().stream() },
         pathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
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

    /// The live index changed: Temple's own rows take its copies.
    func liveIndexChanged(_ index: SessionIndex) {
        liveByID = Dictionary(index.allSessions.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        scheduleRebuild()
    }

    // MARK: Lifecycle

    /// The tab came on screen (opened, or switched back to): take a fresh
    /// snapshot. Rows already on the page stay while it reads.
    public func activate() {
        if selection.isEmpty { wantsInitialSelection = true }
        refresh()
    }

    /// The tab left the screen: stop reading for nobody.
    public func deactivate() {
        guard readTask != nil else { return }
        readTask?.cancel()
        readTask = nil
        if case .reading = readState { readState = lastUpdated == nil ? .idle : .done }
    }

    /// The tab closed: its view state goes with it.
    public func reset() {
        deactivate()
        diskByID = [:]
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
        query = ""; scope = .all; agentFilter = nil; projectFilter = nil
        rebuild()
    }

    /// ⌘R, and every activation. A read already running is replaced.
    public func refresh() {
        readTask?.cancel()
        readState = .reading(read: 0, total: nil)
        let stream = catalog()
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
                    for session in batch where seen.insert(session.id).inserted {
                        let isNoise = SessionFilter.isNoise(session) { path in
                            if let hit = exists[path] { return hit }
                            let result = self.pathExists(path)
                            exists[path] = result
                            return result
                        }
                        self.diskByID[session.id] = isNoise ? nil : session
                    }
                    self.readState = .reading(read: read, total: total)
                    self.rebuild()
                }
            }
            guard let self, !Task.isCancelled else { return }
            // Gone from disk since the last read: drop it now the read is whole.
            self.diskByID = self.diskByID.filter { seen.contains($0.key) }
            self.storeFailures = failures
            self.joinedByID = Dictionary(self.memberStates().map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
            self.lastUpdated = self.now()
            self.readState = .done
            self.readTask = nil
            self.rebuild()
        }
    }

    // MARK: Derived

    public func isInTemple(_ id: String) -> Bool { overlay.isTempleSession(id) }

    /// In Temple and put away (the session, or its whole project).
    public func isArchived(_ session: AgentSession) -> Bool {
        isInTemple(session.id)
            && (overlay.isArchived(session.id) || overlay.isProjectArchived(session.projectPath))
    }

    public func joinedState(_ id: String) -> SessionState? { joinedByID[id] }

    /// Search or a filter is narrowing the page ("Showing 47 of 3,810").
    public var isNarrowed: Bool {
        !normalizedQuery.isEmpty || scope != .all || agentFilter != nil || projectFilter != nil
    }

    public var isReading: Bool {
        if case .reading = readState { return true }
        return false
    }

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // objectWillChange fires BEFORE the change lands: rebuild a turn later.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                self.rebuild()
            }
        }
    }

    /// Recompute every derived list from the snapshot. A few thousand structs:
    /// cheap, and never run from a view body.
    func rebuild() {
        let temple = overlay.templeSessions
        var rows = diskByID.values.map { disk -> AgentSession in
            temple.contains(disk.id) ? (liveByID[disk.id] ?? disk) : disk
        }
        rows.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        allRows = rows
        inTempleCount = rows.reduce(0) { $0 + (temple.contains($1.id) ? 1 : 0) }
        var agents: [Agent: Int] = [:]
        var projectCounts: [String: Int] = [:]
        for row in rows {
            agents[row.agent, default: 0] += 1
            projectCounts[row.projectPath, default: 0] += 1
        }
        agentCounts = agents
        projects = projectCounts
            .map { (path: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.path < $1.path : $0.count > $1.count }

        let needle = normalizedQuery
        let overrides = needle.isEmpty ? [:] : overlay.displayTitleOverrides
        let visible = rows.filter { session in
            switch scope {
            case .all: break
            case .inTemple: if !temple.contains(session.id) { return false }
            case .notInTemple: if temple.contains(session.id) { return false }
            }
            if let agentFilter, session.agent != agentFilter { return false }
            if let projectFilter, session.projectPath != projectFilter { return false }
            return needle.isEmpty || Self.matches(session, needle, override: overrides[session.id])
        }
        visibleRows = visible
        groups = HistoryGrouping.groups(visible, now: now())

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

    /// Case-insensitive substring over everything the row shows or hides in
    /// its tooltip, plus an id prefix (a pasted id from a log finds its row).
    /// No ranking: order is chronology.
    static func matches(_ session: AgentSession, _ needle: String, override: String?) -> Bool {
        if session.title.localizedCaseInsensitiveContains(needle) { return true }
        if let override, override.localizedCaseInsensitiveContains(needle) { return true }
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
        rebuild()
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
    public var selectedRows: [AgentSession] {
        visibleRows.filter { selection.contains($0.id) }
    }

    /// What the bulk Import would bring in.
    public var selectedOutsideRows: [AgentSession] {
        selectedRows.filter { !isInTemple($0.id) }
    }

    /// Esc: clear search → clear selection → leave (the caller goes back to
    /// the previous tab; History stays open).
    public func escape() -> EscapeOutcome {
        if !query.isEmpty {
            query = ""
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
        guard selection.count == 1, let id = selection.first,
              let session = visibleRows.first(where: { $0.id == id }) else { return }
        openSession(session)
    }

    public func open(_ session: AgentSession) {
        openSession(session)
    }

    public func showOnly(project path: String) {
        projectFilter = path
    }

    // MARK: Import

    /// ⌘I, the bar's Import, a row's Import: ask first. Rows already in
    /// Temple are left out of the count and the copy; nothing to import, no
    /// sheet.
    public func requestImport(_ sessions: [AgentSession]? = nil) {
        let candidates = (sessions ?? selectedRows).filter { !isInTemple($0.id) }
        guard !candidates.isEmpty else { return }
        pendingImport = Self.importRequest(for: candidates)
    }

    public func cancelImport() { pendingImport = nil }

    static func importRequest(for sessions: [AgentSession]) -> ImportRequest {
        if sessions.count == 1, let session = sessions.first {
            let name = projectName(session.projectPath)
            return ImportRequest(
                sessions: sessions,
                title: "Import “\(session.title)” into Temple?",
                message: "It will appear in the sidebar under \(name). Nothing runs until you open it, and the session file on disk is not changed.",
                confirmLabel: "Import")
        }
        var counts: [String: Int] = [:]
        for session in sessions { counts[projectName(session.projectPath), default: 0] += 1 }
        let names = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        return ImportRequest(
            sessions: sessions,
            title: "Import \(sessions.count) sessions into Temple?",
            message: "They will appear in the sidebar under \(projectList(names)). Nothing runs until you open one, and the session files on disk are not changed.",
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
    public func confirmImport(_ request: ImportRequest? = nil, undoManager: UndoManager?) {
        guard let request = request ?? pendingImport else { return }
        pendingImport = nil
        let sessions = request.sessions.filter { !isInTemple($0.id) }
        guard !sessions.isEmpty else { return }
        let failures = overlay.importSessions(sessions)
        let imported = sessions.map(\.id).filter { failures[$0] == nil }
        refreshJoinedStates()
        clearSelection()
        if !imported.isEmpty {
            markJustImported(imported)
            showNotice(Notice(text: imported.count == 1 ? "1 session imported" : "\(imported.count) sessions imported",
                              offersUndo: undoManager != nil))
            registerUndo(undoManager, imported: imported, sessions: sessions)
        }
        if !failures.isEmpty {
            let failedTitles = sessions.filter { failures[$0.id] != nil }.map(\.title)
            let errors = Set(failures.values.map { $0.localizedDescription }).sorted()
            var lines = errors + [failedTitles.joined(separator: " · ")]
            if !imported.isEmpty {
                lines.append(imported.count == 1 ? "The other one was imported." : "The other \(imported.count) were imported.")
            }
            importFailure = ImportFailure(
                title: "Couldn't import \(failures.count) of \(sessions.count) sessions",
                message: lines.joined(separator: "\n"))
        }
        rebuild()
    }

    /// Undo removes exactly the rows this import wrote, and only while each is
    /// still an untouched import not running in a tab (`TempleDB.leave`).
    /// Redo imports what the undo removed. The pair re-registers itself, so
    /// ⌘Z / ⌘⇧Z bounce as often as the user likes.
    private func registerUndo(_ undoManager: UndoManager?, imported ids: [String], sessions: [AgentSession]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            MainActor.assumeIsolated {
                let left = model.undoImport(ids)
                guard let undoManager, !left.isEmpty else { return }
                let back = sessions.filter { left.contains($0.id) }
                undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
                    MainActor.assumeIsolated {
                        model.confirmImport(HistoryModel.importRequest(for: back), undoManager: undoManager)
                    }
                }
                undoManager.setActionName("Import")
            }
        }
        undoManager.setActionName("Import")
    }

    /// Returns the ids that left Temple.
    @discardableResult
    func undoImport(_ ids: [String]) -> [String] {
        let candidates = ids.filter { !hasOpenTab($0) }
        let left = overlay.leave(candidates)
        if !left.isEmpty { onMembershipShrunk() }
        refreshJoinedStates()
        justImported.subtract(left)
        let kept = ids.count - left.count
        let text: String
        if kept == 0 {
            text = left.count == 1 ? "Import undone" : "\(left.count) imports undone"
        } else {
            text = "\(left.count) of \(ids.count) imports undone · \(kept) changed since, kept"
        }
        showNotice(Notice(text: text, offersUndo: false))
        rebuild()
        return left
    }

    private func refreshJoinedStates() {
        joinedByID = Dictionary(memberStates().map { ($0.id, $0) },
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
