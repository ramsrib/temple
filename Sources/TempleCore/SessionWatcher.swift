import Dispatch
import Foundation
import CoreServices

public enum MemberResolution: Equatable, Sendable {
    case resolving
    case awaitingCreation
    case loaded(URL)
    case confirmedAbsent
    case unreadable
}

/// A single FSEvents stream invalidates paths; only committed members are parsed
/// and published. All mutable engine state lives on `queue`.
public final class SessionWatcher: @unchecked Sendable {
    private let stores: [any IncrementalSessionStore]
    private let database: TempleDB?
    private let initialMembers: Set<String>
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sriramb.temple.session-engine")
    private var stream: FSEventStreamRef?
    private var joinObserver: UUID?
    private var continuation: AsyncStream<SessionIndex>.Continuation?
    private var running = false
    private var roots: [RootMapping] = []
    private var files: [String: (URL, Agent)] = [:]
    private var pathsByID: [String: Set<String>] = [:]
    private var memberIDsByPath: [String: Set<String>] = [:]
    private var repairedLegacyIDs: Set<String> = []
    private var pendingLegacyIDs: Set<String> = []
    private var legacyRepairScheduled = false
    private let headerMapURL: URL?
    private var headerMap: RolloutHeaderMap?
    private let queueKey = DispatchSpecificKey<Bool>()
    private var members: Set<String> = []
    private var awaiting: Set<String> = []
    private var states: [String: MemberResolution] = [:]
    private var sessions: [String: AgentSession] = [:]
    private var signatures: [String: FileSignature] = [:]
    private var titles: [String: String] = [:]
    private var titleToken: String?
    private var enumerationSucceeded = true
    private var enumerationByAgent: [Agent: Bool] = [:]
    private var streamID: UUID?
    private var pendingPaths: Set<String> = []
    private var work: DispatchWorkItem?
    private var lastIndex: SessionIndex?
    private var requests: [UUID: AdoptionRequest] = [:]
    private var candidates: [String: CodexRolloutCandidate] = [:]
    private var candidateSignatures: [String: FileSignature] = [:]
    private var claimed: Set<String> = []

    public init(stores: [any IncrementalSessionStore] = [ClaudeSessionStore(), CodexSessionStore()],
                database: TempleDB? = nil, members: Set<String> = [],
                headerMapURL: URL? = nil, debounceInterval: TimeInterval = 0.3) {
        self.stores = stores
        self.database = database
        self.initialMembers = members
        self.debounceInterval = debounceInterval
        self.headerMapURL = headerMapURL
        queue.setSpecific(key: queueKey, value: true)
        // Observe before startup; the row read at startup is the durable replay.
        joinObserver = database?.observeJoins { [weak self] id, awaiting in
            self?.requestResolution(id, awaitingCreation: awaiting)
        }
    }

    deinit {
        if let joinObserver { database?.removeJoinObserver(joinObserver) }
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }

    public func resolution(for id: String) -> MemberResolution? {
        if DispatchQueue.getSpecific(key: queueKey) == true { return states[id] }
        return queue.sync { states[id] }
    }
    /// Read-only publication seam for ordering diagnostics and regression tests.
    var publishedIndex: SessionIndex? {
        if DispatchQueue.getSpecific(key: queueKey) == true { return lastIndex }
        return queue.sync { lastIndex }
    }
    public var isMonitoring: Bool { queue.sync { monitoring } }
    private var monitoring = false

    public func start() -> AsyncStream<SessionIndex> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard self?.streamID == id else { return }
                    self?.stopLocked()
                }
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.stopLocked()
                self.continuation = continuation
                self.streamID = id
                self.running = true
                self.members.formUnion(self.initialMembers)
                self.reloadMembershipLocked()
                // The stream starts BEFORE the scan. Its serial-queue callbacks
                // buffer behind the scan and reconcile after the initial snapshot.
                self.armLocked()
                self.enumerateLocked()
                self.refreshTitlesLocked()
                for id in self.members { self.resolveLocked(id) }
                self.repairLegacyCodexLocked()
                self.publishLocked()
                if !self.requests.isEmpty { self.sweepCandidatesLocked() }
            }
        }
    }

    public func stop() { queue.async { [weak self] in self?.stopLocked() } }

    private func stopLocked() {
        running = false
        monitoring = false
        work?.cancel(); work = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamID = nil
        continuation?.finish(); continuation = nil
        pendingPaths.removeAll()
        files.removeAll(); pathsByID.removeAll(); memberIDsByPath.removeAll()
        repairedLegacyIDs.removeAll(); pendingLegacyIDs.removeAll(); legacyRepairScheduled = false
        headerMap = nil
        signatures.removeAll(); sessions.removeAll()
        lastIndex = nil
    }

    /// Explicit refresh for joins made by a separate DB connection/process. No
    /// periodic full-table polling is attached to filesystem traffic.
    public func reloadMembership() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reloadMembershipLocked()
            if self.running {
                self.enumerateLocked(); self.repairLegacyCodexLocked()
                for id in self.members { self.resolveLocked(id, force: true) }
                self.publishLocked()
            }
        }
    }

    public func requestResolution(_ id: String, awaitingCreation: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            // A notification is an invalidation, never membership authority.
            if let database = self.database {
                guard (try? database.sessionState(id)) != nil else { return }
            } else if !self.initialMembers.contains(id) { return }
            self.members.insert(id)
            if awaitingCreation { self.awaiting.insert(id) }
            self.states[id] = awaitingCreation ? .awaitingCreation : .resolving
            self.repairedLegacyIDs.remove(id)
            guard self.running else { return }
            // Resolve a known hint/map first. A failed lookup gets a fresh name
            // map even if no filesystem event accompanied this explicit open.
            self.resolveLocked(id, force: true)
            if self.sessions[id] == nil {
                self.enumerateLocked(); self.repairLegacyCodexLocked()
                self.resolveLocked(id)
            }
            self.publishLocked()
        }
    }

    private func reloadMembershipLocked() {
        if let database {
            do {
                let rows = try database.sessionStates()
                members = Set(rows.map(\.id))
                awaiting.formUnion(rows.filter {
                    $0.joinedVia == .created && $0.agent == .claude && $0.transcriptPath == nil
                }.map(\.id))
            }
            catch { enumerationSucceeded = false }
        }
        for id in members where states[id] == nil { states[id] = .resolving }
    }

    private func armLocked() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots = stores.flatMap(\.watchedURLs).map(RootMapping.init)
        let paths = Set(roots.flatMap { [$0.watchPhysical, $0.watchLogical] })
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
        queue.async { [weak self] in self?.eventLocked(path, flags: flags) }
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
            armLocked(); recoverLocked(); return
        }
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        // Codex sqlite/WAL/log traffic is rejected before stat or resolution.
        let isTitle = stores.compactMap { $0 as? CodexSessionStore }.contains { $0.titleURLs.contains { SessionPaths.normalized($0.path) == path } }
        let isTranscript = stores.contains { $0.acceptsTranscript(url) }
        let directory = has(kFSEventStreamEventFlagItemIsDir)
        let scan = has(kFSEventStreamEventFlagMustScanSubDirs)
        if directory || scan {
            // Claude project dirs and Codex sessions descendants are relevant;
            // unrelated Codex log directories never start a history walk.
            let relevant = stores.contains { store in
                if let codex = store as? CodexSessionStore {
                    let sessionsRoot = SessionPaths.normalized(codex.watchedURLs[0].appendingPathComponent("sessions").path)
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
        guard isTitle || isTranscript else { return }
        if isTitle { refreshTitlesLocked(); publishLocked(); return }
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
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.work = nil
            let paths = self.pendingPaths; self.pendingPaths.removeAll()
            var changed = false
            for path in paths {
                if self.reconcileFileLocked(URL(fileURLWithPath: path)) { changed = true }
            }
            if changed { self.publishLocked() }
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
                enumerationByAgent[store.agent] = true
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
        pathsByID.removeAll()
        for (path, entry) in files {
            if let store = stores.first(where: { $0.agent == entry.1 }), let id = store.filenameID(at: entry.0) {
                pathsByID[id, default: []].insert(path)
            }
        }
    }

    private func recoverLocked(subtree: String? = nil) {
        let previouslyLoaded = Set(sessions.keys)
        enumerateLocked(subtree: subtree); refreshTitlesLocked()
        var affected: Set<String> = []
        for id in members {
            if let subtree {
                let mapped = (pathsByID[id] ?? []).contains { $0.hasPrefix(subtree + "/") }
                let old = sessions[id]?.filePath.path.hasPrefix(subtree + "/") == true
                let hinted = (try? database?.sessionState(id)?.transcriptPath)?.hasPrefix(subtree + "/") == true
                if !mapped && !old && !hinted { continue }
            }
            affected.insert(id)
            resolveLocked(id)
        }
        // Only a newly lost, previously loaded member needs header repair again.
        // Unresolved legacy rows do not rescan history on every outside write.
        repairedLegacyIDs.subtract(previouslyLoaded.subtracting(sessions.keys))
        repairLegacyCodexLocked()
        for id in affected where sessions[id] == nil { resolveLocked(id) }
        if !requests.isEmpty { sweepCandidatesLocked(subtree: subtree) }
        publishLocked()
    }

    /// Marks repair targets before publication, but does no header I/O here.
    /// Small queued batches let startup, joins, and FSEvents get turns between
    /// repair reads. A stream generation prevents old scans completing a restart.
    private func repairLegacyCodexLocked() {
        guard stores.contains(where: { $0.agent == .codex }) else { return }
        let unresolved = members.filter { id in
            pathsByID[id] == nil && sessions[id] == nil && !repairedLegacyIDs.contains(id) &&
                !awaiting.contains(id) && (try? database?.sessionState(id)?.agent) != .claude
        }
        pendingLegacyIDs.formUnion(unresolved)
        for id in pendingLegacyIDs { states[id] = .resolving }
        guard !pendingLegacyIDs.isEmpty, !legacyRepairScheduled, let generation = streamID else { return }
        legacyRepairScheduled = true
        queue.async { [weak self] in
            guard let self, self.running, self.streamID == generation else { return }
            self.headerMap = self.headerMap ?? RolloutHeaderMap(url: self.headerMapURL ?? RolloutHeaderMap.defaultURL)
            let scan = LegacyRepairScan(paths: self.files.filter { $0.value.1 == .codex }.keys.sorted())
            self.repairBatchLocked(scan, generation: generation)
        }
    }

    private func repairBatchLocked(_ scan: LegacyRepairScan, generation: UUID) {
        guard running, streamID == generation, let headerMap else { return }
        let end = min(scan.offset + 32, scan.paths.count)
        while scan.offset < end {
            let path = scan.paths[scan.offset]; scan.offset += 1
            guard let entry = files[path], let store = stores.first(where: { $0.agent == entry.1 }) else { continue }
            do {
                if let id = try autoreleasepool(invoking: { try headerMap.payloadID(at: entry.0, store: store) }) {
                    scan.pathsByID[id, default: []].insert(path)
                }
            } catch {
                if !Self.isMissing(error) { scan.failed = true }
            }
        }
        if scan.offset == scan.paths.count {
            // Include files discovered by buffered/live events while repairing.
            let newPaths = Set(files.filter { $0.value.1 == .codex }.keys).subtracting(scan.paths)
            scan.paths.append(contentsOf: newPaths.sorted())
        }
        if scan.offset < scan.paths.count {
            queue.async { [weak self] in self?.repairBatchLocked(scan, generation: generation) }
            return
        }
        let targets = pendingLegacyIDs
        pendingLegacyIDs.removeAll()
        legacyRepairScheduled = false
        for id in targets {
            if let paths = scan.pathsByID[id] { pathsByID[id, default: []].formUnion(paths) }
            if !scan.failed && enumerationSucceeded { repairedLegacyIDs.insert(id) }
            resolveLocked(id)
            if sessions[id] == nil && scan.failed { states[id] = .unreadable }
        }
        headerMap.save(retaining: Set(files.filter { $0.value.1 == .codex }.keys))
        // No second snapshot for the common case of genuinely pruned logs.
        if targets.contains(where: { sessions[$0] != nil }) { publishLocked() }
    }

    private func resolveLocked(_ id: String, force: Bool = false) {
        guard members.contains(id) else { return }
        var paths = pathsByID[id] ?? []
        let row = try? database?.sessionState(id)
        var preferredPath: String?
        if let row, let hint = row.transcriptPath {
            let path = logicalPath(hint) ?? RootMapping.alias(hint)
            if let agent = row.agent, let store = stores.first(where: { $0.agent == agent }),
               store.acceptsTranscript(URL(fileURLWithPath: path)) {
                files[path] = (URL(fileURLWithPath: path), agent); paths.insert(path)
                preferredPath = path
                memberIDsByPath[path, default: []].insert(id)
            }
        }
        if let loaded = sessions[id] { paths.insert(loaded.filePath.path) }
        var unreadable = false
        let ordered = preferredPath.map { [$0] + paths.subtracting([$0]).sorted() } ?? paths.sorted()
        for path in ordered {
            guard let entry = files[path], let store = stores.first(where: { $0.agent == entry.1 }) else { continue }
            let signature: FileSignature
            do { signature = try FileSignature(entry.0) }
            catch {
                if !Self.isMissing(error) { unreadable = true }
                continue
            }
            if !force, signatures[path] == signature, let session = sessions[id], session.filePath.path == path {
                states[id] = .loaded(session.filePath); return
            }
            let parsed: AgentSession?
            if let codex = store as? CodexSessionStore { parsed = codex.loadTranscript(at: entry.0) }
            else { parsed = store.loadSession(at: entry.0) }
            signatures[path] = signature // PRE-parse signature, always.
            if let final = try? FileSignature(entry.0), final != signature {
                pendingPaths.insert(path); scheduleLocked()
            }
            guard let parsed, parsed.id == id else { unreadable = true; continue }
            sessions[id] = parsed; states[id] = .loaded(parsed.filePath); awaiting.remove(id)
            memberIDsByPath[path, default: []].insert(id)
            if row?.agent != parsed.agent || row?.transcriptPath != parsed.filePath.path {
                try? database?.updateTranscriptHint(sessionID: id, agent: parsed.agent, path: parsed.filePath)
            }
            return
        }
        sessions.removeValue(forKey: id)
        states[id] = pendingLegacyIDs.contains(id) ? .resolving :
            (unreadable || !enumerationSucceeded ? .unreadable :
                (awaiting.contains(id) ? .awaitingCreation : .confirmedAbsent))
    }

    private func reconcileFileLocked(_ url: URL) -> Bool {
        guard let store = stores.first(where: { $0.acceptsTranscript(url) }) else { return false }
        let path = url.path
        files[path] = (url, store.agent)
        var ids = memberIDsByPath[path] ?? []
        if let id = store.filenameID(at: url) {
            pathsByID[id, default: []].insert(path)
            if members.contains(id) { ids.insert(id) }
        }
        var changed = false
        // Outside writes update only the filename map. No member iteration,
        // transcript parse, title read, or snapshot construction is needed.
        for id in ids {
            let old = sessions[id]
            resolveLocked(id)
            if old != sessions[id] { changed = true }
        }
        if store.agent == .codex, !requests.isEmpty { readCandidateLocked(url, store: store) }
        return changed
    }

    private func refreshTitlesLocked() {
        guard let store = stores.compactMap({ $0 as? CodexSessionStore }).first else { return }
        let token = store.cacheInvalidationToken
        guard token != titleToken else { return }
        titleToken = token; titles = store.loadTitles()
    }

    private func publishLocked() {
        let displayed = sessions.values.map { session in
            guard session.agent == .codex, let title = titles[session.id] else { return session }
            return AgentSession(id: session.id, agent: session.agent, projectPath: session.projectPath,
                title: title, createdAt: session.createdAt, updatedAt: session.updatedAt,
                filePath: session.filePath, messageCount: session.messageCount, model: session.model,
                lastMessagePreview: session.lastMessagePreview, gitBranch: session.gitBranch, originator: session.originator)
        }
        let index = SessionIndex.grouping(displayed)
        guard index != lastIndex else { return }
        lastIndex = index; continuation?.yield(index)
    }

    /// Registers before spawn. Candidates never enter the member snapshot. The
    /// deadline sweep closes delivery gaps; eligibility uses metadata time.
    public func registerAdoption(projectPath: String, startedAt: Date, window: TimeInterval = 5,
                                 completion: @escaping @Sendable (CodexRolloutCandidate?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = UUID()
            self.requests[id] = AdoptionRequest(cwd: projectPath, start: startedAt, window: window, completion: completion)
            if self.running { self.sweepCandidatesLocked() }
            let delay = max(0, startedAt.addingTimeInterval(window).timeIntervalSinceNow) + self.debounceInterval
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.decideAdoptionLocked(id) }
        }
    }

    private func sweepCandidatesLocked(subtree: String? = nil) {
        for store in stores where store.agent == .codex {
            do {
                let listed = try subtree.map { try store.enumerateSessionFiles(in: URL(fileURLWithPath: $0)) } ?? store.enumerateSessionFiles()
                for url in listed { readCandidateLocked(url, store: store) }
            } catch {
                // A failed sweep cannot establish uniqueness.
                for id in requests.keys { requests[id]?.failedSweep = true }
            }
        }
    }

    private func readCandidateLocked(_ url: URL, store: any IncrementalSessionStore) {
        guard let signature = try? FileSignature(url) else { candidates.removeValue(forKey: url.path); return }
        if candidateSignatures[url.path] == signature { return }
        guard let candidate = store.metadataHeader(at: url) else {
            candidates.removeValue(forKey: url.path); candidateSignatures.removeValue(forKey: url.path); return
        }
        candidateSignatures[url.path] = signature
        candidates[url.path] = candidate
        let path = logicalPath(url.path) ?? RootMapping.alias(url.path)
        files[path] = (URL(fileURLWithPath: path), .codex)
        pathsByID[candidate.sessionID, default: []].insert(path)
    }

    private func decideAdoptionLocked(_ id: UUID) {
        guard requests[id] != nil else { return }
        sweepCandidatesLocked()
        guard let request = requests[id] else { return }
        let eligible = Dictionary(candidates.values.filter { request.matches($0) }.map { ($0.sessionID, $0) },
                                  uniquingKeysWith: { first, _ in first }).values
        var result: CodexRolloutCandidate?
        if !request.failedSweep, eligible.count == 1, let candidate = eligible.first,
           !claimed.contains(candidate.sessionID),
           requests.filter({ $0.value.matches(candidate) }).count == 1 {
            claimed.insert(candidate.sessionID); result = candidate
        }
        // Keep decided requests through overlapping windows so the next decision
        // still sees the conflict, even when the first request was refused.
        requests[id]?.decided = true
        request.completion(result)
        if requests.values.allSatisfy(\.decided) {
            requests.removeAll(); candidates.removeAll(); candidateSignatures.removeAll()
        }
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
    weak var watcher: SessionWatcher?
    init(_ watcher: SessionWatcher) { self.watcher = watcher }
}

private final class LegacyRepairScan: @unchecked Sendable {
    var paths: [String]
    var offset = 0
    var pathsByID: [String: Set<String>] = [:]
    var failed = false
    init(paths: [String]) { self.paths = paths }
}

private struct AdoptionRequest {
    let cwd: String
    let start: Date
    let window: TimeInterval
    let completion: @Sendable (CodexRolloutCandidate?) -> Void
    var failedSweep = false
    var decided = false
    func matches(_ candidate: CodexRolloutCandidate) -> Bool {
        candidate.cwd == cwd && abs(candidate.createdAt.timeIntervalSince(start)) <= window
    }
}

struct FileSignature: Codable, Equatable {
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
