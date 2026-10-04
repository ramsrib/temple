import Foundation

/// What `EngineSet` and the app need from one host's engine. `SessionEngine`
/// is the only production conformer; tests substitute scripted ones.
public protocol HostEngine: AnyObject, Sendable {
    var host: HostID { get }
    /// The latest publication (nil before the first one and after stop).
    var latestSnapshot: EngineSnapshot? { get }
    /// The only channel: replays the latest snapshot, then every new one.
    func snapshots() -> AsyncStream<EngineSnapshot>
    func start() async
    func stop() async
    /// An explicit open: a refreshed listing and a reset parse budget.
    func requestResolution(_ id: String, awaitingCreation: Bool) async
    /// Re-read the member's row and follow it (join, leave, rejoin, a new hint).
    func reconcileMembership(_ id: String) async
    /// A fresh, completed "no transcript at all" for a member (see `SessionEngine`).
    func confirmAbsence(_ id: String) async -> Bool
}

public extension HostEngine {
    func requestResolution(_ id: String) async { await requestResolution(id, awaitingCreation: false) }
}

/// One host's member state machine: locate → verify → enrich → back off →
/// verdict, over the host's primitive seam (`HostSessionSource`). It reads
/// the database (membership and which core fields a row still lacks) and
/// never writes it: transcript facts leave only as `AuthorizedFacts` in a
/// snapshot, and the consumer persists them (`FactCommitter`). Identical for
/// every host.
///
/// Every result that comes back from an `await` — a locate, a read — is
/// checked before anything is mutated: the run epoch (stop/start), the
/// member's operation revision (bumped by every invalidation: a transcript
/// event, coverage reset, reconnect, shared-fact change, explicit refresh,
/// candidate replacement, membership change), the source coverage and the
/// candidate the read was issued for. A stale result is dropped; the member
/// is already queued again by whatever made it stale.
///
/// Task ownership: nothing the engine spawns retains it. The drain, timer
/// and change-stream tasks hold the source and a weak engine, and snapshot
/// streams hold only the mirror; whoever made the engine is its sole owner.
public actor SessionEngine: HostEngine {
    public nonisolated let host: HostID
    public nonisolated let source: any HostSessionSource
    private let database: TempleDB?
    private let initialMembers: Set<String>
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private nonisolated let mirror = EngineMirror()
    private nonisolated let relay: EngineRelay

    // Run state.
    private var running = false
    private var runEpoch: UInt64 = 0
    private var coverage: UInt64 = 0
    /// Whether this run has heard any coverage yet (a source may start at 0).
    private var coverageKnown = false
    private var reconnects: UInt64 = 0
    private var sharedRevision: [Agent: UInt64] = [:]
    private var complete: Set<Agent> = []
    private var members: [String: Member] = [:]
    private var membershipLoaded = false
    private var membershipDelay: TimeInterval = 1
    /// Joins committed before `start` that await their transcript's creation
    /// (a new Claude session): the flag is the join's, not the row's.
    private var prestartAwaiting: Set<String> = []

    // Work queue.
    private var pending: Set<String> = []
    private var explicit: Set<String> = []
    private var draining = false
    private var drainTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var timerDue: Date?
    /// Members waiting for a due time before they are queued again
    /// (backoff, a failed transport, a deferred enrichment).
    private var deferred: [String: Date] = [:]
    private var membershipRetryAt: Date?
    private var locateDelay: TimeInterval = 1
    private var readDelays: [String: TimeInterval] = [:]
    /// Per member: the delay before a read that found its file changing
    /// (changed during the read, or not the listed version) is tried again.
    private var churnDelays: [String: TimeInterval] = [:]
    /// Per member: no read before this time (the churn backoff). Events
    /// still revoke at once; their work waits for it. Explicit refresh,
    /// and an accepted read, lift it.
    private var churnUntil: [String: Date] = [:]
    /// Which members a transcript locator concerns (their hint and listed
    /// candidates), so an event costs a lookup, not a scan of every member.
    private var byLocator: [TranscriptLocator: Set<String>] = [:]
    private var indexed: [String: Set<TranscriptLocator>] = [:]
    private var absenceWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var publishScheduled = false
    /// Facts were revoked since the last publication.
    private var revoked = false
    /// A resolution, a fact or the member set changed since the last
    /// publication; without it a publication is skipped unbuilt.
    private var snapshotDirty = true

    // Publication.
    private var generation: UInt64 = 0
    private var published: EngineSnapshot?

    // Counters (engine side; the source adds its own).
    private var counters = EngineMetrics()
    /// Test seam: the next N membership reads throw.
    private var membershipReadFailures = 0

    /// `members` only when `database` is nil (a fixed set, no facts: with no
    /// row there is no incarnation to authorize a write against).
    public init(source: any HostSessionSource, database: TempleDB? = nil,
                members: Set<String> = [],
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = source.host
        self.source = source
        self.database = database
        self.initialMembers = database == nil ? members : []
        self.now = now
        self.sleep = sleep
        let relay = EngineRelay(database: database)
        self.relay = relay
        relay.attach(self)
    }

    deinit {
        relay.detach()
        drainTask?.cancel(); changesTask?.cancel(); timerTask?.cancel()
        mirror.finish()
    }

    // MARK: Published surface (nonisolated)

    public nonisolated var latestSnapshot: EngineSnapshot? { mirror.latest }
    public nonisolated func resolution(for id: String) -> MemberResolution? { mirror.latest?.resolutions[id] }
    public nonisolated func snapshots() -> AsyncStream<EngineSnapshot> { mirror.stream() }
    public nonisolated var isMonitoring: Bool {
        (source as? any HostSourceDiagnostics)?.isMonitoring ?? source.capabilities.contains(.liveChanges)
    }
    public nonisolated var metrics: EngineMetrics {
        var result = mirror.counters
        if let diagnostics = source as? any HostSourceDiagnostics {
            let host = diagnostics.metrics
            result.parses = host.parses
            result.enumerations = host.enumerations
            result.widerReads = host.widerReads
            result.sharedTransfers = host.sharedTransfers
        }
        return result
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        runEpoch &+= 1
        coverage = 0; coverageKnown = false; reconnects = 0; complete = []; sharedRevision = [:]
        locateDelay = 1; membershipDelay = 1
        // Arm observation before the first listing: the source starts
        // watching on subscription, and a locate after it sees the result.
        let stream = source.changes()
        let epoch = runEpoch
        changesTask = Task { [weak self, source, sleep] in
            await Self.followChanges(first: stream, source: source, sleep: sleep, epoch: epoch, engine: WeakEngine(self))
        }
        loadMembership()
    }

    public func stop() {
        guard running else { return }
        running = false
        runEpoch &+= 1
        drainTask?.cancel(); drainTask = nil; draining = false
        changesTask?.cancel(); changesTask = nil
        timerTask?.cancel(); timerTask = nil; timerDue = nil
        pending.removeAll(); explicit.removeAll(); deferred.removeAll(); readDelays.removeAll(); churnDelays.removeAll()
        churnUntil.removeAll()
        byLocator.removeAll(); indexed.removeAll()
        membershipRetryAt = nil; membershipLoaded = false
        members.removeAll(); prestartAwaiting.removeAll()
        for waiters in absenceWaiters.values { waiters.forEach { $0.resume(returning: false) } }
        absenceWaiters.removeAll()
        // A last, empty publication: whatever a consumer still holds or
        // retries from this run is revoked.
        if published != nil {
            generation &+= 1
            mirror.publish(EngineSnapshot(generation: generation, resolutions: [:], facts: [:]))
        }
        published = nil
        mirror.clear()
    }

    private func loadMembership() {
        guard running else { return }
        if let database {
            do {
                if membershipReadFailures > 0 { membershipReadFailures -= 1; throw EngineTestError.injected }
                let rows = try database.sessionStates(host: host)
                for row in rows where members[row.id] == nil {
                    var member = Member(row: row, readOnly: database.isReadOnly)
                    if prestartAwaiting.contains(row.id) { member.awaitingCreation = true; member.resolution = .awaitingCreation }
                    members[row.id] = member
                    reindex(row.id)
                }
                prestartAwaiting.removeAll()
                snapshotDirty = true
            } catch {
                // An empty snapshot, and the read is retried: a failed read
                // proves nothing about membership.
                TempleCoreLog.watcher.error("membership read failed: \(String(describing: error), privacy: .public)")
                membershipRetryAt = now().addingTimeInterval(membershipDelay)
                membershipDelay = min(60, membershipDelay * 2)
                publishNow()
                scheduleTimer()
                return
            }
        } else {
            for id in initialMembers where members[id] == nil { members[id] = Member(id: id) }
        }
        membershipLoaded = true
        membershipRetryAt = nil
        publishNow()
        enqueue(Set(members.keys))
    }

    // MARK: Requests and membership

    public func requestResolution(_ id: String, awaitingCreation: Bool = false) {
        guard running else { return }
        if members[id] == nil { reconcileMembership(id, awaitingCreation: awaitingCreation) }
        guard var member = members[id] else { return }
        if awaitingCreation, !member.resolution.isLoaded { member.awaitingCreation = true }
        member.resetBudget()
        member.failures.removeAll()
        members[id] = member
        churnUntil.removeValue(forKey: id)   // an explicit open does not wait
        invalidate(id)
        explicit.insert(id)
        enqueue([id])
        publishIfRevoked()
    }

    public func reconcileMembership(_ id: String) { reconcileMembership(id, awaitingCreation: false) }

    /// Membership is the database's: the row is re-read, so callbacks that
    /// arrive late or out of order can neither resurrect a member that left
    /// nor miss a rejoin.
    func reconcileMembership(_ id: String, awaitingCreation: Bool) {
        guard running, membershipLoaded else {
            if awaitingCreation { prestartAwaiting.insert(id) }
            return
        }
        guard let database else {
            // A fixed member set: an explicit request is the only change.
            if initialMembers.contains(id), members[id] == nil { members[id] = Member(id: id); enqueue([id]) }
            return
        }
        let row: SessionState?
        do { row = try database.sessionState(id) }
        catch { return }   // A failed read proves nothing; the member stays as it was.
        guard let row, row.host == host else {
            if members.removeValue(forKey: id) != nil { removed(id) }
            return
        }
        guard var member = members[id] else {
            var member = Member(row: row, readOnly: database.isReadOnly)
            member.awaitingCreation = awaitingCreation
            if awaitingCreation { member.resolution = .awaitingCreation }
            members[id] = member
            snapshotDirty = true
            reindex(id)
            publishNow()
            enqueue([id])
            return
        }
        if member.incarnation != row.incarnation {
            // A new membership: nothing of the old one's work stands.
            var fresh = Member(row: row, readOnly: database.isReadOnly)
            fresh.opRevision = member.opRevision &+ 1
            fresh.awaitingCreation = awaitingCreation
            fresh.resolution = awaitingCreation ? .awaitingCreation : .resolving
            members[id] = fresh
            // The old membership's backoffs are not this one's to wait out.
            deferred.removeValue(forKey: id); readDelays.removeValue(forKey: id)
            churnDelays.removeValue(forKey: id); churnUntil.removeValue(forKey: id)
            snapshotDirty = true
            reindex(id)
            resolveAbsenceWaiters(id, absent: false)
            publishNow()
            enqueue([id])
            return
        }
        let oldHint = member.hint, oldAgent = member.agent, oldWanted = member.wanted
        member.update(row: row, readOnly: database.isReadOnly)
        if awaitingCreation, !member.resolution.isLoaded { member.awaitingCreation = true }
        var relocate = false
        if member.hint != oldHint, member.hint?.path != member.verified?.locator.path { relocate = true }
        if member.agent != oldAgent, !member.resolution.isLoaded { relocate = true }
        if !member.wanted.isSubset(of: oldWanted) {
            // It wants a field again: from here on it is guarded, and the
            // file is verified afresh before anything is read from it.
            relocate = true
            member.verified = nil
        }
        if awaitingCreation, !member.resolution.isLoaded { relocate = true }
        // Facts the row no longer needs leave the snapshot (a fill landed,
        // or another writer got there first).
        if let facts = member.facts, let row = member.row, !facts.wouldChange(row) { member.facts = nil; snapshotDirty = true }
        // A field filled elsewhere shortens the backoff of a parse that was
        // waiting behind it; it never re-reads a file already read.
        let rearm = !relocate && member.wanted.isStrictSubset(of: oldWanted) && !member.wanted.isEmpty && deferred[id] != nil
        if rearm { member.delay = 1; member.nextAttempt = .distantPast }
        members[id] = member
        reindex(id)
        if rearm { enqueue([id]) }
        if relocate {
            invalidate(id)
            enqueue([id])
            publishIfRevoked()
        } else {
            schedulePublish()
        }
    }

    private func removed(_ id: String) {
        snapshotDirty = true
        pending.remove(id); explicit.remove(id); deferred.removeValue(forKey: id); readDelays.removeValue(forKey: id)
        churnDelays.removeValue(forKey: id)
        churnUntil.removeValue(forKey: id)
        reindex(id)
        resolveAbsenceWaiters(id, absent: false)
        publishNow()
    }

    /// A fresh answer to "does this member have no transcript at all?" — not
    /// the published verdict, which can be a cached awaiting-creation or an
    /// absence from an older listing. The member stops awaiting creation and
    /// is resolved explicitly (a refreshed listing). True only for a
    /// completed absence; incomplete, unreadable, a failed listing, a stop or
    /// a member that left all answer false.
    public func confirmAbsence(_ id: String) async -> Bool {
        guard running, var member = members[id] else { return false }
        member.awaitingCreation = false
        members[id] = member
        requestResolution(id, awaitingCreation: false)
        return await withCheckedContinuation { continuation in
            absenceWaiters[id, default: []].append(continuation)
        }
    }

    private func resolveAbsenceWaiters(_ id: String, absent: Bool) {
        guard let waiters = absenceWaiters.removeValue(forKey: id) else { return }
        waiters.forEach { $0.resume(returning: absent) }
    }

    /// Test seam: run every due backoff now (a clock a test advanced).
    func reconcileEnrichment() {
        fireTimers()
    }

    /// Test seam: the next `count` membership reads in `start` throw.
    func failMembershipReads(_ count: Int) { membershipReadFailures = count }

    /// Test seams: what the gate compares against.
    var currentCoverage: UInt64 { coverage }
    var currentReconnects: UInt64 { reconnects }
    func operationRevision(_ id: String) -> UInt64? { members[id]?.opRevision }
    /// Test seam: the membership incarnation the engine currently holds for `id`.
    func memberIncarnation(_ id: String) -> String? { members[id]?.incarnation }

    /// Test seam: database callbacks are held (in order) until released, so
    /// a test can deliver them late — after a leave and a rejoin, say.
    nonisolated func holdDatabaseCallbacks() { relay.hold() }
    nonisolated func releaseDatabaseCallbacks(reversed: Bool = false) { relay.release(reversed: reversed) }

    /// Starts (or extends) the member's churn backoff.
    private func holdForChurn(_ id: String) {
        let delay = churnDelays[id] ?? 0.25
        churnDelays[id] = min(8, delay * 2)
        churnUntil[id] = now().addingTimeInterval(delay)
        deferred[id] = churnUntil[id]
        scheduleTimer()
    }

    // MARK: Locator index

    /// Brings the reverse index in line with the member's hint and listed
    /// candidates (or removes it, for a member that left).
    private func reindex(_ id: String) {
        let next: Set<TranscriptLocator> = members[id].map { member in
            Set(member.candidates.map(\.locator) + [member.hint].compactMap { $0 })
        } ?? []
        let old = indexed[id] ?? []
        guard next != old else { return }
        for locator in old.subtracting(next) {
            byLocator[locator]?.remove(id)
            if byLocator[locator]?.isEmpty == true { byLocator.removeValue(forKey: locator) }
        }
        for locator in next.subtracting(old) { byLocator[locator, default: []].insert(id) }
        indexed[id] = next.isEmpty ? nil : next
    }

    // MARK: Invalidation

    /// Whatever the engine was doing for this member is stale: results in
    /// flight are dropped (operation revision) and authorized facts are
    /// revoked at once. The verdict stands until the member is resolved again.
    private func invalidate(_ id: String) {
        guard var member = members[id] else { return }
        member.opRevision &+= 1
        member.pass = nil
        if member.facts != nil {
            // Revoked facts must be producible again: the parse that made
            // them no longer counts against an unchanged file (the backoff
            // stands).
            member.facts = nil
            member.lastAttempt = nil
            revoked = true
            snapshotDirty = true
        }
        members[id] = member
    }

    /// Revocations reach the consumer at once: a write it is still retrying
    /// for revoked facts must stop now, not at the next pass.
    private func publishIfRevoked() {
        guard revoked else { return }
        revoked = false
        publishNow()
    }

    private func enqueue(_ ids: Set<String>) {
        guard running, membershipLoaded else { return }
        var live = ids.filter { members[$0] != nil }
        // A member waiting out a churn backoff stays deferred to its
        // deadline, however many events arrive meanwhile.
        let time = now()
        let held = live.filter { (churnUntil[$0] ?? .distantPast) > time }
        for id in held { deferred[id] = churnUntil[id] }
        if !held.isEmpty { scheduleTimer() }
        live.subtract(held)
        guard !live.isEmpty else { return }
        for id in live { deferred.removeValue(forKey: id) }
        pending.formUnion(live)
        guard !draining else { return }
        draining = true
        let epoch = runEpoch
        drainTask = Task { [weak self, source] in
            await Self.drain(source: source, epoch: epoch, engine: WeakEngine(self))
        }
    }

    // MARK: Changes

    private static func followChanges(first: AsyncThrowingStream<SourceChange, Error>, source: any HostSessionSource,
                                      sleep: @Sendable (Duration) async throws -> Void, epoch: UInt64,
                                      engine box: WeakEngine) async {
        var engine: SessionEngine? { box.value }
        var stream = first
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                for try await change in stream {
                    guard !Task.isCancelled, let live = engine else { return }
                    delay = 1
                    await live.handle(change, epoch: epoch)
                }
            } catch {
                TempleCoreLog.watcher.error("change stream failed: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled, engine != nil else { return }
            // The stream ended or threw: verdicts stand, and observation is
            // re-armed after a backoff, then every member is located again.
            do { try await sleep(.seconds(delay)) } catch { return }
            delay = min(60, delay * 2)
            guard !Task.isCancelled, engine != nil else { return }
            stream = source.changes()
            guard let live = engine, await live.reconnected(epoch: epoch) else { return }
        }
    }

    private func reconnected(epoch: UInt64) -> Bool {
        guard running, runEpoch == epoch else { return false }
        reconnects &+= 1
        // The stream could not vouch for what happened while it was down:
        // like a coverage reset, every member is located again with its
        // enrichment re-armed.
        for id in members.keys {
            members[id]?.resetBudget()
            members[id]?.failures.removeAll()
            members[id]?.verified = nil
            invalidate(id)
        }
        enqueue(Set(members.keys))
        publishIfRevoked()
        return true
    }

    private func handle(_ change: SourceChange, epoch: UInt64) {
        guard running, runEpoch == epoch else { return }
        defer { publishIfRevoked() }
        switch change {
        case .transcripts(let ids, let locators):
            var affected = Set(ids.filter { members[$0] != nil })
            for locator in locators { affected.formUnion(byLocator[locator] ?? []) }
            guard !affected.isEmpty else { return }
            counters.observations &+= UInt64(affected.count)
            mirror.setCounters(counters)
            // Work in flight is stale either way (C6). A member with facts to
            // protect — it wants a field, or holds issued facts — has them
            // revoked now, whatever the change was (growth included), and
            // its identity is read again. A complete member has none: the
            // listing decides, and an append to the same file is a stat.
            for id in affected {
                guard let member = members[id] else { continue }
                // Work under way is superseded by a change to its file: the
                // file is changing under the reads, so the next one waits
                // out a short, growing delay (the churn backoff).
                if member.pass != nil { holdForChurn(id) }
                if member.guardsFacts {
                    invalidate(id)
                    members[id]?.verified = nil
                } else {
                    members[id]?.opRevision &+= 1
                    members[id]?.pass = nil
                }
            }
            enqueue(affected)
        case .coverageReset(let next):
            // Already learned from a listing (which re-resolved everyone else).
            guard next > coverage || !coverageKnown else { return }
            coverage = next
            coverageKnown = true
            // Nothing observed before can be vouched for: every member is
            // located again, with its parse budget re-armed.
            for id in members.keys {
                members[id]?.resetBudget()
                members[id]?.failures.removeAll()
                members[id]?.verified = nil
                invalidate(id)
            }
            enqueue(Set(members.keys))
        case .sharedFacts(let agent, let revision):
            sharedFactsAdvanced(agent, to: revision)
        }
    }

    /// Only a member of that agent (or of no known agent) still wanting a
    /// title, with a transcript to read them against (loaded, or a read in
    /// flight), can gain from new shared facts. Its transcript is unchanged,
    /// so the attempt recorded against it is dropped once (the backoff
    /// stands) and everyone else — including members with no transcript,
    /// which a history line cannot give one — is left alone.
    private func sharedFactsAdvanced(_ agent: Agent, to revision: UInt64) {
        // The first revision a run hears of is a baseline, not a change:
        // nothing has been read against an older one yet.
        guard let known = sharedRevision[agent] else { sharedRevision[agent] = revision; return }
        guard revision > known else { return }
        sharedRevision[agent] = revision
        var affected: Set<String> = []
        for (id, member) in members where member.agent == nil || member.agent == agent {
            // Facts it still holds are revoked whatever its verdict.
            guard member.wanted.contains(.title),
                  member.resolution.isLoaded || member.pass != nil || member.facts != nil else { continue }
            members[id]?.lastAttempt = nil
            invalidate(id)
            affected.insert(id)
        }
        enqueue(affected)
    }

    // MARK: Drain

    private struct LocateBatch: Sendable {
        let epoch: UInt64
        let requests: [LocateRequest]
        let revisions: [String: UInt64]
        /// The membership each request was for: a member that left and
        /// rejoined starts its revisions again, so the revision alone is not
        /// its identity.
        let incarnations: [String: String?]
    }

    private static func drain(source: any HostSessionSource, epoch: UInt64, engine box: WeakEngine) async {
        var engine: SessionEngine? { box.value }
        // A short window from idle, so ids queued by a burst of callbacks or
        // events go out in one listing.
        try? await Task.sleep(for: .milliseconds(5))
        while !Task.isCancelled, let batch = await engine?.nextBatch(epoch: epoch) {
            let result: Result<LocateResult, Error>
            do { result = .success(try await source.locate(batch.requests)) }
            catch { result = .failure(error) }
            // Members settled from the listing (or cached verification)
            // inside the actor; only actual reads come back.
            guard !Task.isCancelled, let plans = await engine?.acceptLocate(batch, result) else { return }
            await withTaskGroup(of: Void.self) { group in
                var queue = plans[...]
                func add() {
                    guard let (id, first) = queue.popFirst() else { return }
                    group.addTask {
                        var engine: SessionEngine? { box.value }
                        var plan: ReadPlan? = first
                        while let current = plan, !Task.isCancelled {
                            let outcome: Result<TranscriptRead, Error>
                            do {
                                outcome = .success(try await source.read(current.locator, agent: current.agent,
                                                                         expecting: id, facts: current.facts))
                            } catch { outcome = .failure(error) }
                            plan = await engine?.step(id, after: (current, outcome))
                        }
                    }
                }
                // Four reads side by side.
                for _ in 0..<4 { add() }
                while await group.next() != nil { add() }
            }
            await engine?.endPass(epoch: epoch)
        }
    }

    private func nextBatch(epoch: UInt64) -> LocateBatch? {
        guard running, runEpoch == epoch, !pending.isEmpty else {
            if runEpoch == epoch { draining = false; drainTask = nil }
            return nil
        }
        var requests: [LocateRequest] = []
        var revisions: [String: UInt64] = [:]
        var incarnations: [String: String?] = [:]
        let time = now()
        while requests.isEmpty, !pending.isEmpty {
            let ids = Array(pending.sorted().prefix(256))
            pending.subtract(ids)
            for id in ids {
                guard let member = members[id] else { continue }
                // Queued before its churn backoff began: it waits for it
                // (an explicit request does not).
                if !explicit.contains(id), let until = churnUntil[id], until > time {
                    deferred[id] = until
                    scheduleTimer()
                    continue
                }
                let refresh = explicit.remove(id) != nil
                members[id]?.pendingExplicit = refresh
                requests.append(LocateRequest(id: id, agent: member.agent, hint: member.hint, refresh: refresh))
                revisions[id] = member.opRevision
                incarnations[id] = .some(member.incarnation)
            }
        }
        guard !requests.isEmpty else { draining = false; drainTask = nil; return nil }
        counters.locates &+= 1
        mirror.setCounters(counters)
        return LocateBatch(epoch: epoch, requests: requests, revisions: revisions, incarnations: incarnations)
    }

    /// The first read for each member that needs one; every other member of
    /// the batch is settled here.
    private func acceptLocate(_ batch: LocateBatch, _ result: Result<LocateResult, Error>) -> [(String, ReadPlan)]? {
        guard running, runEpoch == batch.epoch else { return nil }
        let ids = batch.requests.map(\.id)
        let located: LocateResult
        switch result {
        case .failure(let error):
            // A failed listing proves nothing: verdicts stand, a member that
            // never had one is incomplete, and the batch waits out a backoff.
            TempleCoreLog.watcher.error("locate failed: \(String(describing: error), privacy: .public)")
            counters.retries &+= 1
            mirror.setCounters(counters)
            let due = now().addingTimeInterval(locateDelay)
            locateDelay = min(60, locateDelay * 2)
            // Only members this listing was still for: one that left,
            // rejoined or was asked for again since is queued anew, and its
            // own listing answers for it (and for any absence waiter).
            for id in ids where isCurrent(id, batch, batch.revisions) {
                if members[id]?.everSettled == false, members[id]?.awaitingCreation == false {
                    members[id]?.resolution = .incomplete
                    snapshotDirty = true
                }
                deferred[id] = due
                resolveAbsenceWaiters(id, absent: false)
            }
            scheduleTimer()
            publishNow()
            return []
        case .success(let value): located = value
        }
        locateDelay = 1
        // A listing older than what the engine has seen says nothing now.
        guard located.coverage >= coverage else {
            enqueue(Set(ids))
            return []
        }
        var revisions = batch.revisions
        let first = !coverageKnown
        coverageKnown = true
        if located.coverage > coverage || first {
            coverage = located.coverage
            if !first {
                // New coverage: nothing seen under the old one can be vouched
                // for. Every member's facts are revoked and its enrichment
                // re-armed; members outside this batch are located again,
                // and this batch — listed under the new coverage — goes on.
                for id in members.keys {
                    let current = isCurrent(id, batch, batch.revisions)
                    members[id]?.resetBudget()
                    members[id]?.failures.removeAll()
                    members[id]?.verified = nil
                    invalidate(id)
                    if current { revisions[id] = members[id]?.opRevision }
                }
                enqueue(Set(members.keys).subtracting(ids))
            }
        }
        for (agent, revision) in located.sharedRevision { sharedFactsAdvanced(agent, to: revision) }
        complete = located.complete
        var reads: [(String, ReadPlan)] = []
        for id in ids {
            guard isCurrent(id, batch, revisions), var member = members[id] else { continue }
            let candidates = located.candidates[id] ?? []
            member.candidates = candidates
            members[id] = member
            reindex(id)
            // Past a missing revert, the first rollout still there decides,
            // as the catalog picks: an unreadable one stops the fallback.
            let permitted = TranscriptCandidates.permitted(candidates, role: \.role, missing: { $0.stat == .missing },
                                                           group: { AnyHashable($0.agent) })
            let present = permitted.filter { $0.stat != .missing }
            // Facts for anything but exactly the file version they were read
            // from are revoked (candidate replacement, or any change to it).
            if let facts = member.facts {
                let first = present.first
                let same: Bool = {
                    guard let first, first.locator == facts.locator, case .present(let signature) = first.stat else { return false }
                    return signature == facts.signature
                }()
                if !same {
                    members[id] = member
                    invalidate(id)
                    member = members[id]!
                }
            }
            member.pass = Pass(epoch: batch.epoch, opRevision: member.opRevision, incarnation: member.incarnation,
                               coverage: coverage, explicit: member.pendingExplicit, queue: present)
            member.pendingExplicit = false
            members[id] = member
            if let plan = step(id, after: nil) { reads.append((id, plan)) }
        }
        publishIfRevoked()
        return reads
    }

    /// Whether this listing was for the member as it is now: the same
    /// membership, with nothing having invalidated it since.
    private func isCurrent(_ id: String, _ batch: LocateBatch, _ revisions: [String: UInt64]) -> Bool {
        guard let member = members[id], let incarnation = batch.incarnations[id] else { return false }
        return member.incarnation == incarnation && member.opRevision == revisions[id]
    }

    private func endPass(epoch: UInt64) {
        guard running, runEpoch == epoch else { return }
        publishNow()
    }

    // MARK: Per-member steps

    private struct ReadPlan: Sendable {
        let locator: TranscriptLocator
        let agent: Agent
        let facts: Bool
        let signature: TranscriptSignature
        /// The pass it was issued for: a result is accepted only by that pass.
        let epoch: UInt64
        let opRevision: UInt64
        let incarnation: String?
    }

    /// Takes the outcome of the previous read (if any), then decides the
    /// next one — or settles the member and returns nil.
    private func step(_ id: String, after previous: (ReadPlan, Result<TranscriptRead, Error>)?) -> ReadPlan? {
        guard running, var member = members[id], var pass = member.pass, pass.epoch == runEpoch,
              pass.incarnation == member.incarnation, pass.opRevision == member.opRevision,
              pass.coverage == coverage else { return nil }
        if let (plan, outcome) = previous {
            guard plan.epoch == pass.epoch, plan.incarnation == pass.incarnation, plan.opRevision == pass.opRevision,
                  pass.queue.first?.locator == plan.locator else { return nil }
            pass.queue.removeFirst()
            counters.reads &+= 1
            counters.verifications &+= 1
            if plan.facts { counters.factReads &+= 1 }
            mirror.setCounters(counters)
            accept(outcome, of: plan, id: id, member: &member, pass: &pass)
            if pass.abandoned {
                // The read saw another version than the listing did: nothing
                // of it is accepted. The verdict stands and the member is
                // listed again after a short, growing delay.
                pass.churned = true
                member.pass = pass
                members[id] = member
                settle(id)
                return nil
            }
        }
        // Loaded: done. Otherwise the next permitted candidate.
        while pass.loaded == nil, !pass.transport, let candidate = pass.queue.first {
            guard case .present(let signature) = candidate.stat else {
                pass.queue.removeFirst()
                pass.unreadable = true
                continue
            }
            let decision = decide(&member, candidate: candidate, signature: signature, pass: pass)
            // Facts this pass issued itself may have moved the revision.
            pass.opRevision = member.opRevision
            switch decision {
            case .read(let plan):
                member.pass = pass
                members[id] = member
                return plan
            case .loaded:
                pass.loaded = candidate.locator
            case .failed(let verdict):
                pass.queue.removeFirst()
                pass.record(verdict)
            }
        }
        member.pass = pass
        members[id] = member
        settle(id)
        return nil
    }

    private func accept(_ outcome: Result<TranscriptRead, Error>, of plan: ReadPlan, id: String,
                        member: inout Member, pass: inout Pass) {
        switch outcome {
        case .success(let read):
            // A read describes one version of the file. One that only grew
            // since the listing is that version, appended to; a replaced or
            // truncated file is not the candidate that was listed.
            // A read describes one version of the file; it counts only if
            // that is the version the listing stated.
            guard read.signature == plan.signature else {
                pass.abandoned = true
                return
            }
            readDelays.removeValue(forKey: id)
            churnDelays.removeValue(forKey: id)
            churnUntil.removeValue(forKey: id)
            switch read.identity {
            case .verified:
                if member.verified?.locator != plan.locator { member.enrichmentFailed = false }
                member.verified = (plan.locator, read.signature)
                member.failures.removeValue(forKey: plan.locator)
                if plan.facts {
                    member.lastAttempt = (plan.locator, read.signature)
                    guard var summary = read.summary else {
                        // Verified, yet the requested facts did not parse:
                        // the verdict is unreadable and the attempt stands.
                        member.enrichmentFailed = true
                        pass.loaded = plan.locator
                        return
                    }
                    guard summary.id == id, summary.locator == plan.locator else {
                        member.lastAttempt = nil
                        member.verified = nil
                        member.failures[plan.locator] = (read.signature, .mismatch)
                        pass.record(.mismatch)
                        return
                    }
                    member.enrichmentFailed = false
                    member.titleRefresh = false
                    if let used = read.sharedRevision, used < sharedRevision[plan.agent] ?? 0 {
                        // Titles from older shared bytes than the engine has
                        // seen: none of them is offered, and one title-only
                        // read follows.
                        summary = summary.withoutTitles()
                        if member.wanted.contains(.title) { member.titleRefresh = true; pass.requeue = true }
                    }
                    replaceFacts(&member, &pass, authorize(member, locator: plan.locator, agent: plan.agent,
                        signature: read.signature, sharedRevision: read.sharedRevision, summary: summary))
                } else if member.facts == nil {
                    replaceFacts(&member, &pass, authorize(member, locator: plan.locator, agent: plan.agent,
                        signature: read.signature, sharedRevision: nil, summary: nil))
                }
                pass.loaded = plan.locator
            case .mismatch:
                member.failures[plan.locator] = (read.signature, .mismatch)
                if member.verified?.locator == plan.locator { member.verified = nil }
                pass.record(.mismatch)
            case .incomplete:
                member.failures[plan.locator] = (read.signature, .incomplete)
                if member.verified?.locator == plan.locator { member.verified = nil }
                pass.record(.incomplete)
            }
        case .failure(let error):
            switch error as? TranscriptReadError {
            case .missing?:
                // Gone since the listing: located again, so a fallback the
                // selected file was guarding becomes permitted.
                if member.verified?.locator == plan.locator { member.verified = nil }
                pass.requeue = true
            case .unreadable?:
                member.failures[plan.locator] = (plan.signature, .unreadable)
                if member.verified?.locator == plan.locator { member.verified = nil }
                pass.record(.unreadable)
            case .changedDuringRead?:
                pass.churned = true
            case .transport?, nil:
                // The host could not be reached: the verdict stands and the
                // member is tried again after a backoff.
                counters.retries &+= 1
                mirror.setCounters(counters)
                let delay = readDelays[id] ?? 1
                readDelays[id] = min(60, delay * 2)
                pass.transport = true
                deferred[id] = now().addingTimeInterval(delay)
                scheduleTimer()
            }
        }
    }

    /// New facts for a member that already has some carry a new
    /// authorization: the consumer persisted (or is retrying) the old ones,
    /// and must see these as different.
    private func replaceFacts(_ member: inout Member, _ pass: inout Pass, _ next: AuthorizedFacts?) {
        issue(&member, next)
        pass.opRevision = member.opRevision
    }

    /// Facts become the member's current ones. An authorization names one
    /// value only: facts that differ from the last ones issued under the
    /// same authorization (a re-read after the consumer saw the first, or
    /// after they were dropped) get a new operation revision.
    private func issue(_ member: inout Member, _ next: AuthorizedFacts?) {
        guard var next else { return }
        if let issued = member.issued, issued.authorization == next.authorization, issued != next {
            member.opRevision &+= 1
            next = AuthorizedFacts(
                authorization: .init(runEpoch: next.authorization.runEpoch, opRevision: member.opRevision,
                                     incarnation: next.incarnation),
                locator: next.locator, agent: next.agent, signature: next.signature, coverage: next.coverage,
                sharedRevision: next.sharedRevision, summary: next.summary)
        }
        if member.facts != next { snapshotDirty = true }
        member.facts = next
        member.issued = next
    }

    private enum Decision {
        case read(ReadPlan)
        case loaded
        case failed(MemberResolution)
    }

    /// What one present candidate needs: an identity read (with facts when
    /// the budget allows and the row wants them), a facts read for a
    /// verified file, or nothing.
    private func decide(_ member: inout Member, candidate: TranscriptCandidate, signature: TranscriptSignature,
                        pass: Pass) -> Decision {
        let explicit = pass.explicit
        let locator = candidate.locator
        var verified = false
        if let current = member.verified, current.locator == locator {
            if current.signature == signature {
                verified = true
            } else if !member.guardsFacts, current.signature.identity != 0,
                      signature.identity == current.signature.identity, signature.size > current.signature.size {
                // A complete member's transcript appended to (same file,
                // grown): nothing to protect, nothing to read.
                // Accepted limitation (decided): a file rewritten in place
                // to ANOTHER session and grown on the same inode stays
                // loaded here. Header evidence on every append would bring
                // back the per-append read this path exists to avoid; no
                // agent CLI rewrites a transcript into another session in
                // place; and a complete member holds no facts, so nothing
                // of the other session can reach its row.
                member.verified = (locator, signature)
                verified = true
            } else {
                // Any change at all — growth, a same-size rewrite, a new
                // identity — means identity again, and whatever was parsed
                // from it is gone. The parse budget belongs to the member
                // and survives.
                member.verified = nil
                member.enrichmentFailed = false
                member.lastAttempt = nil
            }
        }
        if !verified, !explicit, let cached = member.failures[locator], cached.signature == signature {
            return .failed(cached.verdict)
        }
        let wantsFacts = !member.readOnly && !member.wanted.isEmpty && member.incarnation != nil
        var parse = false
        if wantsFacts {
            if explicit || member.titleRefresh {
                parse = true
            } else if let facts = member.facts, facts.locator == locator, facts.signature == signature, facts.summary != nil {
                parse = false
            } else if member.lastAttempt?.locator == locator && member.lastAttempt?.signature == signature {
                parse = false
            } else if now() < member.nextAttempt {
                deferred[member.id] = member.nextAttempt
                scheduleTimer()
                parse = false
            } else {
                parse = true
            }
        }
        if verified && !parse {
            if member.facts == nil {
                issue(&member, authorize(member, locator: locator, agent: candidate.agent,
                                         signature: signature, sharedRevision: nil, summary: nil))
            }
            return .loaded
        }
        if parse {
            // The budget is charged before the read, even one whose result
            // is discarded. The attempt is recorded only once a read's facts
            // are actually taken (parsed, or found unparseable): a dropped
            // or failed read must not block the retry of an unchanged file.
            member.nextAttempt = now().addingTimeInterval(member.delay)
            member.delay = min(60, member.delay * 2)
        }
        return .read(ReadPlan(locator: locator, agent: candidate.agent, facts: parse, signature: signature,
                              epoch: pass.epoch, opRevision: pass.opRevision, incarnation: pass.incarnation))
    }

    /// Facts for this membership as the engine stands now, or nil when the
    /// row could not use them (or there is no row or incarnation to
    /// authorize a write against, or the database is read-only).
    private func authorize(_ member: Member, locator: TranscriptLocator, agent: Agent, signature: TranscriptSignature,
                           sharedRevision: UInt64?, summary: TranscriptSummary?) -> AuthorizedFacts? {
        guard !member.readOnly, database != nil, let incarnation = member.incarnation,
              locator.host == host, let row = member.row else { return nil }
        let facts = AuthorizedFacts(
            authorization: .init(runEpoch: runEpoch, opRevision: member.opRevision, incarnation: incarnation),
            locator: locator, agent: agent, signature: signature, coverage: coverage,
            sharedRevision: sharedRevision, summary: summary)
        return facts.wouldChange(row) ? facts : nil
    }

    /// The member's verdict from its finished pass: loaded iff a candidate
    /// verified (unreadable when its requested facts did not parse); else
    /// unreadable > mismatch > incomplete > awaiting creation > absent (only
    /// when every listing that could hold it completed) > incomplete. A
    /// transport failure or a pass that must be located again keeps the
    /// verdict it had.
    private func settle(_ id: String) {
        guard var member = members[id], let pass = member.pass else { return }
        member.pass = nil
        let verdict: MemberResolution
        let final = !pass.transport && !pass.requeue && !pass.churned
        if let loaded = pass.loaded {
            verdict = member.enrichmentFailed ? .unreadable : .loaded(loaded)
            member.awaitingCreation = false
        } else if !final {
            verdict = member.everSettled ? member.resolution : (pass.transport ? .incomplete : member.resolution)
        } else if pass.unreadable {
            verdict = .unreadable
        } else if let failure = pass.failure {
            verdict = failure
        } else if member.awaitingCreation {
            verdict = .awaitingCreation
        } else if eligibleAgentsComplete(member) {
            verdict = .confirmedAbsent
        } else {
            verdict = .incomplete
        }
        if pass.loaded == nil, final, member.facts != nil { member.facts = nil; snapshotDirty = true }
        if member.resolution != verdict { snapshotDirty = true }
        member.resolution = verdict
        if final || pass.loaded != nil { member.everSettled = true }
        members[id] = member
        if pass.churned {
            holdForChurn(id)
        } else if pass.requeue {
            enqueue([id])
        }
        resolveAbsenceWaiters(id, absent: final && verdict == .confirmedAbsent)
    }

    /// Absence needs every listing that could hold the member: its agent's,
    /// or every agent's when the row does not know it.
    private func eligibleAgentsComplete(_ member: Member) -> Bool {
        if let agent = member.agent { return complete.contains(agent) }
        return Set(Agent.allCases).isSubset(of: complete)
    }

    // MARK: Timers

    private func scheduleTimer() {
        let due = ([membershipRetryAt].compactMap { $0 } + Array(deferred.values)).min()
        guard let due else { return }
        if let timerDue, timerDue <= due, timerTask != nil { return }
        timerTask?.cancel()
        timerDue = due
        let delay = max(0.01, due.timeIntervalSince(now()))
        let epoch = runEpoch
        timerTask = Task { [weak self, sleep] in
            do { try await sleep(.milliseconds(Int(delay * 1000))) } catch { return }
            await self?.timerFired(epoch: epoch)
        }
    }

    private func timerFired(epoch: UInt64) {
        guard runEpoch == epoch else { return }
        timerTask = nil; timerDue = nil
        fireTimers()
    }

    private func fireTimers() {
        guard running else { return }
        let time = now()
        if let retry = membershipRetryAt, retry <= time, !membershipLoaded {
            membershipRetryAt = nil
            loadMembership()
        }
        let due = Set(deferred.filter { $0.value <= time }.keys)
        for id in due { deferred.removeValue(forKey: id) }
        enqueue(due)
        scheduleTimer()
    }

    // MARK: Publication

    private func publishNow() {
        publishScheduled = false
        guard running, snapshotDirty || published == nil else { return }
        snapshotDirty = false
        let resolutions = members.mapValues(\.resolution)
        let facts = members.compactMapValues(\.facts)
        if let published, published.resolutions == resolutions, published.facts == facts { return }
        generation &+= 1
        let snapshot = EngineSnapshot(generation: generation, resolutions: resolutions, facts: facts)
        published = snapshot
        counters.publications &+= 1
        mirror.setCounters(counters)
        mirror.publish(snapshot)
    }

    /// Coalesces publications for changes nothing is waiting on (facts a
    /// landed fill made unnecessary): a burst of row callbacks is one snapshot.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { [weak self] in await self?.publishNow() }
    }
}

// MARK: - Member state

private struct Member {
    let id: String
    var row: SessionState?
    var agent: Agent?
    var hint: TranscriptLocator?
    var incarnation: String?
    var wanted: Set<SessionCoreField> = []
    var readOnly = true
    var awaitingCreation = false
    var opRevision: UInt64 = 0
    var resolution: MemberResolution = .resolving
    var everSettled = false
    var candidates: [TranscriptCandidate] = []
    var verified: (locator: TranscriptLocator, signature: TranscriptSignature)?
    var failures: [TranscriptLocator: (signature: TranscriptSignature, verdict: MemberResolution)] = [:]
    var lastAttempt: (locator: TranscriptLocator, signature: TranscriptSignature)?
    var nextAttempt = Date.distantPast
    var delay: TimeInterval = 1
    var enrichmentFailed = false
    var titleRefresh = false
    var facts: AuthorizedFacts?
    /// The last facts issued (published or not), to keep one authorization
    /// to one value.
    var issued: AuthorizedFacts?
    var pass: Pass?
    var pendingExplicit = false

    init(id: String) { self.id = id }

    init(row: SessionState, readOnly: Bool) {
        self.id = row.id
        update(row: row, readOnly: readOnly)
    }

    mutating func update(row: SessionState, readOnly: Bool) {
        self.row = row
        agent = row.agent
        hint = row.transcriptPath.map { TranscriptLocator(host: row.host, path: $0) }
        incarnation = row.incarnation
        wanted = row.missingCoreFields
        self.readOnly = readOnly
    }

    /// Whether the conservative rule applies: the member can be given facts
    /// (it wants a field the database lets it fill) or holds some. A
    /// complete member has nothing a stale read could put in its row.
    var guardsFacts: Bool {
        facts != nil || (!readOnly && incarnation != nil && !wanted.isEmpty)
    }

    mutating func resetBudget() {
        delay = 1
        nextAttempt = .distantPast
        lastAttempt = nil
    }
}

private struct Pass {
    let epoch: UInt64
    var opRevision: UInt64
    let incarnation: String?
    let coverage: UInt64
    let explicit: Bool
    var queue: [TranscriptCandidate]
    var loaded: TranscriptLocator?
    var unreadable = false
    var failure: MemberResolution?
    var transport = false
    /// The member must be located again (a file vanished or moved mid-read).
    var requeue = false
    /// The read's file was not the listed candidate; the pass is dropped.
    var abandoned = false
    /// The file kept changing under the read: tried again after a delay.
    var churned = false

    mutating func record(_ verdict: MemberResolution) {
        switch verdict {
        case .unreadable: unreadable = true
        case .mismatch: failure = .mismatch
        default: if failure == nil { failure = verdict }
        }
    }
}

/// The engine as its own tasks see it: never retained by them.
private final class WeakEngine: @unchecked Sendable {
    weak var value: SessionEngine?
    init(_ value: SessionEngine?) { self.value = value }
}

private enum EngineTestError: Error { case injected }

private extension MemberResolution {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}

private extension TranscriptSummary {
    /// The same facts with every title source removed: no title fill at
    /// all, including the first-prompt fallback.
    func withoutTitles() -> TranscriptSummary {
        TranscriptSummary(id: id, agent: agent, locator: locator, modifiedAt: modifiedAt, cwd: cwd,
                          firstPrompt: nil, historyPrompt: nil, createdAt: createdAt, gitBranch: gitBranch,
                          model: model, messageCount: messageCount, lastMessagePreview: lastMessagePreview,
                          originator: originator, recordedTitle: nil, sharedTitle: nil,
                          directoryHint: directoryHint, laterPromptHint: laterPromptHint,
                          legacyTitleHint: legacyTitleHint, selectionKey: selectionKey)
    }
}

// MARK: - Mirror and relay

/// The locked, read-only face of an engine: the latest snapshot, counters,
/// and the snapshot streams. Streams hold this, never the engine.
final class EngineMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EngineSnapshot?
    private var metrics = EngineMetrics()
    private var observers: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var finished = false

    var latest: EngineSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    var counters: EngineMetrics { lock.lock(); defer { lock.unlock() }; return metrics }

    func setCounters(_ value: EngineMetrics) { lock.lock(); metrics = value; lock.unlock() }

    /// Yields under the lock, as registration replays under it: a new
    /// stream can never receive an older snapshot after a newer one.
    func publish(_ next: EngineSnapshot) {
        lock.lock(); defer { lock.unlock() }
        snapshot = next
        observers.values.forEach { $0.yield(next) }
    }

    func clear() { lock.lock(); snapshot = nil; lock.unlock() }

    func stream() -> AsyncStream<EngineSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.observers.removeValue(forKey: token); self.lock.unlock()
            }
            lock.lock(); defer { lock.unlock() }
            if finished { continuation.finish(); return }
            observers[token] = continuation
            if let snapshot { continuation.yield(snapshot) }
        }
    }

    /// The engine is gone: every stream ends.
    func finish() {
        lock.lock(); finished = true; let targets = Array(observers.values); observers.removeAll(); lock.unlock()
        targets.forEach { $0.finish() }
    }
}

/// Database observer registrations made before the engine exists, routed
/// to it weakly: a callback never keeps an engine alive, and each one only
/// asks the engine to re-read the row.
final class EngineRelay: @unchecked Sendable {
    private let database: TempleDB?
    private let lock = NSLock()
    private weak var engine: SessionEngine?
    private var tokens: (join: UUID, leave: UUID, row: UUID)?

    init(database: TempleDB?) { self.database = database }

    func attach(_ engine: SessionEngine) {
        lock.lock(); self.engine = engine; lock.unlock()
        guard let database else { return }
        let join = database.observeJoins { [weak self] id, awaiting in self?.deliver(id, awaiting: awaiting) }
        let leave = database.observeLeaves { [weak self] id in self?.deliver(id, awaiting: false) }
        let row = database.observeRowChanges { [weak self] id in self?.deliver(id, awaiting: false) }
        lock.lock(); tokens = (join, leave, row); lock.unlock()
    }

    private var held: [(String, Bool)]?

    private func deliver(_ id: String, awaiting: Bool) {
        lock.lock()
        if held != nil { held?.append((id, awaiting)); lock.unlock(); return }
        let engine = self.engine
        lock.unlock()
        guard let engine else { return }
        Task { await engine.reconcileMembership(id, awaitingCreation: awaiting) }
    }

    func hold() { lock.lock(); if held == nil { held = [] }; lock.unlock() }

    func release(reversed: Bool) {
        lock.lock(); let pending = held ?? []; held = nil; let engine = self.engine; lock.unlock()
        guard let engine else { return }
        let ordered = reversed ? Array(pending.reversed()) : pending
        Task { for (id, awaiting) in ordered { await engine.reconcileMembership(id, awaitingCreation: awaiting) } }
    }

    func detach() {
        lock.lock(); let registered = tokens; tokens = nil; engine = nil; lock.unlock()
        guard let database, let registered else { return }
        database.removeJoinObserver(registered.join)
        database.removeLeaveObserver(registered.leave)
        database.removeRowChangeObserver(registered.row)
    }
}

public struct EngineMetrics: Sendable, Equatable {
    public var parses: UInt64 = 0
    /// Identity checks the engine received (one per read).
    public var verifications: UInt64 = 0
    /// Reads the engine issued asking for facts (each charged the parse budget).
    public var factReads: UInt64 = 0
    public var publications: UInt64 = 0
    /// Member-affecting transcript observations the engine acted on.
    public var observations: UInt64 = 0
    /// Full walks of every store's listing (startup, coverage resets, and
    /// anything else that cannot trust the filename map).
    public var enumerations: UInt64 = 0
    /// Primitive calls: `locate` round trips, `read`s, and reads that needed a wider head.
    public var locates: UInt64 = 0
    public var reads: UInt64 = 0
    public var widerReads: UInt64 = 0
    /// Reads of an agent's shared inputs (Codex history.jsonl, session_index.jsonl).
    public var sharedTransfers: UInt64 = 0
    /// Operations that failed on transport and wait out a backoff.
    public var retries: UInt64 = 0

    public init(parses: UInt64 = 0, verifications: UInt64 = 0, publications: UInt64 = 0, observations: UInt64 = 0,
                enumerations: UInt64 = 0, locates: UInt64 = 0, reads: UInt64 = 0, widerReads: UInt64 = 0,
                sharedTransfers: UInt64 = 0, retries: UInt64 = 0) {
        self.parses = parses; self.verifications = verifications; self.publications = publications
        self.observations = observations; self.enumerations = enumerations
        self.locates = locates; self.reads = reads; self.widerReads = widerReads
        self.sharedTransfers = sharedTransfers; self.retries = retries
    }
}
