import Dispatch
import Foundation

/// Owns durable membership and coherent publications for exactly one host.
/// Source operations are serialized; queue mutations also invalidate late replies.
public final class SessionEngine: @unchecked Sendable {
    public let source: any HostSessionSource
    public var host: HostID { source.host }
    private let database: TempleDB?
    private let initialMembers: Set<String>
    private let queue = DispatchQueue(label: "com.sriramb.temple.session-engine")
    private let lock = NSLock()
    private var snapshot: EngineSnapshot?
    private var states: [String: MemberResolution] = [:]
    private var summaries: [String: TranscriptSummary] = [:]
    private var members: Set<String> = []
    private var awaiting: Set<String> = []
    private var wanted: [String: Set<SessionCoreField>]?
    private var generation: UInt64 = 0
    private var runID = UUID()
    private var running = false
    private var changesTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var workTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var stateObservers: [UUID: AsyncStream<[String: MemberResolution]>.Continuation] = [:]
    private var startContinuation: AsyncStream<EngineSnapshot>.Continuation?
    private var joins: UUID?
    private var leaves: UUID?
    private var publications: UInt64 = 0
    private var revisions: [String: UInt64] = [:]
    private var adoptionTasks: [UUID: Task<Void, Never>] = [:]

    public init(source: any HostSessionSource, database: TempleDB? = nil, members: Set<String> = []) {
        self.source = source; self.database = database; self.initialMembers = members
        joins = database?.observeJoins { [weak self = self] id, awaiting in
            self?.resolveRequest(id, awaitingCreation: awaiting, explicit: false)
        }
        leaves = database?.observeLeaves { [weak self = self] id in self?.forgetMember(id) }
    }
    deinit {
        if let joins { database?.removeJoinObserver(joins) }
        if let leaves { database?.removeLeaveObserver(leaves) }
        changesTask?.cancel(); workTask?.cancel()
        workTasks.values.forEach { $0.cancel() }
        adoptionTasks.values.forEach { $0.cancel() }
    }
    public func resolution(for id: String) -> MemberResolution? {
        lock.lock(); defer { lock.unlock() }; return snapshot?.resolutions[id]
    }
    public var publishedSnapshot: EngineSnapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }
    public var isMonitoring: Bool { (source as? any HostSourceDiagnostics)?.isMonitoring ?? source.capabilities.contains(.liveChanges) }
    public var metrics: EngineMetrics {
        var result = (source as? any HostSourceDiagnostics)?.metrics ?? EngineMetrics()
        lock.lock(); result.publications = publications; lock.unlock()
        return result
    }
    public func snapshots() -> AsyncStream<EngineSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self = self] _ in
                self?.queue.async { [weak self = self] in self?.observers.removeValue(forKey: token) }
            }
            queue.async {
                self.observers[token] = continuation
                if let snapshot = self.publishedSnapshot { continuation.yield(snapshot) }
            }
        }
    }
    public func resolutionUpdates() -> AsyncStream<[String: MemberResolution]> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self = self] _ in
                self?.queue.async { [weak self = self] in self?.stateObservers.removeValue(forKey: token) }
            }
            queue.async { self.stateObservers[token] = continuation; continuation.yield(self.states) }
        }
    }
    public func start() -> AsyncStream<EngineSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self = self] _ in
                self?.queue.async { [weak self = self] in
                    if self?.runID == token { self?.stopLocked() }
                }
            }
            queue.async {
                self.stopLocked(preservePrestart: !self.running)
                self.runID = token; self.running = true; self.startContinuation = continuation
                self.members.formUnion(self.initialMembers)
                if let database = self.database {
                    do { self.members = Set(try database.sessionStates(host: self.host).map(\.id)) }
                    catch { self.publishLocked(); return }
                }
                for id in self.members { self.states[id] = self.awaiting.contains(id) ? .awaitingCreation : .resolving }
                // changes() arms local observation before the first resolve enumeration.
                let changes = self.source.changes()
                self.changesTask = Task { [weak self = self] in
                    do {
                        for try await change in changes {
                            guard !Task.isCancelled else { break }
                            self?.queue.async { [weak self = self] in
                                guard let self, self.running, self.runID == token else { return }
                                switch change {
                                case .sessions(let ids): self.enqueueLocked(Set(ids).intersection(self.members))
                                case .coverageReset(let generation):
                                    guard generation > self.generation else { return }
                                    self.generation = generation
                                    self.enqueueLocked(self.members)
                                case .sharedTitlesChanged: self.enqueueLocked(self.members)
                                }
                            }
                        }
                    } catch {
                        self?.queue.async { [weak self = self] in
                            guard let self, self.running, self.runID == token else { return }
                            for id in self.members { self.states[id] = .incomplete; self.summaries.removeValue(forKey: id) }
                            self.publishLocked()
                        }
                    }
                }
                self.enqueueLocked(self.members, includeEmpty: true)
            }
        }
    }
    public func stop() { queue.async { [weak self = self] in self?.stopLocked() } }
    private func stopLocked(preservePrestart: Bool = false) {
        running = false; runID = UUID()
        changesTask?.cancel(); changesTask = nil
        workTasks.values.forEach { $0.cancel() }; workTasks.removeAll(); workTask = nil
        if !preservePrestart { adoptionTasks.values.forEach { $0.cancel() }; adoptionTasks.removeAll(); awaiting.removeAll() }
        source.release(Array(members)); members.removeAll(); states.removeAll(); summaries.removeAll()
        startContinuation?.finish(); startContinuation = nil
        lock.lock(); snapshot = nil; lock.unlock()
    }
    public func requestResolution(_ id: String, awaitingCreation: Bool = false) {
        resolveRequest(id, awaitingCreation: awaitingCreation, explicit: true)
    }
    private func resolveRequest(_ id: String, awaitingCreation: Bool, explicit: Bool) {
        queue.async {
            if let database = self.database {
                guard let row = try? database.sessionState(id), row.host == self.host else { return }
            } else if !self.initialMembers.contains(id) { return }
            self.members.insert(id)
            if awaitingCreation { self.awaiting.insert(id) }
            if self.states[id] == nil || awaitingCreation { self.states[id] = awaitingCreation ? .awaitingCreation : .resolving }
            if self.running { self.enqueueLocked([id], explicit: explicit) }
        }
    }
    public func forgetMember(_ id: String) {
        queue.async {
            if let database = self.database {
                do { if let row = try database.sessionState(id), row.host == self.host { return } }
                catch { return }
            }
            self.members.remove(id); self.awaiting.remove(id)
            self.revisions[id, default: 0] &+= 1
            self.states.removeValue(forKey: id); self.summaries.removeValue(forKey: id)
            self.source.release([id])
            if self.running { self.publishLocked() }
        }
    }
    public func setEnrichmentWanted(_ missing: [String: Set<SessionCoreField>]) {
        queue.async {
            let old = self.wanted; self.wanted = missing
            if self.running {
                let changed = self.members.filter { old?[$0] != missing[$0] }
                self.enqueueLocked(Set(changed))
            }
        }
    }
    private func enqueueLocked(_ ids: Set<String>, explicit: Bool = false, includeEmpty: Bool = false) {
        guard running, !ids.isEmpty || includeEmpty else { return }
        let token = runID
        let requestedGeneration = generation
        let requests = ids.sorted().compactMap { id -> ResolutionRequest? in
            let row = try? database?.sessionState(id)
            if database != nil && row?.host != host { return nil }
            var missing = Set<SessionCoreField>()
            if let wanted { missing = wanted[id] ?? [] }
            else {
                if row?.agent == nil { missing.insert(.agent) }
                if row?.directory == nil { missing.insert(.directory) }
                if row?.title == nil { missing.insert(.title) }
                if row?.lastActiveAt == nil { missing.insert(.lastActiveAt) }
            }
            return ResolutionRequest(id: id, agent: row?.agent,
                hint: row?.transcriptPath.map { TranscriptLocator(host: host, path: $0) },
                wanted: missing, awaitingCreation: awaiting.contains(id), explicit: explicit)
        }
        let versions = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, revisions[$0.id, default: 0]) })
        let preceding = workTask
        let operation = UUID()
        workTask = Task { [weak self = self, source] in
            defer { self?.queue.async { [weak self = self] in self?.workTasks.removeValue(forKey: operation) } }
            await preceding?.value
            guard !Task.isCancelled else { return }
            do {
                let batch = try await source.resolve(requests)
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self = self] in
                    guard let self, self.running, self.runID == token, batch.generation >= self.generation else { return }
                    self.generation = batch.generation
                    for request in requests where self.members.contains(request.id) && self.revisions[request.id, default: 0] == versions[request.id] {
                        let id = request.id
                        let result = batch.results[id] ?? .incomplete
                        self.summaries.removeValue(forKey: id)
                        switch result {
                        case .loaded(let locator, let summary, _):
                            guard locator.host == self.host, summary == nil || summary?.locator.host == self.host && summary?.id == id else {
                                self.states[id] = .mismatch; continue
                            }
                            self.states[id] = .loaded(locator)
                            self.awaiting.remove(id)
                            if let summary { self.summaries[id] = summary }
                            if let database = self.database, database.isReadOnly != true,
                               let row = try? database.sessionState(id),
                               let agent = summary?.agent ?? request.agent,
                               row.transcriptPath != locator.path || row.agent == nil {
                                try? database.updateTranscriptHint(sessionID: id, agent: agent,
                                    locator: locator)
                            }
                        case .absent: self.states[id] = .confirmedAbsent
                        case .awaitingCreation: self.states[id] = .awaitingCreation
                        case .unreadable: self.states[id] = .unreadable
                        case .incomplete: self.states[id] = .incomplete
                        case .mismatch: self.states[id] = .mismatch
                        }
                    }
                    self.publishLocked()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.queue.async { [weak self = self] in
                    guard let self, self.running, self.runID == token, self.generation <= requestedGeneration else { return }
                    for request in requests where self.members.contains(request.id) && self.revisions[request.id, default: 0] == versions[request.id] {
                        self.states[request.id] = .incomplete; self.summaries.removeValue(forKey: request.id)
                    }
                    self.publishLocked()
                }
            }
        }
        workTasks[operation] = workTask
    }
    private func publishLocked() {
        guard running else { return }
        let next = EngineSnapshot(generation: generation, resolutions: states, summaries: summaries)
        lock.lock()
        let changed = next != snapshot
        if changed { snapshot = next; publications &+= 1 }
        lock.unlock()
        guard changed else { return }
        startContinuation?.yield(next)
        observers.values.forEach { $0.yield(next) }
        stateObservers.values.forEach { $0.yield(states) }
    }
    /// Revalidate catalog facts through the same semantic seam. Temporary interest
    /// is released only if no committed join acquired the id during the read.
    public func summaryForImport(_ summary: TranscriptSummary) async -> TranscriptSummary? {
        guard summary.locator.host == host else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let preceding = self.workTask
                let operation = UUID()
                self.workTask = Task { [weak self = self, source = self.source] in
                    defer { self?.queue.async { [weak self = self] in self?.workTasks.removeValue(forKey: operation) } }
                    await preceding?.value
                    var facts: TranscriptSummary?
                    if !Task.isCancelled {
                        let request = ResolutionRequest(id: summary.id, agent: summary.agent, hint: summary.locator,
                            wanted: [.agent, .directory, .title, .lastActiveAt], explicit: true)
                        if let batch = try? await source.resolve([request]),
                           case .loaded(let locator, let result, _) = batch.results[summary.id],
                           locator.host == summary.locator.host, result?.id == summary.id,
                           result?.locator.host == summary.locator.host {
                            facts = result
                        }
                    }
                    let result = Task.isCancelled ? nil : facts
                    guard let self else { source.release([summary.id]); continuation.resume(returning: nil); return }
                    self.queue.async {
                        if !self.members.contains(summary.id) { source.release([summary.id]) }
                        continuation.resume(returning: result)
                    }
                }
                self.workTasks[operation] = self.workTask
            }
        }
    }

    public func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult {
        let cancellation = EngineCancellation()
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.adoptionTasks[token] = Task { [weak self = self, source = self.source] in
                        defer { self?.queue.async { [weak self = self] in self?.adoptionTasks.removeValue(forKey: token) } }
                        do {
                            let result = try await source.adopt(request)
                            try Task.checkCancellation()
                            continuation.resume(returning: result)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { self.adoptionTasks[token]?.cancel() }
        }
    }
    public func registerAdoption(projectPath: String, startedAt: Date, window: TimeInterval = 5,
                                 completion: @escaping @Sendable (CodexRolloutCandidate?) -> Void) {
        let token = UUID()
        queue.async {
            self.adoptionTasks[token] = Task { [weak self = self, source = self.source] in
                let request = AdoptionRequest(directory: projectPath, startedAt: startedAt, window: window)
                let result = try? await source.adopt(request)
                guard !Task.isCancelled else { return }
                if case .adopted(let id, let locator) = result, let url = locator.localURL {
                    completion(CodexRolloutCandidate(sessionID: id, cwd: projectPath, createdAt: startedAt, filePath: url))
                } else { completion(nil) }
                self?.queue.async { [weak self = self] in self?.adoptionTasks.removeValue(forKey: token) }
            }
        }
    }
}

public struct EngineMetrics: Sendable {
    public var parses: UInt64 = 0
    public var verifications: UInt64 = 0
    public var publications: UInt64 = 0
    public var observations: UInt64 = 0
}

private final class EngineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
