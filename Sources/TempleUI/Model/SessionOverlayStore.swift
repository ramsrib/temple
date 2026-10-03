import Foundation
import Combine
import TempleCore

struct PreparedSessionImport: Sendable {
    let id: String
    let agent: Agent
    let path: URL?
    let core: SessionCore
}

/// App-state overlay the CLIs don't track: pins, custom names, color marks,
/// archive state, and the manual project order (ADR-009).
///
/// Values are cached in memory for synchronous SwiftUI reads and written
/// through to TempleDB on mutation.
@MainActor
public final class SessionOverlayStore: ObservableObject {
    /// Full durable row state, including immediate in-memory activity.
    @Published public private(set) var rows: [String: SessionState]
    /// Emitted after a row changes, without making subscribers diff the whole store.
    struct RowChange { let id: String; let recencyOnly: Bool }
    let rowChanges = PassthroughSubject<RowChange, Never>()
    private var missingCoreFields: [String: Set<SessionCoreField>] = [:]
    private var rowObserver: UUID?

    @Published public private(set) var pinned: Set<String>
    @Published public private(set) var customNames: [String: String]
    @Published public private(set) var colors: [String: String]
    /// The last title each agent gave itself. Claude and Codex retitle their
    /// terminal as the work moves on, but write that title nowhere on disk — so
    /// Temple remembers it, and a session keeps the name it earned even after it
    /// is closed and the app restarts.
    @Published public private(set) var generatedTitles: [String: String]
    /// Archived sessions and projects: hidden from every browse surface, found
    /// again only in the ⌘⇧Y archive browser.
    @Published public private(set) var archivedSessions: Set<String>
    @Published public private(set) var archivedProjectKeys: Set<ProjectKey>
    public var archivedProjects: Set<String> { Set(archivedProjectKeys.filter { $0.host.isLocal }.map(\.path)) }
    /// Temple's sessions: every one it started, opened, or had pinned, renamed,
    /// colored or archived. Exactly the sessions with a row in the DB — each
    /// write below joins its session first — and, at the default session
    /// scope, the only ones anything lists.
    @Published public private(set) var templeSessions: Set<String>
    /// The sidebar order the user arranged, outermost first. Only projects the
    /// user has actually placed appear here; everything else stays on the
    /// launch-frozen recency order.
    @Published public private(set) var projectKeyOrder: [ProjectKey]
    public var projectOrder: [String] { projectKeyOrder.filter { $0.host.isLocal }.map(\.path) }

    @Published public private(set) var lastActiveAt: [String: Date]
    private let now: () -> Date
    /// A cancellable one-shot scheduler; tests advance it without wall-clock waits.
    private let scheduleTouch: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var pendingTouches: [String: Date] = [:]
    private var touchTimers: [String: () -> Void] = [:]
    private let db: TempleDB

    public init(db: TempleDB, now: @escaping () -> Date = Date.init,
                scheduleTouch: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, action in
                    let task = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled else { return }
                        action()
                    }
                    return { task.cancel() }
                }) {
        self.now = now
        self.scheduleTouch = scheduleTouch
        self.db = db
        let states = (try? db.sessionStates()) ?? []
        self.rows = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        self.lastActiveAt = Dictionary(uniqueKeysWithValues: states.compactMap { row in row.lastActiveAt.map { (row.id, $0) } })
        let projects = (try? db.projectStates()) ?? []
        self.pinned = Set(states.lazy.filter(\.pinned).map(\.id))
        self.archivedSessions = Set(states.lazy.filter(\.archived).map(\.id))
        self.templeSessions = Set(states.lazy.map(\.id))
        self.archivedProjectKeys = Set(projects.lazy.filter(\.archived).map { ProjectKey(host: .local, path: $0.path) })
        self.projectKeyOrder = projects
            .compactMap { state in state.position.map { ($0, state.path) } }
            .sorted { $0.0 < $1.0 }
            .map { ProjectKey(host: .local, path: $0.1) }
        self.customNames = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.customName.map { (state.id, $0) }
            }
        )
        self.colors = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.color.map { (state.id, $0) }
            }
        )
        self.generatedTitles = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.generatedTitle.map { (state.id, $0) }
            }
        )
        rowObserver = db.observeRowChanges { [weak self] id in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refreshRow(id) }
            } else {
                Task { @MainActor [weak self] in self?.refreshRow(id) }
            }
        }
        // Replay after registration so a concurrent commit cannot be lost.
        if let current = try? db.sessionStates() {
            rows = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        }
        for row in rows.values { trackMissingFields(row) }
    }

    deinit {
        if let rowObserver { db.removeRowChangeObserver(rowObserver) }
    }

    private func trackMissingFields(_ row: SessionState) {
        var missing: Set<SessionCoreField> = []
        if row.agent == nil { missing.insert(.agent) }
        if row.directory == nil { missing.insert(.directory) }
        if row.title == nil { missing.insert(.title) }
        if row.lastActiveAt == nil { missing.insert(.lastActiveAt) }
        missingCoreFields[row.id] = missing.isEmpty ? nil : missing
    }

    private func refreshRow(_ id: String) {
        do {
            if var row = try db.sessionState(id) {
                if let pending = pendingTouches[id] {
                    row.lastActiveAt = max(row.lastActiveAt ?? .distantPast, pending)
                }
                trackMissingFields(row)
                if lastActiveAt[id] != row.lastActiveAt { lastActiveAt[id] = row.lastActiveAt }
                if rows[id] != row {
                    var previous = rows[id]
                    previous?.lastActiveAt = row.lastActiveAt
                    let recencyOnly = previous == row
                    rows[id] = row
                    rowChanges.send(RowChange(id: id, recencyOnly: recencyOnly))
                }
            } else {
                missingCoreFields.removeValue(forKey: id)
                lastActiveAt.removeValue(forKey: id)
                if rows.removeValue(forKey: id) != nil {
                    rowChanges.send(RowChange(id: id, recencyOnly: false))
                }
            }
        } catch {
            TempleUILog.db.error("row refresh failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Only recorded facts fill NULL core fields; complete rows never hit SQLite.
    /// Partial rows also skip writes until a summary supplies a missing fact.
    public func fillMissingCoreFields(from summary: TranscriptSummary) {
        guard let row = rows[summary.id], row.host == summary.locator.host,
              let missing = missingCoreFields[summary.id] else { return }
        let supplied = Set<SessionCoreField>([.agent, .lastActiveAt])
            .union(summary.cwd == nil ? [] : [.directory])
            .union((summary.firstPrompt ?? summary.historyPrompt) == nil ? [] : [.title])
        guard !missing.isDisjoint(with: supplied) else { return }
        do {
            let changed = try db.fillCoreFields(sessionID: summary.id, expectedHost: summary.locator.host, agent: summary.agent,
                directory: summary.cwd, title: summary.firstPrompt ?? summary.historyPrompt, lastActiveAt: summary.modifiedAt)
            // Changed rows refresh synchronously through the committed observer.
            // Reconcile a no-op too: another writer may already have filled it.
            if changed.isEmpty { refreshRow(summary.id) }
        } catch {
            TempleUILog.db.error("core fill failed for session \(summary.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public convenience init() throws {
        self.init(db: try AppDatabase.open())
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public func isTempleSession(_ id: String) -> Bool { templeSessions.contains(id) }

    /// The session becomes Temple's, if it is not already. Called on every
    /// open; core facts fill only unknown fields. How it joined is recorded
    /// only by the first join (see `TempleDB`).
    ///
    /// Membership follows the row, not the attempt: a failed write leaves the
    /// id out, and whatever touches the session next joins it then. Returns
    /// whether the session is Temple's now; every setter below stops when it
    /// is not, because its own write would insert a row that says nothing
    /// about how the session joined, behind the set's back.
    ///
    /// A failed write is not retried — the same as every other write in this
    /// store (a pin, a name, a title). Local SQLite writes fail essentially
    /// never, and a retry ledger for them grew a new edge case per review
    /// round; what matters is that failure never shows the wrong sessions.
    @discardableResult
    public func join(_ id: String, via: JoinedVia, agent: Agent? = nil, transcriptPath: URL? = nil, core: SessionCore = SessionCore()) -> Bool {
        do {
            try db.join(sessionID: id, via: via, agent: agent, transcriptPath: transcriptPath, core: core)
            templeSessions.insert(id)
            return true
        } catch {
            TempleUILog.db.error("join failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Import (the History tab)

    /// Bring sessions in without running them: one `.imported` join each,
    /// with its transcript as the engine's hint, through the same committed
    /// join every other way in uses — so each loads into the live index at
    /// once. Membership publishes once for the whole batch, not per row. A
    /// session that is already Temple's keeps its row as it is. Returns the
    /// failures, keyed by id, with the error as thrown (ADR-023: not retried;
    /// a failed session simply stays out).
    public func importSessions(_ summaries: [TranscriptSummary]) -> [String: Error] {
        importCore(summaries.map { ($0.id, $0.agent, $0.locator.localURL,
            SessionCore(host: $0.locator.host, directory: $0.cwd,
                        directorySource: $0.cwd == nil ? nil : .transcript,
                        title: $0.firstPrompt ?? $0.historyPrompt, lastActiveAt: $0.modifiedAt)) })
    }

    /// P2 adapter while History holds AgentSession. Parsing is bounded to four
    /// workers and runs off-main; membership is checked again at commit time.
    var importSummaryReader: @Sendable (AgentSession) -> TranscriptSummary? = { session in
        session.agent == .claude
            ? ClaudeSessionStore().loadSummary(at: session.filePath)
            : CodexSessionStore().loadSummary(at: session.filePath)
    }

    func prepareImports(_ sessions: [AgentSession]) async -> [PreparedSessionImport] {
        let sessions = sessions.filter { !templeSessions.contains($0.id) }
        let read = importSummaryReader
        return await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (Int, PreparedSessionImport).self) { group in
                var next = 0
                var results: [Int: PreparedSessionImport] = [:]
                func enqueue(_ index: Int) {
                    let session = sessions[index]
                    group.addTask {
                        let summary = read(session)
                        let facts = summary?.id == session.id ? summary : nil
                        return (index, PreparedSessionImport(id: session.id, agent: session.agent,
                            path: session.filePath, core: SessionCore(directory: facts?.cwd,
                                directorySource: facts?.cwd == nil ? nil : .transcript,
                                title: facts?.firstPrompt ?? facts?.historyPrompt, lastActiveAt: facts?.modifiedAt)))
                    }
                }
                while next < min(4, sessions.count) { enqueue(next); next += 1 }
                while let (index, entry) = await group.next() {
                    results[index] = entry
                    if next < sessions.count { enqueue(next); next += 1 }
                }
                return sessions.indices.compactMap { results[$0] }
            }
        }.value
    }

    public func importSessions(_ sessions: [AgentSession]) async -> [String: Error] {
        let entries = await prepareImports(sessions)
        return importPreparedSessions(entries)
    }

    func importPreparedSessions(_ entries: [PreparedSessionImport]) -> [String: Error] {
        importCore(entries.map { ($0.id, $0.agent, $0.path, $0.core) })
    }

    private func importCore(_ entries: [(String, Agent, URL?, SessionCore)]) -> [String: Error] {
        var failures: [String: Error] = [:]
        var joined: Set<String> = []
        var activity = lastActiveAt
        for (id, agent, path, core) in entries where !templeSessions.contains(id) && !joined.contains(id) {
            do {
                try db.join(sessionID: id, via: .imported, agent: agent, transcriptPath: path, core: core)
                joined.insert(id)
                if let date = core.lastActiveAt { activity[id] = date }
            } catch {
                TempleUILog.db.error("import failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                failures[id] = error
            }
        }
        if !joined.isEmpty { templeSessions.formUnion(joined) }
        if activity != lastActiveAt { lastActiveAt = activity }
        return failures
    }

    public func observeLaunchDirectory(_ id: String, _ directory: String) {
        guard isTempleSession(id) else { return }
        try? db.observeLaunchDirectory(sessionID: id, directory)
    }

    /// Immediate, monotonic publication; one fixed 30-second window per session.
    public func touch(_ id: String, at: Date? = nil) {
        guard isTempleSession(id) else { return }
        let date = max(lastActiveAt[id] ?? .distantPast, at ?? now())
        if lastActiveAt[id] != date { lastActiveAt[id] = date }
        if var row = rows[id], row.lastActiveAt != date {
            row.lastActiveAt = date
            trackMissingFields(row)
            rows[id] = row
            rowChanges.send(RowChange(id: id, recencyOnly: true))
        }
        pendingTouches[id] = max(pendingTouches[id] ?? .distantPast, date)
        guard touchTimers[id] == nil else { return }
        touchTimers[id] = scheduleTouch(30) { [weak self] in self?.flushTouch(id) }
    }

    private func flushTouch(_ id: String) {
        touchTimers.removeValue(forKey: id)?()
        guard let date = pendingTouches.removeValue(forKey: id) else { return }
        try? db.touch(sessionID: id, at: date)
    }

    public func flushPendingTouches() {
        for id in Array(pendingTouches.keys) { flushTouch(id) }
    }

    /// Undo of an import (`TempleDB.leave`): each row goes only if it is
    /// still an untouched import. Returns the ids that left; the rest stay
    /// Temple's, holding whatever was decided about them since.
    public func leave(_ ids: [String]) -> [String] {
        let left = ids.filter { id in
            guard templeSessions.contains(id) else { return false }
            do {
                return try db.leave(sessionID: id)
            } catch {
                TempleUILog.db.error("leave failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }
        if !left.isEmpty { templeSessions.subtract(left) }
        return left
    }

    /// The session was opened in a tab. Written for members only (it never
    /// joins one), so an import undone later can tell the session was used:
    /// `TempleDB.leave` keeps a row opened since.
    public func recordOpened(_ id: String, at date: Date = Date()) {
        guard isTempleSession(id) else { return }
        do {
            try db.recordOpened(sessionID: id, at: date)
        } catch {
            TempleUILog.db.error("recording the open failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public func togglePin(_ id: String) {
        guard join(id, via: .imported) else { return }
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        try? db.setPinned(pinned.contains(id), sessionID: id)
    }

    public func isArchived(_ id: String) -> Bool { archivedSessions.contains(id) }

    /// Archiving drops the pin: a session cannot be both the one you always
    /// want in front of you and one you have put away. Unarchiving does not
    /// bring it back — the pin was a separate decision, and re-pinning is a
    /// click. The DB write clears the pin in the same statement.
    public func setArchived(_ archived: Bool, sessionID id: String) {
        guard join(id, via: .imported) else { return }
        if archived {
            archivedSessions.insert(id)
            pinned.remove(id)
        } else {
            archivedSessions.remove(id)
        }
        try? db.setArchived(archived, sessionID: id)
    }

    public func isProjectArchived(_ key: ProjectKey) -> Bool { archivedProjectKeys.contains(key) }
    public func isProjectArchived(_ path: String) -> Bool { isProjectArchived(ProjectKey(host: .local, path: path)) }
    public func setProjectArchived(_ archived: Bool, key: ProjectKey) {
        if archived { archivedProjectKeys.insert(key) } else { archivedProjectKeys.remove(key) }
        // Project-state host persistence is the explicitly deferred v11 migration.
        if key.host.isLocal { try? db.setProjectArchived(archived, path: key.path) }
    }
    public func setProjectArchived(_ archived: Bool, path: String) { setProjectArchived(archived, key: ProjectKey(host: .local, path: path)) }
    public func setProjectKeyOrder(_ keys: [ProjectKey]) {
        projectKeyOrder = keys
        try? db.setProjectOrder(keys.filter { $0.host.isLocal }.map(\.path))
    }
    public func setProjectOrder(_ paths: [String]) { setProjectKeyOrder(paths.map { ProjectKey(host: .local, path: $0) }) }

    public func customName(for id: String) -> String? { customNames[id] }

    public func rename(_ id: String, to name: String) {
        guard join(id, via: .imported) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: id)
        } else {
            customNames[id] = trimmed
        }
        try? db.setCustomName(customNames[id], sessionID: id)
    }

    public func color(for id: String) -> String? { colors[id] }

    public func setColor(_ name: String?, for id: String) {
        guard join(id, via: .imported) else { return }
        if let name {
            colors[id] = name
        } else {
            colors.removeValue(forKey: id)
        }
        try? db.setColor(colors[id], sessionID: id)
    }

    public func generatedTitle(for id: String) -> String? { generatedTitles[id] }

    /// How long live retitles coalesce before one publish + DB write. Every
    /// WORKING agent retitles about once a second, and `generatedTitles` is
    /// @Published on a store the whole app observes — flushing per tick meant
    /// a full re-render plus a synchronous DB write per title, per agent.
    var titleFlushDelay: TimeInterval = 1.0
    /// Latest unflushed title per session (last one in a window wins).
    private var pendingGeneratedTitles: [String: String] = [:]
    private var titleFlushTask: Task<Void, Never>?

    /// Record the agent's current self-assigned title. Cheap to call on every
    /// retitle: unchanged titles are dropped here, and changed ones batch into
    /// one flush per `titleFlushDelay` window.
    public func recordGeneratedTitle(_ title: String, for id: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Compare against what the flush WOULD publish (pending first), not
        // just what is published: a title that returns to the published value
        // mid-window must clear the pending intermediate, or the flush would
        // regress to it ("Ready" → "Thinking" → "Ready" must stay "Ready").
        guard (pendingGeneratedTitles[id] ?? generatedTitles[id]) != trimmed else { return }
        if generatedTitles[id] == trimmed {
            pendingGeneratedTitles.removeValue(forKey: id)
            return
        }
        pendingGeneratedTitles[id] = trimmed
        guard titleFlushTask == nil else { return }
        titleFlushTask = Task { [weak self] in
            if let delay = self?.titleFlushDelay, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // A cancelled task must not fire a second, early flush after
            // `flushPendingTitles()` already ran it.
            guard !Task.isCancelled else { return }
            self?.flushGeneratedTitles()
        }
    }

    /// Quit paths call this so the last title an agent gave itself survives
    /// the coalescing window — losing it is losing the one thing this store
    /// exists to keep.
    public func flushPendingTitles() {
        titleFlushTask?.cancel()
        flushGeneratedTitles()
    }

    private func flushGeneratedTitles() {
        titleFlushTask = nil
        for (id, title) in pendingGeneratedTitles where generatedTitles[id] != title {
            generatedTitles[id] = title
            // A title never makes a session Temple's: it only follows a join.
            // Every way into a tab joins first, so a title for a session that
            // is not a member means that join failed; the title is shown but
            // not written, rather than writing a row that forgets how the
            // session joined.
            guard isTempleSession(id) else { continue }
            try? db.setTitle(title, sessionID: id)
        }
        pendingGeneratedTitles.removeAll()
    }

    /// Display title: a rename wins, then whatever the agent last called itself,
    /// then the title parsed from the session file (which is pinned to the first
    /// prompt and never catches up with a long session).
    public func displayTitle(for session: AgentSession) -> String {
        customName(for: session.id) ?? generatedTitle(for: session.id) ?? session.title
    }

    /// session id → the displayed title, for search (same precedence as
    /// `displayTitle(for:)`): a session must be findable under the name the
    /// list shows, not only under the file title nobody sees anymore.
    public var displayTitleOverrides: [String: String] {
        generatedTitles.merging(customNames) { _, custom in custom }
    }
}
