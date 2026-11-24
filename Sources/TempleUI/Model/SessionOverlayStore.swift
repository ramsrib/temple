import Foundation
import Combine
import TempleCore

/// Why a join was refused: the id is already Temple's on another host, or
/// already names another agent (`TempleDB.join`).
public enum JoinConflict: Equatable, Sendable {
    /// The session is Temple's on this host as the other agent's.
    case agent(Agent)
    /// The session is Temple's on this host with no agent recorded, and
    /// both agents have a session with this id there: which one it is
    /// can't be told.
    case agentUnknown

    public var message: String {
        switch self {
        case .agent(let agent): "Already in Temple as a \(agent.displayName) session."
        case .agentUnknown: "Already in Temple with no agent recorded, and more than one agent has a session with this ID."
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
    /// Why a launch must not go ahead: a conflict, or a join whose write
    /// failed. Nothing runs that Temple could not record as its session.
    public var launchRefusal: String? {
        switch self {
        case .joined: nil
        case .refused(let conflict): conflict.message
        case .failed(let error): "Temple couldn't record this session: \(error.localizedDescription)"
        }
    }
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
    /// Keyed by session: the same id on two hosts is two rows (ADR-041).
    public private(set) var rows: [SessionKey: SessionState]
    /// Emitted after a row changes, without making subscribers diff the whole store.
    /// `recencyOnly`: nothing but `lastActiveAt` moved (no `objectWillChange`).
    struct RowChange { let id: SessionKey; let recencyOnly: Bool }
    let rowChanges = PassthroughSubject<RowChange, Never>()
    private var rowObserver: UUID?

    /// Archived projects: hidden from every browse surface, listed in
    /// History's Archived scope. (An archived session is its row's flag.)
    @Published public private(set) var archivedProjectKeys: Set<ProjectKey>
    /// The sidebar order the user arranged, outermost first. Only projects the
    /// user has actually placed appear here; everything else stays on the
    /// launch-frozen recency order.
    @Published public private(set) var projectKeyOrder: [ProjectKey]

    private let now: () -> Date
    /// A cancellable one-shot scheduler; tests advance it without wall-clock waits.
    private let scheduleTouch: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var pendingTouches: [SessionKey: Date] = [:]
    private var touchTimers: [SessionKey: () -> Void] = [:]
    private let db: TempleDB
    /// Transcript facts from the engine: persisted only while the latest
    /// snapshot still authorizes them (`FactCommitter`).
    private let facts: FactCommitter
    private let scheduleFactRetry: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private var factRetry: (() -> Void)?
    private var factRetryDue: Date?
    /// A fact write found its row gone or rejoined: the session's host's
    /// engine is asked to re-read it (AppModel wires this).
    var onOwnershipMismatch: ((SessionKey) -> Void)?

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
        self.rows = Dictionary(uniqueKeysWithValues: states.map { ($0.key, $0) })
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
            rows = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
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

    private func refreshRow(_ id: SessionKey) {
        do {
            if var row = try db.sessionState(id.id, host: id.host) {
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
            TempleUILog.db.error("row refresh failed for session \(id.id, privacy: .public) on \(id.host.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Engine facts

    /// The latest merged snapshot's authorized facts, whole: each newly
    /// authorized entry is persisted once (NULL-only fill and hint, under
    /// the row's host and incarnation); a failed write is retried with
    /// backoff while the snapshot still carries the same authorization, and
    /// dropped the moment one does not.
    public func applyFacts(_ latest: [SessionKey: AuthorizedFacts]) {
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
                onOwnershipMismatch?(id)
            case .failed(let id, let error):
                TempleUILog.db.error("core fill failed for session \(id.id, privacy: .public) on \(id.host.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

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
    var pendingFactIDs: Set<SessionKey> { facts.pendingIDs }

    public convenience init() throws {
        self.init(db: try AppDatabase.open())
    }

    public func isPinned(_ id: SessionKey) -> Bool { rows[id]?.pinned == true }

    /// Membership is the row: one answer, from one place.
    public func isTempleSession(_ id: SessionKey) -> Bool { rows[id] != nil }

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
    /// The session is its id on `id.host` (ADR-041); `core`, when given,
    /// must be that host's. A row on that host naming another agent is
    /// refused: nothing is written and the session is not counted Temple's
    /// (`TempleDB.join`).
    @discardableResult
    public func join(_ id: SessionKey, via: JoinedVia, agent: Agent? = nil, locator: TranscriptLocator? = nil,
                     core: SessionCore? = nil, carrying marks: CarriedMarks? = nil) -> JoinResult {
        if let core, core.host != id.host {
            assertionFailure("a join's facts are its own host's")
            return .failed(TempleDBError.locatorHostMismatch)
        }
        do {
            try db.join(sessionID: id.id, via: via, agent: agent, locator: locator, core: core ?? SessionCore(host: id.host),
                        carrying: marks ?? CarriedMarks(name: nil, color: nil))
            // A join that wrote reached `rows` through the observer already;
            // one that found the row there (another connection inserted it
            // since this store last read) wrote nothing and notified nobody.
            // Either way the row is Temple's now, so read it.
            refreshRow(id)
            return .joined
        } catch TempleDBError.agentConflict(let existing) {
            TempleUILog.db.notice("join refused for session \(id.id, privacy: .public) on \(id.host.rawValue, privacy: .public): row is \(existing.rawValue, privacy: .public)")
            return .refused(.agent(existing))
        } catch {
            TempleUILog.db.error("join failed for session \(id.id, privacy: .public) on \(id.host.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failed(error)
        }
    }

    /// A setter's join: the session, on its own host.
    private func joinForSetter(_ id: SessionKey) -> Bool {
        join(id, via: .imported).isJoined
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
    /// One outcome per session. The same id on two hosts is two sessions,
    /// each joined on its own host (ADR-041). Two agents listing one id on
    /// one host are each attempted: the first joins, and the DB refuses the
    /// second with its reason (`agentConflict`) — never a silent skip that
    /// a caller would count as imported.
    func `import`(_ sessions: [TranscriptSummary]) -> [ImportOutcome] {
        guard !Task.isCancelled else { return sessions.map { _ in .failed(CancellationError()) } }
        // Membership as it stood before this import: an entry joined earlier
        // in the batch does not make a later one for the same session a skip.
        let before = rows
        var joined: Set<SessionKey> = []
        return sessions.map { summary in
            let key = SessionKey(id: summary.id, host: summary.locator.host)
            guard before[key] == nil else { return .skipped }
            do {
                let incarnation = try db.join(sessionID: summary.id, via: .imported, agent: summary.agent,
                                              locator: summary.locator, core: SessionCore(filling: summary))
                // As in `join`: a no-op join still makes the row a member here.
                refreshRow(key)
                // The same session twice in one batch joined once.
                guard joined.insert(key).inserted else { return .skipped }
                return .joined(incarnation: incarnation)
            } catch {
                TempleUILog.db.error("import failed for session \(summary.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return .failed(error)
            }
        }
    }

    /// What one import of another Temple's session came to.
    enum PeerImportOutcome {
        /// The receipt names the membership and the marks it wrote.
        case joined(JoinReceipt)
        /// Already Temple's on its host: left as it is.
        case skipped
        case failed(Error)
    }

    /// Bring another Temple's sessions in without running them
    /// (docs/designs/open-existing-sessions.md section 3): one `.imported`
    /// join each on its host, its recorded transcript as the engine's hint,
    /// and its name and colour written only into a row the join makes.
    /// Nothing else of the other Temple's is written: no title, folder,
    /// pin or archive.
    func importPeers(_ peers: [PeerRow]) -> [PeerImportOutcome] {
        guard !Task.isCancelled else { return peers.map { _ in .failed(CancellationError()) } }
        let before = rows
        var joined: Set<SessionKey> = []
        return peers.map { peer in
            let key = SessionKey(id: peer.id, host: peer.host)
            guard before[key] == nil else { return .skipped }
            do {
                let receipt = try db.join(sessionID: peer.id, via: .imported, agent: peer.agent, locator: peer.locator,
                                          core: SessionCore(host: peer.host), carrying: peer.marks)
                refreshRow(key)
                // Joined meanwhile by another window or connection: not this import's.
                guard receipt.inserted, joined.insert(key).inserted else { return .skipped }
                return .joined(receipt)
            } catch {
                TempleUILog.db.error("import failed for session \(peer.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return .failed(error)
            }
        }
    }

    public func observeLaunchDirectory(_ id: SessionKey, _ directory: String) {
        guard isTempleSession(id) else { return }
        try? db.observeLaunchDirectory(sessionID: id.id, host: id.host, directory)
    }

    /// Immediate, monotonic publication; one fixed 30-second window per
    /// session. Only this session's row moves: the same id on another host
    /// is another session.
    public func touch(_ id: SessionKey, at: Date? = nil) {
        guard var row = rows[id] else { return }
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
        guard touchTimers[id] == nil else { return }
        touchTimers[id] = scheduleTouch(30) { [weak self] in self?.flushTouch(id) }
    }

    private func flushTouch(_ id: SessionKey) {
        touchTimers.removeValue(forKey: id)?()
        guard let date = pendingTouches.removeValue(forKey: id) else { return }
        try? db.touch(sessionID: id.id, host: id.host, at: date)
    }

    public func flushPendingTouches() {
        for id in Array(pendingTouches.keys) { flushTouch(id) }
    }

    /// One session's pending touch written now: a decision about the row
    /// (its drop at a tab's close) is made on what the database says after
    /// this process's own activity has landed, not before.
    public func flushPendingTouch(_ id: SessionKey) { flushTouch(id) }

    /// The row as the database has it this instant, past this store's own
    /// view of it: another process on the same file (an installed Temple
    /// beside a dev build) writes without telling this one.
    public func storedRow(_ id: SessionKey) -> SessionState? {
        try? db.sessionState(id.id, host: id.host)
    }

    /// Undo of an import (`TempleDB.leave`): each row goes only if it is
    /// still an untouched import. Returns the sessions that left; the rest
    /// stay Temple's, holding whatever was decided about them since.
    public func leave(_ keys: [SessionKey]) -> [SessionKey] {
        leave(keys.map { ImportedMembership(key: $0, agent: nil, incarnation: nil) })
    }

    /// One import as History captured it: the row's id and host, and the
    /// agent and membership incarnation it joined with (nil: not checked).
    struct ImportedMembership: Hashable {
        let key: SessionKey
        let agent: Agent?
        let incarnation: String?
        /// The name and colour the import itself wrote (another Temple's).
        var marks = CarriedMarks(name: nil, color: nil)
    }

    /// Undo of an import, narrowed to the membership that import made: a
    /// row that has since left and joined again — as another agent, or as
    /// the same file re-imported — is not the one undone.
    func leave(_ imports: [ImportedMembership]) -> [SessionKey] {
        let left = imports.filter { item in
            let key = item.key
            guard isTempleSession(key) else { return false }
            do {
                return try db.leave(sessionID: key.id, host: key.host, agent: item.agent, incarnation: item.incarnation,
                                    marks: item.marks)
            } catch {
                TempleUILog.db.error("leave failed for session \(key.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }.map(\.key)
        return left
    }

    /// The sweep's drop of rows that never started (ADR-038; see
    /// `TempleDB.discardNeverStarted`). Returns the sessions that went.
    func discardNeverStarted(_ refs: [MembershipRef], idleBefore: Date) -> [SessionKey] {
        guard !refs.isEmpty else { return [] }
        do {
            return try db.discardNeverStarted(refs, idleBefore: idleBefore)
        } catch {
            TempleUILog.db.error("dropping never-started sessions failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// A created session whose tab closed unused (see
    /// `TempleDB.discardUnstartedCreation`).
    @discardableResult
    public func discardUnstartedCreation(_ ref: MembershipRef) -> Bool {
        guard isTempleSession(ref.key) else { return false }
        do {
            return try db.discardUnstartedCreation(ref)
        } catch {
            TempleUILog.db.error("discard failed for session \(ref.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// A remote Discard's row disposition, in one transaction under the
    /// membership it was chosen for (`TempleDB.discardRemoteSession`). A
    /// failed write throws: the caller says so.
    public func discardRemoteSession(_ id: SessionKey, incarnation: String,
                                     lastOpenedAt: Date?) throws -> TempleDB.DiscardDisposition {
        try db.discardRemoteSession(sessionID: id.id, host: id.host, incarnation: incarnation, lastOpenedAt: lastOpenedAt, at: now())
    }

    /// The session was opened in a tab. Written for members only (it never
    /// joins one), so an import undone later can tell the session was used:
    /// `TempleDB.leave` keeps a row opened since.
    public func recordOpened(_ id: SessionKey, at date: Date = Date()) {
        guard isTempleSession(id) else { return }
        do {
            try db.recordOpened(sessionID: id.id, host: id.host, at: date)
        } catch {
            TempleUILog.db.error("recording the open failed for session \(id.id, privacy: .public) on \(id.host.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // Each setter writes its column; the committed row is what every reader
    // then sees. A write that fails changes nothing on screen, rather than
    // showing a state that would vanish at the next launch.

    public func togglePin(_ id: SessionKey) {
        guard joinForSetter(id) else { return }
        try? db.setPinned(!isPinned(id), sessionID: id.id, host: id.host)
    }

    public func isArchived(_ id: SessionKey) -> Bool { rows[id]?.archived == true }

    /// Archiving drops the pin: a session cannot be both the one you always
    /// want in front of you and one you have put away. Unarchiving does not
    /// bring it back — the pin was a separate decision, and re-pinning is a
    /// click. The DB write clears the pin in the same statement.
    public func setArchived(_ archived: Bool, session id: SessionKey) {
        guard joinForSetter(id) else { return }
        try? db.setArchived(archived, sessionID: id.id, host: id.host, at: now())
    }

    // MARK: Temple's archive (ADR-030)
    // Thin and unretried like every setter here: a failed write is logged
    // and changes nothing on screen; the next sweep plans it again.

    /// Archive rows nobody can resume any more. Returns the sessions archived.
    func autoArchive(_ entries: [AutoArchiveEntry], idleBefore: Date) -> [SessionKey] {
        do {
            return try db.autoArchive(entries, idleBefore: idleBefore, at: now())
        } catch {
            TempleUILog.db.error("auto-archive failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The notice's Undo. Returns the sessions restored.
    func restoreTempleArchives(_ refs: [MembershipRef]) -> [SessionKey] {
        do {
            return try db.restoreTempleArchives(refs, at: now())
        } catch {
            TempleUILog.db.error("restoring auto-archived sessions failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// What a Restore changed, for its Undo and Redo: every touched row as
    /// it was, the memberships restored, and the projects whose mask it
    /// lifted.
    struct RestoreRecord {
        let states: [ArchiveState]
        let restored: [MembershipRef]
        let unmasked: [ProjectKey]
        var isEmpty: Bool { states.isEmpty && unmasked.isEmpty }
    }

    /// A person's Restore (ADR-031), of these sessions as they are now:
    /// each comes back on its own. A session whose project is archived takes
    /// the project's mask apart into its siblings' own flags
    /// (`TempleDB.restoreSessions`), so the rest of the project stays away.
    /// `unmasking` lifts those projects' masks whatever the ids. Nil when the
    /// write failed.
    func restoreSessions(_ ids: [SessionKey], unmasking extra: [ProjectKey] = []) -> RestoreRecord? {
        let refs = ids.compactMap { id -> MembershipRef? in
            guard let row = rows[id], let incarnation = row.incarnation else { return nil }
            return MembershipRef(id: id.id, host: id.host, incarnation: incarnation)
        }
        return restore(refs, unmasking: extra.filter { archivedProjectKeys.contains($0) })
    }

    /// The same, for exactly these memberships (Redo): one that left and
    /// joined again since is not restored, and its project is not touched.
    func restore(_ refs: [MembershipRef], unmasking extra: [ProjectKey] = []) -> RestoreRecord? {
        do {
            let outcome = try db.restoreSessions(refs, masked: archivedProjectKeys, unmasking: extra, at: now())
            for key in outcome.unmasked { archivedProjectKeys.remove(key) }
            for key in outcome.unmasked where !key.host.isLocal { remoteProjectState?.setArchived(false, key: key) }
            return RestoreRecord(states: outcome.states, restored: outcome.restored, unmasked: outcome.unmasked)
        } catch {
            TempleUILog.db.error("restore failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Undo of a Restore: rows exactly as they were, masks back on.
    func revert(_ record: RestoreRecord) {
        do {
            try db.revertArchiveStates(record.states, maskingAgain: record.unmasked)
            for key in record.unmasked { archivedProjectKeys.insert(key) }
            for key in record.unmasked where !key.host.isLocal { remoteProjectState?.setArchived(true, key: key) }
        } catch {
            TempleUILog.db.error("undoing a restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func isProjectArchived(_ key: ProjectKey) -> Bool { archivedProjectKeys.contains(key) }
    public func setProjectArchived(_ archived: Bool, key: ProjectKey) {
        if archived { archivedProjectKeys.insert(key) } else { archivedProjectKeys.remove(key) }
        // `project_state` is this Mac's; a host's projects keep their masks
        // in the remote store, written by the same operation.
        if key.host.isLocal { try? db.setProjectArchived(archived, path: key.path) }
        else { remoteProjectState?.setArchived(archived, key: key) }
    }
    public func setProjectKeyOrder(_ keys: [ProjectKey]) {
        projectKeyOrder = keys
        try? db.setProjectOrder(keys.filter { $0.host.isLocal }.map(\.path))
        // A host's part of the order, each at its place in the whole list.
        remoteProjectState?.setOrder(keys.enumerated().filter { !$0.element.host.isLocal }
            .map { (key: $0.element, position: $0.offset) })
    }

    /// Remote projects' archive masks and their part of the manual order
    /// (`remote_project_state`, docs/designs/remote-ssh.md section 8). Set
    /// once at launch while sessions on hosts are on; the two files are not
    /// one transaction, and a mask left out of step by a crash is put right
    /// by the next Restore or Undo, which rewrite it from the rows.
    public var remoteProjectState: RemoteProjectStatePersisting? {
        didSet { loadRemoteProjectState() }
    }

    private func loadRemoteProjectState() {
        guard let remoteProjectState else { return }
        let states = remoteProjectState.projectStates()
        archivedProjectKeys.formUnion(states.filter(\.archived).map(\.key))
        var order = projectKeyOrder.filter { $0.host.isLocal }
        for state in states.compactMap({ state in state.position.map { (state.key, $0) } }).sorted(by: { $0.1 < $1.1 }) {
            order.insert(state.0, at: min(state.1, order.count))
        }
        projectKeyOrder = order
    }

    public func customName(for id: SessionKey) -> String? { rows[id]?.customName }

    public func rename(_ id: SessionKey, to name: String) {
        guard joinForSetter(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? db.setCustomName(trimmed.isEmpty ? nil : trimmed, sessionID: id.id, host: id.host)
    }

    public func color(for id: SessionKey) -> String? { rows[id]?.color }

    public func setColor(_ name: String?, for id: SessionKey) {
        guard joinForSetter(id) else { return }
        try? db.setColor(name, sessionID: id.id, host: id.host)
    }

    /// The last title the agent gave itself. Claude and Codex retitle their
    /// terminal as the work moves on, but write that title nowhere on disk —
    /// so the row remembers it, and a session keeps the name it earned even
    /// after it is closed and the app restarts.
    public func generatedTitle(for id: SessionKey) -> String? { rows[id]?.generatedTitle }

    /// How long live retitles coalesce before one DB write (and so one row
    /// change). Every WORKING agent retitles about once a second; flushing
    /// per tick meant a full re-render plus a synchronous DB write per
    /// title, per agent.
    var titleFlushDelay: TimeInterval = 1.0
    /// Latest unflushed title per session (last one in a window wins).
    private var pendingGeneratedTitles: [SessionKey: String] = [:]
    private var titleFlushTask: Task<Void, Never>?

    /// Record the agent's current self-assigned title. Cheap to call on every
    /// retitle: unchanged titles are dropped here, and changed ones batch into
    /// one flush per `titleFlushDelay` window.
    public func recordGeneratedTitle(_ title: String, for id: SessionKey) {
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
            try? db.setTitle(title, sessionID: id.id, host: id.host)
        }
        pendingGeneratedTitles.removeAll()
    }

    /// Display title: a rename wins, then whatever the agent last called itself,
    /// then the title parsed from the session file (which is pinned to the first
    /// prompt and never catches up with a long session).
    public func displayTitle(for session: TranscriptSummary) -> String {
        let key = SessionKey(id: session.id, host: session.locator.host)
        return customName(for: key) ?? generatedTitle(for: key) ?? session.catalogTitle
    }
}
