import Foundation
import Combine
import TempleCore

/// Why a join was refused: the id is already Temple's on another host, or
/// already names another agent (`TempleDB.join`).
public enum JoinConflict: Equatable, Sendable {
    case host(HostID)
    case agent(Agent)

    public var message: String {
        switch self {
        case .host(let host): "Already in Temple on \(host.displayName)."
        case .agent(let agent): "Already in Temple as a \(agent.displayName) session."
        }
    }
}

/// What a join did. A refusal wrote nothing; a failure is a write that did
/// not happen (membership follows the row, so nothing pretends it joined).
public enum JoinResult {
    case joined
    case refused(JoinConflict)
    case failed(Error)

    public var isJoined: Bool { if case .joined = self { true } else { false } }
    public var conflict: JoinConflict? { if case .refused(let conflict) = self { conflict } else { nil } }
}

/// App-state overlay the CLIs don't track: pins, custom names, color marks,
/// archive state, and the manual project order (ADR-009).
///
/// The rows are the session: every per-session answer here (membership,
/// pin, name, color, archive, title, activity) is read from `rows`, which
/// the DB's committed-row observer keeps current. Only project state, which
/// no row backs, is held beside them.
@MainActor
public final class SessionOverlayStore: ObservableObject {
    /// Full durable row state, including immediate in-memory activity.
    /// Exactly the sessions that are Temple's: each write below joins its
    /// session first, and at the default session scope these are the only
    /// ones anything lists.
    ///
    /// Not `@Published`: every working agent touches its row about once a
    /// second, and a publish per touch re-rendered everything observing the
    /// store. Any other change announces itself with `objectWillChange`;
    /// every change, activity included, is on `rowChanges`.
    public private(set) var rows: [String: SessionState]
    /// Emitted after a row changes, without making subscribers diff the whole store.
    /// `recencyOnly`: nothing but `lastActiveAt` moved (no `objectWillChange`).
    struct RowChange { let id: String; let recencyOnly: Bool }
    let rowChanges = PassthroughSubject<RowChange, Never>()
    private var rowObserver: UUID?

    /// Archived projects: hidden from every browse surface, found again only
    /// in the ⌘⇧Y archive browser. (An archived session is its row's flag.)
    @Published public private(set) var archivedProjectKeys: Set<ProjectKey>
    /// The sidebar order the user arranged, outermost first. Only projects the
    /// user has actually placed appear here; everything else stays on the
    /// launch-frozen recency order.
    @Published public private(set) var projectKeyOrder: [ProjectKey]

    private let now: () -> Date
    /// A cancellable one-shot scheduler; tests advance it without wall-clock waits.
    private let scheduleTouch: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var pendingTouches: [String: Date] = [:]
    private var touchHosts: [String: HostID] = [:]
    private var touchTimers: [String: () -> Void] = [:]
    private let db: TempleDB
    /// Transcript facts from the engine: persisted only while the latest
    /// snapshot still authorizes them (`FactCommitter`).
    private let facts: FactCommitter
    private let scheduleFactRetry: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var factRetry: (() -> Void)?
    private var factRetryDue: Date?
    private var latestFacts: [String: AuthorizedFacts] = [:]
    /// A fact write found its row gone, rejoined or on another host: the
    /// owning engine is asked to re-read it (AppModel wires this).
    var onOwnershipMismatch: ((_ id: String, _ host: HostID) -> Void)?

    public init(db: TempleDB, now: @escaping () -> Date = Date.init,
                scheduleTouch: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = SessionOverlayStore.schedule,
                persistFacts: FactCommitter.Persist? = nil,
                scheduleFactRetry: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = SessionOverlayStore.schedule) {
        self.now = now
        self.scheduleTouch = scheduleTouch
        self.db = db
        let persister = FactPersister(database: db)
        self.facts = FactCommitter(persist: persistFacts ?? { try persister.persist($0, $1) }, now: now)
        self.scheduleFactRetry = scheduleFactRetry
        let states = (try? db.sessionStates()) ?? []
        self.rows = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        // project_state is this Mac's (its host column is the deferred v13
        // migration), so every stored project is a local key.
        let projects = (try? db.projectStates()) ?? []
        self.archivedProjectKeys = Set(projects.lazy.filter(\.archived).map { ProjectKey(host: .local, path: $0.path) })
        self.projectKeyOrder = projects
            .compactMap { state in state.position.map { ($0, state.path) } }
            .sorted { $0.0 < $1.0 }
            .map { ProjectKey(host: .local, path: $0.1) }
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
    }

    /// A cancellable one-shot main-actor timer.
    public nonisolated static func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    deinit {
        if let rowObserver { db.removeRowChangeObserver(rowObserver) }
    }

    private func refreshRow(_ id: String) {
        do {
            if var row = try db.sessionState(id) {
                if let pending = pendingTouches[id] {
                    row.lastActiveAt = max(row.lastActiveAt ?? .distantPast, pending)
                }
                if rows[id] != row {
                    var previous = rows[id]
                    previous?.lastActiveAt = row.lastActiveAt
                    let recencyOnly = previous == row
                    if !recencyOnly { objectWillChange.send() }
                    rows[id] = row
                    rowChanges.send(RowChange(id: id, recencyOnly: recencyOnly))
                }
            } else if rows[id] != nil {
                objectWillChange.send()
                rows.removeValue(forKey: id)
                rowChanges.send(RowChange(id: id, recencyOnly: false))
            }
        } catch {
            TempleUILog.db.error("row refresh failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Engine facts

    /// The latest merged snapshot's authorized facts, whole: each newly
    /// authorized entry is persisted once (NULL-only fill and hint, under
    /// the row's host and incarnation); a failed write is retried with
    /// backoff while the snapshot still carries the same authorization, and
    /// dropped the moment one does not.
    public func applyFacts(_ latest: [String: AuthorizedFacts]) {
        latestFacts = latest
        handle(facts.receive(latest))
        rescheduleFactRetry()
    }

    private func retryFacts() {
        factRetry = nil; factRetryDue = nil
        handle(facts.retryDue())
        rescheduleFactRetry()
    }

    private func handle(_ outcomes: [FactCommitter.Outcome]) {
        for outcome in outcomes {
            switch outcome {
            case .written(let id, .changed):
                // Changed rows refresh synchronously through the committed observer.
                _ = id
            case .written(let id, .unchanged):
                // Another writer may already have filled it.
                refreshRow(id)
            case .written(let id, .ownershipMismatch):
                refreshRow(id)
                if let host = latestFactHost(id) { onOwnershipMismatch?(id, host) }
            case .failed(let id, let error):
                TempleUILog.db.error("core fill failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func latestFactHost(_ id: String) -> HostID? { latestFacts[id]?.locator.host }

    private func rescheduleFactRetry() {
        guard let due = facts.nextRetry else {
            factRetry?(); factRetry = nil; factRetryDue = nil
            return
        }
        if let factRetryDue, factRetryDue <= due, factRetry != nil { return }
        factRetry?()
        factRetryDue = due
        factRetry = scheduleFactRetry(max(0, due.timeIntervalSince(now()))) { [weak self] in self?.retryFacts() }
    }

    /// Fact writes waiting out a backoff (diagnostic, for tests).
    var pendingFactIDs: Set<String> { facts.pendingIDs }

    public convenience init() throws {
        self.init(db: try AppDatabase.open())
    }

    public func isPinned(_ id: String) -> Bool { rows[id]?.pinned == true }

    /// Membership is the row: one answer, from one place.
    public func isTempleSession(_ id: String) -> Bool { rows[id] != nil }

    /// A member whose row this host owns.
    private func isMember(_ id: String, on host: HostID) -> Bool { rows[id]?.host == host }

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
    ///
    /// A row already owned by another host, or naming another agent, is
    /// refused: nothing is written and the session is not counted Temple's
    /// here (`TempleDB.join`).
    @discardableResult
    public func join(_ id: String, via: JoinedVia, agent: Agent? = nil, locator: TranscriptLocator? = nil,
                     core: SessionCore = SessionCore()) -> JoinResult {
        do {
            try db.join(sessionID: id, via: via, agent: agent, locator: locator, core: core)
            // A join that wrote reached `rows` through the observer already;
            // one that found the row there (another connection inserted it
            // since this store last read) wrote nothing and notified nobody.
            // Either way the row is Temple's now, so read it.
            refreshRow(id)
            return .joined
        } catch TempleDBError.hostConflict(let host) {
            TempleUILog.db.notice("join refused for session \(id, privacy: .public): owned by host \(host.rawValue, privacy: .public)")
            return .refused(.host(host))
        } catch TempleDBError.agentConflict(let existing) {
            TempleUILog.db.notice("join refused for session \(id, privacy: .public): row is \(existing.rawValue, privacy: .public)")
            return .refused(.agent(existing))
        } catch {
            TempleUILog.db.error("join failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(error)
        }
    }

    /// A setter's join: the row's own host for a member, this Mac otherwise.
    private func joinForSetter(_ id: String) -> Bool {
        join(id, via: .imported, core: SessionCore(host: rows[id]?.host ?? .local)).isJoined
    }

    // MARK: Import (the History tab)

    /// What one import came to, in the order the sessions were given.
    enum ImportOutcome {
        /// With the membership's incarnation, so an undo names exactly it.
        case joined(incarnation: String?)
        /// Already Temple's on its host before this import: left as it is.
        case skipped
        case failed(Error)
    }

    /// Bring catalog sessions in without running them: one `.imported` join
    /// each, with its transcript as the engine's hint and the catalog row's
    /// own facts committed at join (NULL-only, transcript-sourced), through
    /// the same committed join every other way in uses. The engine verifies
    /// and enriches the member after it joins, like any other; there is no
    /// second parse in between. Not retried (ADR-023): a failed session
    /// simply stays out, and says why.
    ///
    /// One outcome per session. Two entries for one id (two hosts, or two
    /// agents, listing it) are each attempted: the first joins, and the DB
    /// refuses the second with its reason (`hostConflict`/`agentConflict`)
    /// — never a silent skip that a caller would count as imported.
    func `import`(_ sessions: [TranscriptSummary]) -> [ImportOutcome] {
        guard !Task.isCancelled else { return sessions.map { _ in .failed(CancellationError()) } }
        // Membership as it stood before this import: an entry joined earlier
        // in the batch does not make a later one for the same id a skip.
        let before = rows
        var joined: Set<String> = []
        return sessions.map { summary in
            // Another host's member is attempted, so its refusal is reported
            // rather than the import silently skipping it.
            guard before[summary.id]?.host != summary.locator.host else { return .skipped }
            do {
                let incarnation = try db.join(sessionID: summary.id, via: .imported, agent: summary.agent,
                                              locator: summary.locator, core: SessionCore(filling: summary))
                // As in `join`: a no-op join still makes the row a member here.
                refreshRow(summary.id)
                // The same session twice in one batch joined once.
                guard joined.insert(summary.id).inserted else { return .skipped }
                return .joined(incarnation: incarnation)
            } catch {
                TempleUILog.db.error("import failed for session \(summary.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return .failed(error)
            }
        }
    }

    public func observeLaunchDirectory(_ id: String, host: HostID, _ directory: String) {
        guard isTempleSession(id) else { return }
        try? db.observeLaunchDirectory(sessionID: id, host: host, directory)
    }

    /// Immediate, monotonic publication; one fixed 30-second window per
    /// session. Only a row owned by `host` moves: a tab on another host
    /// holding the same id changes nothing.
    public func touch(_ id: String, host: HostID, at: Date? = nil) {
        guard var row = rows[id], row.host == host else { return }
        let event = at ?? now()
        let date = max(row.lastActiveAt ?? .distantPast, event)
        if row.lastActiveAt != date {
            row.lastActiveAt = date
            rows[id] = row
            rowChanges.send(RowChange(id: id, recencyOnly: true))
        }
        // The write gets when the activity happened, not the presented date:
        // the database keeps its own date monotonic, and a keep is spent
        // only by activity after the restore (ADR-030), which a stored
        // future date must not fake.
        pendingTouches[id] = max(pendingTouches[id] ?? .distantPast, event)
        touchHosts[id] = host
        guard touchTimers[id] == nil else { return }
        touchTimers[id] = scheduleTouch(30) { [weak self] in self?.flushTouch(id) }
    }

    private func flushTouch(_ id: String) {
        touchTimers.removeValue(forKey: id)?()
        let host = touchHosts.removeValue(forKey: id) ?? .local
        guard let date = pendingTouches.removeValue(forKey: id) else { return }
        try? db.touch(sessionID: id, host: host, at: date)
    }

    public func flushPendingTouches() {
        for id in Array(pendingTouches.keys) { flushTouch(id) }
    }

    /// Undo of an import (`TempleDB.leave`): each row goes only if it is
    /// still an untouched import. Returns the ids that left; the rest stay
    /// Temple's, holding whatever was decided about them since.
    public func leave(_ keys: [SessionKey]) -> [String] {
        leave(keys.map { ImportedMembership(key: $0, agent: nil, incarnation: nil) })
    }

    /// One import as History captured it: the row's id and host, and the
    /// agent and membership incarnation it joined with (nil: not checked).
    struct ImportedMembership: Hashable {
        let key: SessionKey
        let agent: Agent?
        let incarnation: String?
    }

    /// Undo of an import, narrowed to the membership that import made: a
    /// row that has since left and joined again — as another agent, or as
    /// the same file re-imported — is not the one undone.
    func leave(_ imports: [ImportedMembership]) -> [String] {
        let left = imports.filter { item in
            let key = item.key
            guard isTempleSession(key.id) else { return false }
            do {
                return try db.leave(sessionID: key.id, host: key.host, agent: item.agent, incarnation: item.incarnation)
            } catch {
                TempleUILog.db.error("leave failed for session \(key.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }.map(\.key.id)
        return left
    }

    /// A created session whose tab closed unused (see
    /// `TempleDB.discardUnstartedCreation`).
    @discardableResult
    public func discardUnstartedCreation(_ id: String, host: HostID) -> Bool {
        guard isTempleSession(id) else { return false }
        do {
            return try db.discardUnstartedCreation(sessionID: id, host: host)
        } catch {
            TempleUILog.db.error("discard failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The session was opened in a tab. Written for members only (it never
    /// joins one), so an import undone later can tell the session was used:
    /// `TempleDB.leave` keeps a row opened since.
    public func recordOpened(_ id: String, host: HostID, at date: Date = Date()) {
        guard isTempleSession(id) else { return }
        do {
            try db.recordOpened(sessionID: id, host: host, at: date)
        } catch {
            TempleUILog.db.error("recording the open failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // Each setter writes its column; the committed row is what every reader
    // then sees. A write that fails changes nothing on screen, rather than
    // showing a state that would vanish at the next launch.

    public func togglePin(_ id: String) {
        guard joinForSetter(id) else { return }
        try? db.setPinned(!isPinned(id), sessionID: id)
    }

    public func isArchived(_ id: String) -> Bool { rows[id]?.archived == true }

    /// Archiving drops the pin: a session cannot be both the one you always
    /// want in front of you and one you have put away. Unarchiving does not
    /// bring it back — the pin was a separate decision, and re-pinning is a
    /// click. The DB write clears the pin in the same statement.
    public func setArchived(_ archived: Bool, sessionID id: String) {
        guard joinForSetter(id) else { return }
        try? db.setArchived(archived, sessionID: id, at: now())
    }

    // MARK: Temple's archive (ADR-030)
    // Thin and unretried like every setter here: a failed write is logged
    // and changes nothing on screen; the next sweep plans it again.

    /// Archive rows nobody can resume any more. Returns the ids archived.
    func autoArchive(_ entries: [AutoArchiveEntry], idleBefore: Date) -> [String] {
        do {
            return try db.autoArchive(entries, idleBefore: idleBefore, at: now())
        } catch {
            TempleUILog.db.error("auto-archive failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The notice's Undo. Returns the ids restored.
    func restoreTempleArchives(_ refs: [MembershipRef]) -> [String] {
        do {
            return try db.restoreTempleArchives(refs, at: now())
        } catch {
            TempleUILog.db.error("restoring auto-archived sessions failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func isProjectArchived(_ key: ProjectKey) -> Bool { archivedProjectKeys.contains(key) }
    public func setProjectArchived(_ archived: Bool, key: ProjectKey) {
        if archived { archivedProjectKeys.insert(key) } else { archivedProjectKeys.remove(key) }
        // Project-state host persistence is the explicitly deferred v13 migration.
        if key.host.isLocal { try? db.setProjectArchived(archived, path: key.path) }
    }
    public func setProjectKeyOrder(_ keys: [ProjectKey]) {
        projectKeyOrder = keys
        try? db.setProjectOrder(keys.filter { $0.host.isLocal }.map(\.path))
    }

    public func customName(for id: String) -> String? { rows[id]?.customName }

    public func rename(_ id: String, to name: String) {
        guard joinForSetter(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? db.setCustomName(trimmed.isEmpty ? nil : trimmed, sessionID: id)
    }

    public func color(for id: String) -> String? { rows[id]?.color }

    public func setColor(_ name: String?, for id: String) {
        guard joinForSetter(id) else { return }
        try? db.setColor(name, sessionID: id)
    }

    /// The last title the agent gave itself. Claude and Codex retitle their
    /// terminal as the work moves on, but write that title nowhere on disk —
    /// so the row remembers it, and a session keeps the name it earned even
    /// after it is closed and the app restarts.
    public func generatedTitle(for id: String) -> String? { rows[id]?.generatedTitle }

    /// How long live retitles coalesce before one DB write (and so one row
    /// change). Every WORKING agent retitles about once a second; flushing
    /// per tick meant a full re-render plus a synchronous DB write per
    /// title, per agent.
    var titleFlushDelay: TimeInterval = 1.0
    /// Latest unflushed title per session (last one in a window wins).
    private var pendingGeneratedTitles: [String: String] = [:]
    private var titleHosts: [String: HostID] = [:]
    private var titleFlushTask: Task<Void, Never>?

    /// Record the agent's current self-assigned title. Cheap to call on every
    /// retitle: unchanged titles are dropped here, and changed ones batch into
    /// one flush per `titleFlushDelay` window.
    public func recordGeneratedTitle(_ title: String, for id: String, host: HostID = .local) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Compare against what the flush WOULD publish (pending first), not
        // just what is published: a title that returns to the published value
        // mid-window must clear the pending intermediate, or the flush would
        // regress to it ("Ready" → "Thinking" → "Ready" must stay "Ready").
        guard (pendingGeneratedTitles[id] ?? generatedTitle(for: id)) != trimmed else { return }
        if generatedTitle(for: id) == trimmed {
            pendingGeneratedTitles.removeValue(forKey: id)
            return
        }
        pendingGeneratedTitles[id] = trimmed
        titleHosts[id] = host
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
        for (id, title) in pendingGeneratedTitles where generatedTitle(for: id) != title {
            // A title never makes a session Temple's: it only follows a join.
            // Every way into a tab joins first, so a title for a session that
            // is not a member means that join failed; the title is dropped,
            // rather than writing a row that forgets how the session joined.
            guard isTempleSession(id) else { continue }
            try? db.setTitle(title, sessionID: id, host: titleHosts[id] ?? .local)
        }
        pendingGeneratedTitles.removeAll()
        titleHosts.removeAll()
    }

    /// Display title: a rename wins, then whatever the agent last called itself,
    /// then the title parsed from the session file (which is pinned to the first
    /// prompt and never catches up with a long session).
    public func displayTitle(for session: TranscriptSummary) -> String {
        customName(for: session.id) ?? generatedTitle(for: session.id) ?? session.catalogTitle
    }
}
