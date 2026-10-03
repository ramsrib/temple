import Dispatch
import Foundation
import CoreServices

/// Local observation, selection, verification and enrichment. Registered interests
/// come from the engine; this source never reads or writes Temple registeredIDship.
public final class LocalSessionSource: HostSessionSource, HostSourceDiagnostics, @unchecked Sendable {
    public let host = HostID.local
    public let capabilities: Set<HostCapability> = [.liveChanges, .revealInFinder, .catalog]
    private var interests: [String: ResolutionRequest] = [:]
    private var changeContinuations: [UUID: AsyncThrowingStream<SourceChange, Error>.Continuation] = [:]
    private let stores: [any IncrementalSessionStore]
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sriramb.temple.local-source")
    private var stream: FSEventStreamRef?
    private var running = false
    private var roots: [RootMapping] = []
    private var files: [String: (URL, Agent)] = [:]
    private var pathsByID: [String: Set<String>] = [:]
    private var memberIDsByPath: [String: Set<String>] = [:]
    private var hintPathsByID: [String: String] = [:]
    private var selectedCodexPaths: [String: (path: String, key: String)] = [:]
    private var registeredIDs: Set<String> = []
    private var awaiting: Set<String> = []
    private var states: [String: MemberResolution] = [:]
    private var statesDirty = false
    private var summaries: [String: TranscriptSummary] = [:]
    private var generation: UInt64 = 0
    private var contentDirty = false
    private var changedIDs: Set<String> = []
    private var signatures: [String: FileSignature] = [:] // last observed, including stat-only writes
    private var memberWork: [String: MemberWork] = [:]
    private var enrichmentTimers: [String: DispatchWorkItem] = [:]
    private let now: @Sendable () -> Date
    private let monitorChanges: Bool
    private var parseCount: UInt64 = 0
    private var verificationCount: UInt64 = 0
    private var observedCount: UInt64 = 0
    private var snapshotMetrics = EngineMetrics()

    private let snapshotLock = NSLock()
    private var snapshotMonitoring = false
    private var adoptionTimers: [UUID: DispatchWorkItem] = [:]
    private var unresolvedCandidates: Set<String> = []
    private var enumerationSucceeded = true
    private var enumerationByAgent: [Agent: Bool] = [:]
    private var streamID: UUID?
    private var pendingPaths: Set<String> = []
    private var work: DispatchWorkItem?
    private var requests: [UUID: LocalAdoptionWindow] = [:]
    private var candidates: [String: CodexRolloutCandidate] = [:]
    // Keep competitors seen anywhere in an active window, even if a later
    // sweep no longer finds their files. Overflow refuses the decision.
    private var seenCandidates: [String: CodexRolloutCandidate] = [:]
    private var candidateSignatures: [String: FileSignature] = [:]
    private var claimed: [String: Date] = [:]
    private static let candidateCacheLimit = 512
    private static let adoptionRequestLimit = 128
    private let rolloutDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    public init(stores: [any IncrementalSessionStore] = [ClaudeSessionStore(), CodexSessionStore()],
                debounceInterval: TimeInterval = 0.3,
                monitorChanges: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.stores = stores
        self.debounceInterval = debounceInterval
        self.now = now
        self.monitorChanges = monitorChanges
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }
    public var isMonitoring: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshotMonitoring
    }
    private var monitoring = false

    public func changes() -> AsyncThrowingStream<SourceChange, Error> {
        let token = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self = self] _ in
                self?.queue.async { [weak self = self] in
                    guard let self else { return }
                    self.changeContinuations.removeValue(forKey: token)
                    self.stopIfIdleLocked()
                }
            }
            queue.async { [weak self = self] in
                guard let self else { continuation.finish(); return }
                self.changeContinuations[token] = continuation
                self.startLocked()
            }
        }
    }

    public func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch {
        let ticket = AdoptionTicket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResolutionBatch, Error>) in
                queue.async {
                    guard !ticket.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.startLocked()
                    for request in requests {
                        guard !ticket.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                        let id = request.id
                        let previous = self.interests[id]
                        self.interests[id] = request
                        self.registeredIDs.insert(id)
                        if request.awaitingCreation { self.awaiting.insert(id) }
                        let filled = previous.map { !$0.wanted.subtracting(request.wanted).isEmpty } ?? false
                        if request.explicit || previous == nil || filled { self.resetEnrichmentLocked(id) }
                        self.resolveLocked(id, explicit: request.explicit || filled)
                        if request.explicit && (self.states[id] == .confirmedAbsent || self.states[id] == .resolving) {
                            self.enumerateLocked(); self.resolveLocked(id, explicit: true)
                        }
                    }
                    self.snapshotLocked()
                    var results: [String: ResolutionResult] = [:]
                    for request in requests {
                        let id = request.id
                        switch self.states[id] ?? .incomplete {
                        case .loaded(let locator):
                            let summary = self.summaries[id]
                            var missing = request.wanted
                            if let summary {
                                missing.remove(.agent); missing.remove(.lastActiveAt)
                                if summary.cwd != nil { missing.remove(.directory) }
                                if summary.firstPrompt != nil || summary.historyPrompt != nil { missing.remove(.title) }
                            }
                            results[id] = .loaded(locator, summary, missing)
                        case .confirmedAbsent: results[id] = .absent
                        case .awaitingCreation: results[id] = .awaitingCreation
                        case .unreadable: results[id] = .unreadable
                        case .mismatch: results[id] = .mismatch
                        case .resolving, .incomplete: results[id] = .incomplete
                        }
                    }
                    // A request reads the latest local state; no redundant invalidation.
                    self.changedIDs.subtract(requests.map(\.id))
                    self.contentDirty = !self.changedIDs.isEmpty
                    if ticket.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(returning: ResolutionBatch(generation: self.generation, results: results)) }
                }
            }
        } onCancel: { ticket.cancel() }
    }

    public func release(_ ids: [String]) {
        for id in ids { forgetMember(id) }
    }

    public func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        let catalog = LocalSessionCatalog(stores: stores.filter { query.agents.contains($0.agent) })
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in catalog.stream(batchSize: query.batchSize, newestFirst: query.newestFirst) {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func setStateLocked(_ id: String, to state: MemberResolution) {
        if case .loaded = state { awaiting.remove(id) }
        guard states[id] != state else { return }
        states[id] = state; statesDirty = true; changedIDs.insert(id)
    }

    private func snapshotLocked() {
        snapshotLock.lock()
        if statesDirty { statesDirty = false; contentDirty = true }
        snapshotMonitoring = monitoring
        snapshotMetrics = EngineMetrics(parses: parseCount, verifications: verificationCount,
            publications: 0, observations: observedCount)
        snapshotLock.unlock()
    }

    private func emitChangesLocked() {
        snapshotLocked()
        guard running, contentDirty else { return }
        contentDirty = false
        let ids = changedIDs.intersection(registeredIDs).sorted()
        changedIDs.removeAll()
        guard !ids.isEmpty else { return }
        for continuation in changeContinuations.values { continuation.yield(.sessions(ids)) }
    }

    private func startLocked() {
        guard !running else { return }
        running = true
        streamID = UUID()
        generation &+= 1
        // Arm before enumeration. Callbacks buffer behind the scan on this queue.
        armLocked()
        enumerateLocked()
        if !requests.isEmpty {
            for requestID in requests.keys { scheduleAdoptionDeadlineLocked(requestID) }
            sweepCandidatesLocked()
        }
        snapshotLocked()
    }

    private func stopIfIdleLocked() {
        if changeContinuations.isEmpty && registeredIDs.isEmpty && requests.isEmpty { stopLocked() }
    }

    private func stopLocked(preservePrestart: Bool = false) {
        if !preservePrestart {
            adoptionTimers.values.forEach { $0.cancel() }; adoptionTimers.removeAll()
            for request in requests.values where !request.decided { request.completion(.incomplete) }
            requests.removeAll(); candidates.removeAll(); seenCandidates.removeAll(); candidateSignatures.removeAll()
            unresolvedCandidates.removeAll(); awaiting.removeAll()
        }
        running = false
        monitoring = false
        work?.cancel(); work = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamID = nil
        pendingPaths.removeAll()
        files.removeAll(); pathsByID.removeAll(); memberIDsByPath.removeAll()
        hintPathsByID.removeAll(); selectedCodexPaths.removeAll()
        signatures.removeAll(); summaries.removeAll(); memberWork.removeAll()
        enrichmentTimers.values.forEach { $0.cancel() }; enrichmentTimers.removeAll()
        interests.removeAll(); registeredIDs.removeAll(); changedIDs.removeAll()
        states.removeAll(); statesDirty = true; snapshotLocked()
    }

    /// Release observation state without disturbing the filename map.
    private func forgetMember(_ id: String) {
        queue.async { [weak self = self] in
            guard let self, self.registeredIDs.contains(id) else { return }
            self.interests.removeValue(forKey: id)
            self.registeredIDs.remove(id)
            self.awaiting.remove(id)
            self.memberWork.removeValue(forKey: id)
            self.enrichmentTimers.removeValue(forKey: id)?.cancel()
            self.summaries.removeValue(forKey: id)
            self.signatures.removeValue(forKey: id)
            self.hintPathsByID.removeValue(forKey: id)
            for path in Array(self.memberIDsByPath.keys) {
                self.memberIDsByPath[path]?.remove(id)
                if self.memberIDsByPath[path]?.isEmpty == true { self.memberIDsByPath.removeValue(forKey: path) }
            }
            self.states.removeValue(forKey: id)
            self.statesDirty = true
            self.snapshotLocked()
            guard self.running else { return }
            self.publishLocked()
            self.stopIfIdleLocked()
        }
    }

    private func armLocked() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots = stores.flatMap(\.watchedURLs).map(RootMapping.init)
        // Enumeration-only control for the synthetic benchmark: startup still
        // resolves rows, but no filesystem events can reach the engine.
        guard monitorChanges else { return }
        let requestedPaths = Set(roots.flatMap { [$0.watchPhysical, $0.watchLogical] })
        let paths = requestedPaths.filter { path in
            !requestedPaths.contains { other in other != path && path.hasPrefix(other + "/") }
        }
        let relay = EventRelay(self)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<EventRelay>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<EventRelay>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            guard let watcher = Unmanaged<EventRelay>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            let paths = unsafeBitCast(rawPaths, to: NSArray.self)
            var batch: [String: FSEventStreamEventFlags] = [:]
            for i in 0..<count {
                if let path = paths[i] as? String { batch[path, default: 0] |= flags[i] }
            }
            for (path, flags) in batch { watcher.eventLocked(path, flags: flags) }
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
            Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            max(0.01, debounceInterval),
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        else {
            enumerationSucceeded = false
            TempleCoreLog.watcher.error("FSEvents stream could not be created")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        monitoring = FSEventStreamStart(created)
        if !monitoring {
            enumerationSucceeded = false
            TempleCoreLog.watcher.error("FSEvents stream failed to start")
        }
    }

    /// Deterministic recovery seam; production and tests use the same classifier.
    func reconcileEvent(path: String, flags: FSEventStreamEventFlags) {
        queue.async { [weak self = self] in self?.eventLocked(path, flags: flags) }
    }

    private func eventLocked(_ rawPath: String, flags: FSEventStreamEventFlags) {
        guard running else { return }
        func has(_ flag: Int) -> Bool { flags & UInt32(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { return }
        let dropped = has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
        let rootChanged = has(kFSEventStreamEventFlagRootChanged)
        let path = logicalPath(rawPath)
        let rootLocation = path.map { p in roots.contains { $0.logical == p || $0.logical.hasPrefix(p + "/") } } ?? false
        if dropped || rootChanged || rootLocation {
            armLocked(); recoverLocked(resetCoverage: dropped || rootChanged); return
        }
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if ["history.jsonl", "session_index.jsonl"].contains(url.lastPathComponent),
           stores.contains(where: { store in
               guard let codex = store as? CodexSessionStore else { return false }
               return SessionPaths.normalized(codex.sessionsRoot.deletingLastPathComponent().path) == url.deletingLastPathComponent().path
           }) {
            for continuation in changeContinuations.values { continuation.yield(.sharedTitlesChanged) }
            return
        }
        // Codex sqlite/WAL/log traffic is rejected before stat or resolution.
        let isTranscript = stores.contains { $0.acceptsTranscript(url) }
        let directory = has(kFSEventStreamEventFlagItemIsDir)
        let scan = has(kFSEventStreamEventFlagMustScanSubDirs)
        if directory || scan {
            // Claude project dirs and Codex sessions descendants are relevant;
            // unrelated Codex log directories never start a history walk.
            let relevant = stores.contains { store in
                if let codex = store as? CodexSessionStore {
                    let sessionsRoot = SessionPaths.normalized(codex.sessionsRoot.path)
                    return path == sessionsRoot || path.hasPrefix(sessionsRoot + "/")
                }
                return store.watchedURLs.contains {
                    let root = SessionPaths.normalized($0.path)
                    return path == root || path.hasPrefix(root + "/")
                }
            }
            if relevant { recoverLocked(subtree: path) }
            return
        }
        guard isTranscript else { return }
        let hintedMember = memberIDsByPath[path]?.isEmpty == false
        let filenameMember = stores.contains { store in
            store.acceptsTranscript(url) && store.filenameID(at: url).map { registeredIDs.contains($0) } == true
        }
        guard hintedMember || filenameMember || (stores.contains { $0.agent == .codex && $0.acceptsTranscript(url) } && !requests.isEmpty) else { return }
        pendingPaths.insert(path)
        scheduleLocked()
    }

    private func logicalPath(_ raw: String) -> String? {
        let path = RootMapping.alias(raw)
        for root in roots.sorted(by: { $0.physical.count > $1.physical.count }) {
            if path == root.physical || path.hasPrefix(root.physical + "/") {
                return root.logical + path.dropFirst(root.physical.count)
            }
            if path == root.logical || path.hasPrefix(root.logical + "/") { return path }
            if root.logical.hasPrefix(path + "/") { return path }
        }
        return nil
    }

    private func scheduleLocked() {
        guard work == nil else { return }
        let item = DispatchWorkItem { [weak self = self] in
            guard let self, self.running else { return }
            self.work = nil
            let paths = self.pendingPaths; self.pendingPaths.removeAll()
            var changed = false
            for path in paths {
                if self.reconcileFileLocked(URL(fileURLWithPath: path)) { changed = true }
            }
            if changed { self.publishLocked() }
            else { self.emitChangesLocked() }
        }
        work = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func enumerateLocked(subtree: String? = nil) {
        var next: [String: (URL, Agent)] = subtree.map { prefix in
            files.filter { !$0.key.hasPrefix(prefix + "/") }
        } ?? [:]
        for store in stores {
            if let subtree, !store.watchedURLs.contains(where: {
                let root = SessionPaths.normalized($0.path)
                return root == subtree || root.hasPrefix(subtree + "/") || subtree.hasPrefix(root + "/")
            }) { continue }
            do {
                let listed = try subtree.map { try store.enumerateSessionFiles(in: URL(fileURLWithPath: $0)) } ?? store.enumerateSessionFiles()
                // A subtree proves only its own coverage, never recovery of
                // an earlier failed full-store filename lookup.
                if subtree == nil { enumerationByAgent[store.agent] = true }
                for file in listed {
                    let url = URL(fileURLWithPath: logicalPath(file.path) ?? RootMapping.alias(file.path))
                    next[url.path] = (url, store.agent)
                }
            } catch {
                enumerationByAgent[store.agent] = false
                // Preserve the last map for this agent; failed listing proves no absence.
                for (path, entry) in files where entry.1 == store.agent { next[path] = entry }
                TempleCoreLog.watcher.error("enumeration failed: \(String(describing: error), privacy: .public)")
            }
        }
        enumerationSucceeded = enumerationByAgent.values.allSatisfy { $0 }
        files = next
        pathsByID.removeAll(); selectedCodexPaths.removeAll()
        for (path, entry) in files {
            if let store = stores.first(where: { $0.agent == entry.1 }) { _ = recordFilenameLocked(path, store: store) }
        }
    }

    @discardableResult
    private func recordFilenameLocked(_ path: String, store: any IncrementalSessionStore) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let id = store.filenameID(at: url) else { return nil }
        pathsByID[id, default: []].insert(path)
        if store.agent == .codex, let key = store.rolloutSelectionKey(at: url) {
            if let old = selectedCodexPaths[id], key < old.key || (key == old.key && path <= old.path) { return id }
            selectedCodexPaths[id] = (path, key)
        }
        return id
    }

    private func trackHintLocked(_ id: String, path: String?) {
        guard hintPathsByID[id] != path else { return }
        if let old = hintPathsByID.removeValue(forKey: id) {
            memberIDsByPath[old]?.remove(id)
            if memberIDsByPath[old]?.isEmpty == true { memberIDsByPath.removeValue(forKey: old) }
        }
        if let path {
            hintPathsByID[id] = path
            memberIDsByPath[path, default: []].insert(id)
        }
    }

    private func recoverLocked(subtree: String? = nil, resetCoverage: Bool = false) {
        if resetCoverage {
            generation &+= 1; contentDirty = true
            for continuation in changeContinuations.values { continuation.yield(.coverageReset(generation)) }
        }
        enumerateLocked(subtree: subtree)
        for id in registeredIDs {
            if let subtree {
                let mapped = (pathsByID[id] ?? []).contains { $0.hasPrefix(subtree + "/") }
                let old = memberWork[id]?.path.hasPrefix(subtree + "/") == true
                let hinted = interests[id]?.hint?.path.hasPrefix(subtree + "/") == true
                if !mapped && !old && !hinted { continue }
            }
            if resetCoverage { resetEnrichmentLocked(id) }
            resolveLocked(id, explicit: resetCoverage)
        }
        if !requests.isEmpty { sweepCandidatesLocked(subtree: subtree) }
        publishLocked()
    }

    private func resolveLocked(_ id: String, explicit: Bool = false, rescannedMissing: Bool = false) {
        guard registeredIDs.contains(id) else { return }
        let row = interests[id]
        // A committed hint can name a new revert that arrived while this ID
        // was still outside Temple. Include its filename before choosing the
        // thread's active rollout, without enumerating or reading other logs.
        if let hint = row?.hint?.path, let agent = row?.agent,
           let store = stores.first(where: { $0.agent == agent }) {
            let path = logicalPath(hint) ?? RootMapping.alias(hint)
            let url = URL(fileURLWithPath: path)
            if store.acceptsTranscript(url), pathsByID[id]?.contains(path) != true,
               store.filenameID(at: url) == id, (try? FileSignature(url)) != nil {
                files[path] = (url, agent)
                _ = recordFilenameLocked(path, store: store)
            }
        }
        var selectedPath = selectedCodexPaths[id]?.path
        var paths: Set<String> = selectedPath.map { [$0] } ?? pathsByID[id] ?? []
        var preferredPath: String?
        if let row, let hint = row.hint?.path {
            let path = logicalPath(hint) ?? RootMapping.alias(hint)
            if let agent = row.agent, let store = stores.first(where: { $0.agent == agent }),
               store.acceptsTranscript(URL(fileURLWithPath: path)) {
                files[path] = (URL(fileURLWithPath: path), agent)
                preferredPath = path
                // An older canonical Codex hint must not override thread/revert.
                if selectedPath == nil || selectedPath == path || store.filenameID(at: URL(fileURLWithPath: path)) != id {
                    paths.insert(path)
                }
                trackHintLocked(id, path: path)
            }
        }
        if preferredPath == nil { trackHintLocked(id, path: nil) }
        if let loaded = memberWork[id], selectedPath == nil || loaded.path == selectedPath {
            paths.insert(loaded.path)
        }
        var unreadable = false
        var available: [(String, FileSignature)] = []
        for path in paths {
            do { available.append((path, try FileSignature(URL(fileURLWithPath: path)))) }
            catch {
                if !Self.isMissing(error) { unreadable = true }
                else if path == selectedPath {
                    // Deletion is the only event that needs a thread-local
                    // rescan of older names. Ordinary writes use the cached pick.
                    pathsByID[id]?.remove(path); files.removeValue(forKey: path)
                    selectedCodexPaths.removeValue(forKey: id); selectedPath = nil
                    if let store = stores.first(where: { $0.agent == .codex }) {
                        let remaining = (pathsByID[id] ?? []).compactMap { path -> (path: String, key: String)? in
                            guard let key = store.rolloutSelectionKey(at: URL(fileURLWithPath: path)) else { return nil }
                            return (path, key)
                        }.sorted { $0.key == $1.key ? $0.path > $1.path : $0.key > $1.key }
                        for candidate in remaining {
                            do {
                                let signature = try FileSignature(URL(fileURLWithPath: candidate.path))
                                selectedCodexPaths[id] = candidate; selectedPath = candidate.path
                                available.append((candidate.path, signature)); break
                            } catch {
                                if Self.isMissing(error) {
                                    pathsByID[id]?.remove(candidate.path); files.removeValue(forKey: candidate.path)
                                } else {
                                    selectedCodexPaths[id] = candidate; selectedPath = candidate.path
                                    unreadable = true; break
                                }
                            }
                        }
                    }
                }
            }
        }
        // The cached filename pick comes first. Any separate validated hint
        // remains a fallback; older canonical rollouts were excluded above.
        let ordered = available.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return false }
            if lhs.0 == selectedPath { return true }
            if rhs.0 == selectedPath { return false }
            if lhs.0 == preferredPath { return true }
            if rhs.0 == preferredPath { return false }
            return lhs.0 < rhs.0
        }
        var failure: MemberResolution?
        for (path, signature) in ordered {
            guard let entry = files[path], let store = stores.first(where: { $0.agent == entry.1 }) else { continue }
            observedCount &+= 1
            let previous = signatures[id]
            var work = memberWork[id] ?? MemberWork(path: path)
            let invalidate = work.path != path || previous?.fileNumber != signature.fileNumber
                || signature.size < (previous?.size ?? 0)
            if invalidate {
                // Identity belongs to the selected file; the parse budget belongs
                // to the member and survives replacements, truncation and reverts.
                work.path = path
                work.verified = false
                work.verificationFailure = nil
                work.lastAttempt = nil
                work.enrichmentFailed = false
                summaries.removeValue(forKey: id)
            }
            signatures[id] = signature
            memberWork[id] = work
            if !work.verified {
                if !explicit, previous == signature, let cachedFailure = work.verificationFailure {
                    if cachedFailure == .unreadable { unreadable = true }
                    else { failure = failure ?? cachedFailure }
                    continue
                }
                verificationCount &+= 1
                do {
                    let verdict = try store.verifyIdentity(at: entry.0, expectedID: id)
                    guard try FileSignature(entry.0) == signature else {
                        work.verified = false; memberWork[id] = work
                        pendingPaths.insert(path); scheduleLocked(); continue
                    }
                    switch verdict {
                    case .verified: work.verified = true; work.verificationFailure = nil
                    case .incomplete: failure = failure ?? .incomplete; work.verificationFailure = .incomplete
                    case .mismatch: failure = .mismatch; work.verificationFailure = .mismatch
                    }
                } catch { unreadable = true; work.verificationFailure = .unreadable }
                memberWork[id] = work
                guard work.verified else { continue }
            }
            // Path authority changes after verification, even when all core fields exist.
            trackHintLocked(id, path: path)
            let missing = missingFieldsLocked(id, row: row)
            guard !missing.isEmpty else {
                enrichmentTimers.removeValue(forKey: id)?.cancel()
                memberWork[id] = work
                setStateLocked(id, to: .loaded(entry.0)); awaiting.remove(id)
                return
            }
            if !explicit && work.lastAttempt == signature {
                memberWork[id] = work
                setStateLocked(id, to: work.enrichmentFailed ? .unreadable : .loaded(entry.0)); return
            }
            if !explicit && now() < work.nextAttempt {
                memberWork[id] = work
                scheduleEnrichmentLocked(id, after: work.nextAttempt.timeIntervalSince(now()))
                setStateLocked(id, to: .loaded(entry.0)); return
            }
            // Charge even a read whose result is discarded for a concurrent write.
            work.lastAttempt = signature
            work.nextAttempt = now().addingTimeInterval(work.delay)
            work.delay = min(60, work.delay * 2)
            memberWork[id] = work
            parseCount &+= 1
            let summary = store.loadSummary(at: entry.0)
            do {
                guard try FileSignature(entry.0) == signature else {
                    // Nothing from either read is accepted across a concurrent write.
                    work.verified = false
                    memberWork[id] = work
                    pendingPaths.insert(path); scheduleLocked(); return
                }
            } catch {
                work.verified = false; memberWork[id] = work
                unreadable = true; continue
            }
            work.enrichmentFailed = summary == nil
            memberWork[id] = work
            guard let summary else { unreadable = true; continue }
            guard summary.id == id else {
                work.verified = false; memberWork[id] = work
                failure = .mismatch; continue
            }
            if summaries[id] != summary { contentDirty = true; changedIDs.insert(id) }
            summaries[id] = summary
            setStateLocked(id, to: .loaded(entry.0)); awaiting.remove(id)
            return
        }
        if ordered.isEmpty, !unreadable, !paths.isEmpty, !rescannedMissing {
            // A disappeared hint/previous path is not a new enumeration verdict.
            enumerateLocked()
            resolveLocked(id, explicit: explicit, rescannedMissing: true)
            return
        }
        if summaries.removeValue(forKey: id) != nil { contentDirty = true; changedIDs.insert(id) }
        // A candidate with a failed verification is evidence, never absence.
        setStateLocked(id, to: unreadable ? .unreadable : failure ??
            (awaiting.contains(id) ? .awaitingCreation :
                (enumerationSucceeded && ordered.isEmpty ? .confirmedAbsent : .resolving)))
    }

    private func missingFieldsLocked(_ id: String, row: ResolutionRequest?) -> Set<SessionCoreField> {
        row?.wanted ?? []
    }

    private func resetEnrichmentLocked(_ id: String) {
        enrichmentTimers.removeValue(forKey: id)?.cancel()
        memberWork[id]?.delay = 1
        memberWork[id]?.nextAttempt = .distantPast
        memberWork[id]?.lastAttempt = nil
    }

    private func scheduleEnrichmentLocked(_ id: String, after delay: TimeInterval) {
        guard enrichmentTimers[id] == nil else { return }
        let timer = DispatchWorkItem { [weak self = self] in
            guard let self, self.running else { return }
            self.enrichmentTimers.removeValue(forKey: id)
            self.resolveLocked(id)
            self.publishLocked()
        }
        enrichmentTimers[id] = timer
        queue.asyncAfter(deadline: .now() + max(0.01, delay), execute: timer)
    }

    /// Deterministic backoff checkpoint; tests can advance a clock without waiting minutes.
    func reconcileEnrichment() {
        queue.async { [weak self = self] in
            guard let self, self.running else { return }
            for id in self.registeredIDs { self.resolveLocked(id) }
            self.publishLocked()
        }
    }

    public var metrics: EngineMetrics {
        snapshotLock.lock(); defer { snapshotLock.unlock() }; return snapshotMetrics
    }

    private func reconcileFileLocked(_ url: URL) -> Bool {
        guard let store = stores.first(where: { $0.acceptsTranscript(url) }) else { return false }
        let path = url.path
        files[path] = (url, store.agent)
        var ids = memberIDsByPath[path] ?? []
        if let id = recordFilenameLocked(path, store: store), registeredIDs.contains(id) { ids.insert(id) }
        var changed = false
        // Filename routing and validated hints are the only member discovery.
        // Outside writes never parse transcripts, read the DB, or publish state.
        for id in ids.sorted() {
            let old = summaries[id]
            resolveLocked(id)
            if old != summaries[id] { changed = true }
        }
        if store.agent == .codex, !requests.isEmpty {
            _ = readCandidateLocked(url, store: store)
        }
        if !ids.isEmpty { snapshotLocked() }
        return changed
    }

    private func publishLocked() {
        snapshotLocked()
        emitChangesLocked()
    }

    public func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult {
        let ticket = AdoptionTicket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !ticket.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard request.window >= 0, self.requests.count < Self.adoptionRequestLimit else {
                        continuation.resume(returning: .incomplete); return
                    }
                    let id = ticket.id
                    self.requests[id] = LocalAdoptionWindow(cwd: request.directory, start: request.startedAt,
                        window: request.window, completion: { continuation.resume(returning: $0) })
                    ticket.cancelAction = { [weak self = self] in
                        self?.queue.async { [weak self = self] in
                            guard let self, let pending = self.requests.removeValue(forKey: id), !pending.decided else { return }
                            self.adoptionTimers.removeValue(forKey: id)?.cancel()
                            pending.completion(.incomplete)
                            if self.requests.values.allSatisfy(\.decided) {
                                self.requests.removeAll(); self.seenCandidates.removeAll(); self.trimCandidateCacheLocked()
                                self.stopIfIdleLocked()
                            }
                        }
                    }
                    let earliest = self.requests.values.map { $0.start.addingTimeInterval(-$0.window) }.min() ?? request.startedAt
                    self.claimed = self.claimed.filter { $0.value >= earliest }
                    self.startLocked()
                    self.sweepCandidatesLocked()
                    self.scheduleAdoptionDeadlineLocked(id)
                }
            }
        } onCancel: { ticket.cancel() }
    }

    private func scheduleAdoptionDeadlineLocked(_ id: UUID) {
        guard let request = requests[id], !request.decided, let generation = streamID else { return }
        adoptionTimers.removeValue(forKey: id)?.cancel()
        let delay = max(0, request.start.addingTimeInterval(request.window).timeIntervalSinceNow) + debounceInterval
        let timer = DispatchWorkItem { [weak self = self] in
            guard let self, self.running, self.streamID == generation else { return }
            self.decideAdoptionLocked(id)
        }
        adoptionTimers[id] = timer
        queue.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func potentiallyEligible(_ url: URL, signature: FileSignature) -> Bool {
        // Rollout names contain UTC timestamps; mtime also admits partial
        // headers and fixtures. Old history never incurs header I/O per tab.
        let name = url.lastPathComponent
        let timestamp: Date? = {
            guard name.hasPrefix("rollout-"), name.count >= 27 else { return nil }
            let text = String(name.dropFirst(8).prefix(19))
            return rolloutDateFormatter.date(from: text)
        }()
        return requests.values.contains { request in
            !request.decided && (abs(signature.date.timeIntervalSince(request.start)) <= request.window ||
                timestamp.map { abs($0.timeIntervalSince(request.start)) <= request.window } == true)
        }
    }

    private func sweepCandidatesLocked(subtree: String? = nil) {
        if subtree == nil {
            unresolvedCandidates.removeAll()
            for id in requests.keys { requests[id]?.failedSweep = false }
        }
        for store in stores where store.agent == .codex {
            do {
                let listed = try subtree.map { try store.enumerateSessionFiles(in: URL(fileURLWithPath: $0)) } ?? store.enumerateSessionFiles()
                if subtree == nil {
                    let present = Set(listed.map(\.path))
                    candidates = candidates.filter { present.contains($0.key) }
                    candidateSignatures = candidateSignatures.filter { present.contains($0.key) }
                }
                for url in listed { _ = readCandidateLocked(url, store: store) }
            } catch {
                for id in requests.keys { requests[id]?.failedSweep = true }
            }
        }
    }

    private func readCandidateLocked(_ url: URL, store: any IncrementalSessionStore) -> Bool {
        guard let signature = try? FileSignature(url) else {
            if unresolvedCandidates.contains(url.path) || candidateSignatures.count + unresolvedCandidates.count < Self.candidateCacheLimit { unresolvedCandidates.insert(url.path) }
            else { failAdoptionSweepLocked() }
            return true
        }
        guard potentiallyEligible(url, signature: signature) else {
            if candidateSignatures[url.path] != signature {
                candidates.removeValue(forKey: url.path); candidateSignatures.removeValue(forKey: url.path)
            }
            unresolvedCandidates.remove(url.path)
            return false
        }
        if candidateSignatures[url.path] == signature {
            if let candidate = candidates[url.path] { rememberCandidateLocked(candidate) }
            return false
        }
        guard candidateSignatures[url.path] != nil || unresolvedCandidates.contains(url.path) || candidateSignatures.count + unresolvedCandidates.count < Self.candidateCacheLimit else {
            failAdoptionSweepLocked(); return false
        }
        do {
            // Nil here proves a non-session/subagent header. A session header
            // missing cwd/time is unresolved, just like partial JSON or I/O.
            let header = try store.adoptionHeader(at: url)
            guard try FileSignature(url) == signature else { throw CocoaError(.fileReadUnknown) }
            guard let candidate = header else {
                candidates.removeValue(forKey: url.path)
                candidateSignatures[url.path] = signature
                unresolvedCandidates.remove(url.path); return true
            }
            candidateSignatures[url.path] = signature
            candidates[url.path] = candidate
            rememberCandidateLocked(candidate)
            unresolvedCandidates.remove(url.path)
        } catch {
            candidates.removeValue(forKey: url.path)
            candidateSignatures.removeValue(forKey: url.path)
            unresolvedCandidates.insert(url.path)
        }
        return true
    }

    private func rememberCandidateLocked(_ candidate: CodexRolloutCandidate) {
        guard requests.values.contains(where: { !$0.decided && $0.matches(candidate) }) else { return }
        guard seenCandidates[candidate.sessionID] != nil || seenCandidates.count < Self.candidateCacheLimit else {
            for id in requests.keys { requests[id]?.observationOverflow = true }
            return
        }
        seenCandidates[candidate.sessionID] = candidate
    }

    private func failAdoptionSweepLocked() {
        // Overflow cannot prove uniqueness. Refuse instead of evicting a
        // competitor or allocating in proportion to the whole store history.
        for id in requests.keys { requests[id]?.failedSweep = true }
    }

    private func trimCandidateCacheLocked() {
        // Never evict a competing candidate during an active decision. Bound
        // the retained cache only after every overlapping request has finished.
        if candidateSignatures.count > 256 {
            let retained = Set(candidateSignatures.keys.sorted().suffix(256))
            candidateSignatures = candidateSignatures.filter { retained.contains($0.key) }
            candidates = candidates.filter { retained.contains($0.key) }
        }
    }

    private func decideAdoptionLocked(_ id: UUID) {
        guard running, requests[id]?.decided == false else { return }
        sweepCandidatesLocked()
        guard let request = requests[id] else { return }
        let eligible = seenCandidates.values.filter { request.matches($0) }
        var result: AdoptionResult = request.failedSweep || request.observationOverflow || !unresolvedCandidates.isEmpty ? .incomplete : .none
        let overlapping = requests.filter { $0.key != id && $0.value.cwd == request.cwd &&
            abs($0.value.start.timeIntervalSince(request.start)) <= $0.value.window + request.window }.count > 0
        if overlapping || eligible.count > 1 { result = .ambiguous }
        if !request.failedSweep, !request.observationOverflow, unresolvedCandidates.isEmpty, !overlapping,
           eligible.count == 1, let seen = eligible.first,
           let candidate = candidates.values.first(where: { $0.sessionID == seen.sessionID && request.matches($0) }),
           claimed[candidate.sessionID] == nil, claimed.count < Self.candidateCacheLimit {
            claimed[candidate.sessionID] = candidate.createdAt; result = .adopted(id: candidate.sessionID, locator: TranscriptLocator(localURL: candidate.filePath))
        }
        requests[id]?.decided = true
        adoptionTimers.removeValue(forKey: id)?.cancel()
        request.completion(result)
        if requests.values.allSatisfy(\.decided) { requests.removeAll(); seenCandidates.removeAll(); trimCandidateCacheLocked(); stopIfIdleLocked() }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(e.code)) ||
            (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT))
    }
}

/// The stream owns this callback context; a weak engine reference avoids both
/// a retain cycle and a queued callback dereferencing a destroyed watcher.
private final class EventRelay {
    weak var watcher: LocalSessionSource?
    init(_ watcher: LocalSessionSource) { self.watcher = watcher }
}

private struct LocalAdoptionWindow {
    let cwd: String
    let start: Date
    let window: TimeInterval
    let completion: @Sendable (AdoptionResult) -> Void
    var failedSweep = false
    var observationOverflow = false
    var decided = false
    func matches(_ candidate: CodexRolloutCandidate) -> Bool {
        candidate.cwd == cwd && abs(candidate.createdAt.timeIntervalSince(start)) <= window
    }
}

struct FileSignature: Equatable {
    let date: Date
    let size: Int
    let fileNumber: UInt64
    init(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        date = attrs[.modificationDate] as? Date ?? .distantPast
        size = attrs[.size] as? Int ?? 0
        fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Resolve only configured roots. Event leaves may already be deleted, and must
/// not require stat or per-event symlink resolution. Case is intentionally kept.
private struct RootMapping {
    let logical: String
    let physical: String
    let watchLogical: String
    let watchPhysical: String
    init(_ url: URL) {
        logical = Self.alias(url.path)
        physical = Self.alias(url.resolvingSymlinksInPath().path)
        watchLogical = Self.ancestor(URL(fileURLWithPath: logical).deletingLastPathComponent())
        watchPhysical = Self.ancestor(URL(fileURLWithPath: physical))
    }
    static func alias(_ path: String) -> String {
        SessionPaths.normalized(path)
    }
    static func ancestor(_ url: URL) -> String {
        var current = url
        while current.path != "/" && !FileManager.default.fileExists(atPath: current.path) {
            current.deleteLastPathComponent()
        }
        return current.path
    }
}

private struct MemberWork {
    var path: String
    var verified = false
    var enrichmentFailed = false
    var verificationFailure: MemberResolution?
    var lastAttempt: FileSignature?
    var nextAttempt = Date.distantPast
    var delay: TimeInterval = 1
}

/// Cancellation can race registration; the action is installed under the same lock.
private final class AdoptionTicket: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var cancelAction: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return action }
        set {
            lock.lock(); action = newValue; let run = cancelled; lock.unlock()
            if run { newValue?() }
        }
    }
    func cancel() { lock.lock(); cancelled = true; let run = action; lock.unlock(); run?() }
}
