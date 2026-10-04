import Dispatch
import Foundation
import TempleCore
import CoreServices

/// This Mac's transcripts, behind the primitive seam: FSEvents observation
/// of both stores, a filename map kept current by those events (and rebuilt
/// on every coverage reset), listing, bounded reads, Codex adoption and the
/// catalog. It holds no member state: which sessions are Temple's, and what
/// to do about each, is `SessionEngine`'s.
public final class LocalSessionSource: HostSessionSource, HostSourceDiagnostics, @unchecked Sendable {
    /// Only `ENOENT`/`ENOTDIR` (or a file where the folder should be) prove
    /// a folder gone; anything else — a parent it may not search, an I/O
    /// error — is unknown.
    public func directoryEvidence(_ path: String) async -> DirectoryEvidence { Self.evidence(path) }

    static func evidence(_ path: String) -> DirectoryEvidence {
        var info = stat()
        if stat(path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? .exists : .missing }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown
    }
    public let host = HostID.local
    public let capabilities: Set<HostCapability> = [.liveChanges, .revealInFinder, .catalog]
    private var changeContinuations: [UUID: AsyncThrowingStream<SourceChange, Error>.Continuation] = [:]
    private let stores: [any IncrementalSessionStore]
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sriramb.temple.local-source")
    private var stream: FSEventStreamRef?
    private var running = false
    private var roots: [RootMapping] = []
    private var files: [String: (URL, Agent)] = [:]
    private var pathsByID: [String: Set<String>] = [:]
    private var selectedCodexPaths: [String: (path: String, key: String)] = [:]
    /// The source's coverage generation (`LocateResult.coverage`).
    private var generation: UInt64 = 0
    private let monitorChanges: Bool
    /// The shared inputs' paths (normalized once, not per event).
    private let sharedFactPaths: Set<String>
    private var enumerationCount: UInt64 = 0
    private var snapshotMetrics = EngineMetrics()

    private let snapshotLock = NSLock()
    private var snapshotMonitoring = false
    private var adoptionTimers: [UUID: DispatchWorkItem] = [:]
    private var unresolvedCandidates: Set<String> = []
    private var enumerationByAgent: [Agent: Bool] = [:]
    private var streamID: UUID?
    /// Every transcript path observed since the last flush.
    private var rawPaths: Set<String> = []
    /// The last shared-facts revision announced per agent.
    private var announcedShared: [Agent: UInt64] = [:]
    /// Test seam: called during a read at each phase, on the reading thread.
    var readPhaseHook: (@Sendable (ReadPhase, URL) -> Void)?
    enum ReadPhase { case sharedFactsAcquired, bytesRead }
    private var locateCount: UInt64 = 0
    private let readCounts = ReadCounters()
    private var work: DispatchWorkItem?
    private var requests: [UUID: LocalAdoptionWindow] = [:]
    private var candidates: [String: RolloutHeader] = [:]
    // Keep competitors seen anywhere in an active window, even if a later
    // sweep no longer finds their files. Overflow refuses the decision.
    private var seenCandidates: [String: RolloutHeader] = [:]
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

    /// This Mac's two stores, at their real roots or the `TEMPLE_*_ROOT`
    /// overrides. `monitorChanges: false` never arms FSEvents (templectl's
    /// one-shot reads).
    public convenience init(monitorChanges: Bool = true) {
        self.init(stores: [ClaudeSessionStore(), CodexSessionStore()], monitorChanges: monitorChanges)
    }

    init(stores: [any IncrementalSessionStore],
         debounceInterval: TimeInterval = 0.3,
         monitorChanges: Bool = true) {
        self.stores = stores
        self.debounceInterval = debounceInterval
        self.monitorChanges = monitorChanges
        self.sharedFactPaths = Set(stores.flatMap(\.sharedFactURLs).map { SessionPaths.normalized($0.path) })
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

    private func snapshotLocked() {
        snapshotLock.lock()
        snapshotMonitoring = monitoring
        snapshotMetrics = EngineMetrics(enumerations: enumerationCount, locates: locateCount)
        snapshotLock.unlock()
    }

    private func startLocked() {
        guard !running else { return }
        running = true
        streamID = UUID()
        generation &+= 1
        // Arm before enumeration. Callbacks buffer behind the scan on this queue.
        armLocked()
        enumerateLocked()
        for store in stores {
            if let revision = store.sharedRevision() { announcedShared[store.agent] = revision }
        }
        if !requests.isEmpty {
            for requestID in requests.keys { scheduleAdoptionDeadlineLocked(requestID) }
            sweepCandidatesLocked()
        }
        snapshotLocked()
    }

    private func stopIfIdleLocked() {
        if changeContinuations.isEmpty && requests.isEmpty { stopLocked() }
    }

    private func stopLocked() {
        adoptionTimers.values.forEach { $0.cancel() }; adoptionTimers.removeAll()
        for request in requests.values where !request.decided { request.completion(.incomplete) }
        requests.removeAll(); candidates.removeAll(); seenCandidates.removeAll(); candidateSignatures.removeAll()
        unresolvedCandidates.removeAll()
        running = false
        monitoring = false
        work?.cancel(); work = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamID = nil
        rawPaths.removeAll()
        files.removeAll(); pathsByID.removeAll(); selectedCodexPaths.removeAll()
        snapshotLocked()
    }

    private func armLocked() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots = stores.flatMap(\.watchedURLs).map(RootMapping.init)
        // Enumeration-only control for the synthetic benchmark (and for
        // tests that inject every event): nothing from FSEvents arrives.
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
            LocalHostLog.watcher.error("FSEvents stream could not be created")
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        monitoring = FSEventStreamStart(created)
        if !monitoring {
            LocalHostLog.watcher.error("FSEvents stream failed to start")
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
            // Lost events, or a watched root replaced: nothing seen before
            // can be vouched for (coverage moves on). A root that appeared
            // or was touched is listed again and every transcript under it
            // reported.
            armLocked(); recoverLocked(resetCoverage: dropped || rootChanged); return
        }
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if sharedFactPaths.contains(path) {
            sharedFactsChangedLocked()
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
            if relevant { rescanLocked(subtree: path) }
            return
        }
        guard isTranscript else { return }
        // Every transcript write is reported, member or not: which ids are
        // members is the engine's business.
        rawPaths.insert(path)
        scheduleLocked()
    }

    /// history.jsonl or session_index.jsonl changed: announce the new
    /// revision. Which members could gain a title is the engine's question.
    private func sharedFactsChangedLocked() {
        for store in stores {
            guard let revision = store.sharedRevision(), revision > announcedShared[store.agent] ?? 0 else { continue }
            announcedShared[store.agent] = revision
            for continuation in changeContinuations.values { continuation.yield(.sharedFacts(store.agent, revision: revision)) }
        }
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
            let raw = self.rawPaths; self.rawPaths.removeAll()
            // The filename map follows every observed transcript, whether or
            // not anyone is interested in it: `locate` answers from it.
            for path in raw { self.observeTranscriptPathLocked(path) }
            if !self.requests.isEmpty {
                for path in raw {
                    let url = URL(fileURLWithPath: path)
                    if let store = self.stores.first(where: { $0.agent == .codex && $0.acceptsTranscript(url) }) {
                        _ = self.readCandidateLocked(url, store: store)
                    }
                }
            }
            // After the map is current, so a consumer that locates on these
            // finds the source already up to date.
            self.emitTranscriptsLocked(raw)
        }
        work = item
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// One observed transcript path, into or out of the filename map.
    private func observeTranscriptPathLocked(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let store = stores.first(where: { $0.acceptsTranscript(url) }) else { return }
        if Self.candidateStat(path) != .missing {
            files[path] = (url, store.agent)
            _ = recordFilenameLocked(path, store: store)
            return
        }
        guard files.removeValue(forKey: path) != nil, let id = store.filenameID(at: url) else { return }
        pathsByID[id]?.remove(path)
        if pathsByID[id]?.isEmpty == true { pathsByID.removeValue(forKey: id) }
        if selectedCodexPaths[id]?.path == path {
            // The thread's pick is gone: the next one takes its place.
            selectedCodexPaths.removeValue(forKey: id)
            for remaining in (pathsByID[id] ?? []).sorted() { _ = recordFilenameLocked(remaining, store: store) }
        }
    }

    private func enumerateLocked(subtree: String? = nil) {
        if subtree == nil { enumerationCount &+= 1 }
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
                LocalHostLog.watcher.error("enumeration failed: \(String(describing: error), privacy: .public)")
            }
        }
        files = next
        pathsByID.removeAll(); selectedCodexPaths.removeAll()
        for (path, entry) in files {
            if let store = stores.first(where: { $0.agent == entry.1 }) { _ = recordFilenameLocked(path, store: store) }
        }
        snapshotLocked()
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

    /// The whole map is listed again. With a coverage reset, consumers are
    /// told to trust nothing they saw; without one, every transcript the
    /// map held or holds now is reported.
    private func recoverLocked(resetCoverage: Bool) {
        let before = Set(files.keys)
        if resetCoverage {
            generation &+= 1
            for continuation in changeContinuations.values { continuation.yield(.coverageReset(coverage: generation)) }
        }
        enumerateLocked()
        if !requests.isEmpty { sweepCandidatesLocked() }
        if !resetCoverage { emitTranscriptsLocked(before.union(files.keys)) }
    }

    /// A directory under a store moved in, or its events coalesced: that
    /// subtree is listed again, and every transcript it held or holds now is
    /// reported (FSEvents named no file, so any of them may have changed).
    private func rescanLocked(subtree: String) {
        let before = files.keys.filter { $0.hasPrefix(subtree + "/") }
        enumerateLocked(subtree: subtree)
        let after = files.keys.filter { $0.hasPrefix(subtree + "/") }
        if !requests.isEmpty { sweepCandidatesLocked(subtree: subtree) }
        emitTranscriptsLocked(Set(before).union(after))
    }

    public var metrics: EngineMetrics {
        snapshotLock.lock(); var result = snapshotMetrics; snapshotLock.unlock()
        let reads = readCounts.values
        result.reads = reads.reads; result.parses = reads.parses; result.widerReads = reads.wider
        result.sharedTransfers = UInt64(stores.reduce(0) { $0 + $1.sharedTransfers })
        return result
    }

    private func emitTranscriptsLocked(_ paths: Set<String>) {
        guard running, !paths.isEmpty else { return }
        var ids: Set<String> = []
        var locators: Set<TranscriptLocator> = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let store = stores.first(where: { $0.acceptsTranscript(url) }) else { continue }
            if let id = store.filenameID(at: url) { ids.insert(id) }
            locators.insert(TranscriptLocator(host: host, path: path))
        }
        guard !locators.isEmpty else { return }
        for continuation in changeContinuations.values { continuation.yield(.transcripts(ids: ids, locators: locators)) }
    }

    // MARK: Primitives

    /// From the filename map — kept current by events and rebuilt on every
    /// coverage reset while observing; listed on the spot when nothing
    /// observes, or when a request asks for a refresh.
    public func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LocateResult, Error>) in
            queue.async {
                self.locateCount &+= 1
                if !self.running || requests.contains(where: \.refresh) { self.enumerateLocked() }
                var candidates: [String: [TranscriptCandidate]] = [:]
                for request in requests {
                    var list: [TranscriptCandidate] = []
                    for store in self.stores where request.agent == nil || request.agent == store.agent {
                        let listed = (self.pathsByID[request.id] ?? []).filter { self.files[$0]?.1 == store.agent }
                        var hintPath: String?
                        if let hint = request.hint, hint.host == self.host {
                            let path = self.logicalPath(hint.path) ?? RootMapping.alias(hint.path)
                            if store.acceptsTranscript(URL(fileURLWithPath: path)) { hintPath = path }
                        }
                        let hintPresent = hintPath.map { Self.candidateStat($0) != .missing } ?? false
                        for assignment in TranscriptCandidates.assign(id: request.id, format: store.format, listed: listed.sorted(),
                                                                     hint: hintPath, hintPresent: hintPresent) {
                            let stat = Self.candidateStat(assignment.path)
                            // A hint whose file is gone is no candidate (and walks nothing).
                            if assignment.role == .hinted, stat == .missing { continue }
                            list.append(TranscriptCandidate(locator: TranscriptLocator(host: self.host, path: assignment.path),
                                                            agent: store.agent, role: assignment.role, stat: stat))
                        }
                    }
                    candidates[request.id] = list
                }
                // An agent this Mac has no store for has nothing to list: its
                // listing is complete. One with a store is complete only once
                // its last full enumeration succeeded.
                let served = Set(self.stores.map(\.agent))
                let complete = Set(Agent.allCases.filter { !served.contains($0) })
                    .union(self.stores.filter { self.enumerationByAgent[$0.agent] == true }.map(\.agent))
                var shared: [Agent: UInt64] = [:]
                for store in self.stores {
                    if let revision = store.sharedRevision() { shared[store.agent] = revision }
                }
                self.snapshotLocked()
                continuation.resume(returning: LocateResult(coverage: self.generation, candidates: candidates,
                                                            complete: complete, sharedRevision: shared))
            }
        }
    }

    /// Off the source's queue, so reads run side by side.
    public func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        guard locator.host == host, let store = stores.first(where: { $0.agent == agent }) else {
            throw TranscriptReadError.unreadable("not a \(agent.displayName) transcript on this Mac")
        }
        let url = locator.localURL ?? URL(fileURLWithPath: locator.path)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.readNow(url, store: store, expecting: id, facts: facts) })
            }
        }
    }

    /// How often a read retries a file that changed under it before giving up.
    static let readAttempts = 3

    /// Identity, facts and signature describe one version of the file: the
    /// file is stat'ed before and after the bytes are read, and a read that
    /// straddled a change (a replacement, an append, a rewrite) is retried,
    /// never returned with one version's facts and another's signature.
    private func readNow(_ url: URL, store: any IncrementalSessionStore, expecting id: String, facts: Bool) throws -> TranscriptRead {
        func failure(_ error: Error) -> TranscriptReadError {
            Self.isMissing(error) ? .missing : .unreadable(error.localizedDescription)
        }
        readCounts.read()
        for _ in 0..<Self.readAttempts {
            let before: FileSignature
            do { before = try FileSignature(url) } catch { throw failure(error) }
            let identity: (verdict: TranscriptVerification, bytesRead: Int)
            do { identity = try StoreIO.identity(at: url, format: store.format, expecting: id) }
            catch { throw failure(error) }
            var bytes = identity.bytesRead
            var summary: TranscriptSummary?
            var revision: UInt64?
            if facts, identity.verdict == .verified {
                // Facts and revision come as one value: whatever changes after
                // this, these facts keep the revision they were read at.
                let shared = store.sharedFactsSnapshot()
                revision = shared.revision
                readPhaseHook?(.sharedFactsAcquired, url)
                let result = StoreIO.facts(at: url, format: store.format, shared: shared.facts)
                readCounts.parse(wider: result.widerRead)
                summary = result.summary
                bytes += result.bytesRead
            }
            readPhaseHook?(.bytesRead, url)
            let after: FileSignature
            do { after = try FileSignature(url) } catch { throw failure(error) }
            guard after == before else { continue }
            return TranscriptRead(identity: identity.verdict, summary: summary, signature: after.transcript,
                                  bytesRead: bytes, sharedRevision: revision)
        }
        throw TranscriptReadError.changedDuringRead
    }

    private static func candidateStat(_ path: String) -> CandidateStat {
        do { return .present(try FileSignature(URL(fileURLWithPath: path)).transcript) }
        catch { return isMissing(error) ? .missing : .unreadable }
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
            guard let candidate = header.map({ RolloutHeader(header: $0, path: url) }) else {
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

    private func rememberCandidateLocked(_ candidate: RolloutHeader) {
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
            claimed[candidate.sessionID] = candidate.createdAt; result = .adopted(id: candidate.sessionID, locator: TranscriptLocator(localURL: candidate.path))
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
    /// The one adoption rule: the sole exact-folder rollout header inside
    /// the symmetric launch window. Zero or several refuse the decision.
    func matches(_ candidate: RolloutHeader) -> Bool {
        candidate.cwd == cwd && abs(candidate.createdAt.timeIntervalSince(start)) <= window
    }
}

/// A Codex rollout's header (`CodexFormat.header`) and the file it heads.
struct RolloutHeader: Equatable {
    let sessionID: String
    let cwd: String
    let createdAt: Date
    let path: URL
    init(header: AdoptionCandidate, path: URL) {
        sessionID = header.id; cwd = header.cwd; createdAt = header.createdAt; self.path = path
    }
}

struct FileSignature: Equatable {
    let date: Date
    let size: Int
    let fileNumber: UInt64
    var transcript: TranscriptSignature { TranscriptSignature(modifiedAt: date, size: size, identity: fileNumber) }
    /// One `lstat(2)` — the attributes `FileManager.attributesOfItem` reports
    /// for these fields (it does not follow a link either), without the
    /// extended-attribute reads it adds on every call. A failure throws the
    /// POSIX error, so a missing file is `ENOENT`.
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        size = Int(info.st_size)
        fileNumber = UInt64(info.st_ino)
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

private final class ReadCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: UInt64 = 0, parses: UInt64 = 0, wider: UInt64 = 0
    func read() { lock.lock(); reads &+= 1; lock.unlock() }
    func parse(wider isWider: Bool) { lock.lock(); parses &+= 1; if isWider { wider &+= 1 }; lock.unlock() }
    var values: (reads: UInt64, parses: UInt64, wider: UInt64) { lock.lock(); defer { lock.unlock() }; return (reads, parses, wider) }
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
