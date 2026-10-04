import Foundation

/// Applies one membership's authorized transcript facts to its row: the
/// hint (verified locator and agent), then the NULL-only core fill, each
/// under the `(id, host, incarnation)` predicate in its own transaction.
/// Pure SQL application — no scheduling, retry or notion of which facts are
/// current; that is `FactCommitter`'s job. The engine never calls this: it
/// only reads the database (ADR-029, Track B C1).
public struct FactPersister: Sendable {
    public let database: TempleDB
    public init(database: TempleDB) { self.database = database }

    /// `.ownershipMismatch` when the row the facts were authorized for is
    /// gone, rejoined (another incarnation) or on another host — nothing is
    /// written then. `.unchanged` is a legitimate NULL-only no-op.
    public func persist(_ id: String, _ facts: AuthorizedFacts) throws -> SessionWriteOutcome {
        // Facts for another session, or a summary of another file, are not
        // this row's — whatever authorized them.
        if let summary = facts.summary, summary.id != id || summary.locator != facts.locator {
            return .ownershipMismatch
        }
        var changed = false
        var fields: Set<SessionCoreField> = []
        switch try database.updateTranscriptHint(sessionID: id, incarnation: facts.incarnation,
                                                 agent: facts.agent, locator: facts.locator) {
        case .ownershipMismatch: return .ownershipMismatch
        case .changed(let hinted): changed = true; fields.formUnion(hinted)
        case .unchanged: break
        }
        if let summary = facts.summary {
            let core = SessionCore(filling: summary)
            switch try database.fillCoreFields(sessionID: id, host: core.host, incarnation: facts.incarnation,
                                               agent: summary.agent, directory: core.directory,
                                               title: core.title, lastActiveAt: core.lastActiveAt) {
            case .ownershipMismatch: return .ownershipMismatch
            case .changed(let filled): changed = true; fields.formUnion(filled)
            case .unchanged: break
            }
        }
        return changed ? .changed(fields) : .unchanged
    }
}

/// The consumer half of the engine's fact contract, shared by the app's
/// overlay and writable `templectl`: persist the latest snapshot's
/// authorized facts, retry a failed write with backoff — and only while the
/// latest snapshot still carries the same facts, under the same
/// authorization, for that id. A snapshot without the id, or with another
/// authorization, revokes them: a pending retry is dropped, never applied
/// late. (The engine never reuses an authorization for different facts;
/// comparing the whole value makes that a checked property here too.)
///
/// Thread-safe; the persist closure runs under the lock (it is a pair of
/// short local transactions).
public final class FactCommitter: @unchecked Sendable {
    public typealias Persist = (String, AuthorizedFacts) throws -> SessionWriteOutcome

    public enum Outcome {
        case written(String, SessionWriteOutcome)
        case failed(String, Error)
        public var id: String {
            switch self { case .written(let id, _), .failed(let id, _): id }
        }
    }

    private struct Pending {
        let facts: AuthorizedFacts
        var due: Date
        var delay: TimeInterval
    }

    private let lock = NSLock()
    private let persist: Persist
    private let now: () -> Date
    private var current: [String: AuthorizedFacts] = [:]
    /// What was persisted per id, compared whole: facts are revoked when the
    /// latest snapshot no longer carries exactly them.
    private var applied: [String: AuthorizedFacts] = [:]
    private var pending: [String: Pending] = [:]

    public init(persist: @escaping Persist, now: @escaping () -> Date = Date.init) {
        self.persist = persist; self.now = now
    }

    public convenience init(database: TempleDB, now: @escaping () -> Date = Date.init) {
        let persister = FactPersister(database: database)
        self.init(persist: { try persister.persist($0, $1) }, now: now)
    }

    /// The latest snapshot's facts, whole. Revokes what it no longer carries
    /// as it was, then persists every newly authorized entry once.
    @discardableResult
    public func receive(_ facts: [String: AuthorizedFacts]) -> [Outcome] {
        lock.lock(); defer { lock.unlock() }
        current = facts
        for (id, entry) in pending where facts[id] != entry.facts {
            pending.removeValue(forKey: id)
        }
        for (id, entry) in applied where facts[id] != entry {
            applied.removeValue(forKey: id)
        }
        var outcomes: [Outcome] = []
        for id in facts.keys.sorted() {
            let entry = facts[id]!
            guard applied[id] != entry, pending[id] == nil else { continue }
            outcomes.append(attemptLocked(id, entry, delay: 1))
        }
        return outcomes
    }

    /// Retries every pending write that is due and still current.
    @discardableResult
    public func retryDue() -> [Outcome] {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        var outcomes: [Outcome] = []
        for id in pending.keys.sorted() {
            guard let entry = pending[id], entry.due <= time else { continue }
            pending.removeValue(forKey: id)
            // Revoked since it failed: never written late.
            guard current[id] == entry.facts else { continue }
            outcomes.append(attemptLocked(id, entry.facts, delay: min(60, entry.delay * 2)))
        }
        return outcomes
    }

    /// When the earliest pending retry is due (nil: nothing pending).
    public var nextRetry: Date? {
        lock.lock(); defer { lock.unlock() }
        return pending.values.map(\.due).min()
    }

    public var pendingIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.keys)
    }

    private func attemptLocked(_ id: String, _ facts: AuthorizedFacts, delay: TimeInterval) -> Outcome {
        do {
            let outcome = try persist(id, facts)
            applied[id] = facts
            return .written(id, outcome)
        } catch {
            pending[id] = Pending(facts: facts, due: now().addingTimeInterval(delay), delay: delay)
            return .failed(id, error)
        }
    }
}

public extension FactCommitter {
    /// Writable `templectl --watch`'s loop: each snapshot's facts are
    /// received as it arrives (persisting what is newly authorized, revoking
    /// what is no longer carried), and due retries run every `interval`,
    /// until the stream ends. `onSnapshot` runs after each receipt.
    func consume(_ snapshots: AsyncStream<EngineSnapshot>, retryEvery interval: Duration = .seconds(1),
                 onSnapshot: (EngineSnapshot) throws -> Void = { _ in }) async rethrows {
        let retries = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.retryDue()
            }
        }
        defer { retries.cancel() }
        for await snapshot in snapshots {
            receive(snapshot.facts)
            try onSnapshot(snapshot)
        }
    }
}
