import Dispatch
import Foundation
import CoreServices

public enum MemberResolution: Hashable, Sendable {
    case resolving
    case awaitingCreation
    case loaded(URL)
    case confirmedAbsent
    case unreadable
}

/// A single FSEvents stream invalidates paths; only committed members are parsed
/// and published. Engine mutation lives on `queue`; UI reads use a locked snapshot.
public final class SessionWatcher: @unchecked Sendable {
    private let stores: [any IncrementalSessionStore]
    private let database: TempleDB?
    private let initialMembers: Set<String>
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.sriramb.temple.session-engine")
    private var stream: FSEventStreamRef?
    private var joinObserver: UUID?
    private var leaveObserver: UUID?
    private var continuation: AsyncStream<SessionIndex>.Continuation?
    private var running = false
    private var roots: [RootMapping] = []
    private var files: [String: (URL, Agent)] = [:]
    private var pathsByID: [String: Set<String>] = [:]
    private var memberIDsByPath: [String: Set<String>] = [:]
    private var hintPathsByID: [String: String] = [:]
    private var selectedCodexPaths: [String: (path: String, key: String)] = [:]
    private var members: Set<String> = []
    private var awaiting: Set<String> = []
    private var states: [String: MemberResolution] = [:]
    private var statesDirty = false
    private var sessions: [String: AgentSession] = [:]
    private var summaries: [String: TranscriptSummary] = [:]
    private var generation: UInt64 = 0
    private var engineContentDirty = false
    private var lastEngineSnapshot: EngineSnapshot?
    private var engineContinuations: [UUID: AsyncStream<EngineSnapshot>.Continuation] = [:]
    private var signatures: [String: FileSignature] = [:] // validated member ID -> signature
    private let snapshotLock = NSLock()
    private var snapshotStates: [String: MemberResolution] = [:]
    private var snapshotIndex: SessionIndex?
    private var snapshotMonitoring = false
    private var stateContinuations: [UUID: AsyncStream<[String: MemberResolution]>.Continuation] = [:]
    private var adoptionTimers: [UUID: DispatchWorkItem] = [:]
    private var unresolvedCandidates: Set<String> = []
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
                database: TempleDB? = nil, members: Set<String> = [],
                debounceInterval: TimeInterval = 0.3) {
        self.stores = stores
        self.database = database
        self.initialMembers = members
        self.debounceInterval = debounceInterval
        // Observe before startup; the row read at startup is the durable replay.
        joinObserver = database?.observeJoins { [weak self] id, awaiting in
            self?.requestResolution(id, awaitingCreation: awaiting)
        }
        leaveObserver = database?.observeLeaves { [weak self] id in
            self?.forgetMember(id)
        }
    }

    deinit {
        if let joinObserver { database?.removeJoinObserver(joinObserver) }
        if let leaveObserver { database?.removeLeaveObserver(leaveObserver) }
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
    }

    public func resolution(for id: String) -> MemberResolution? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshotStates[id]
    }
    var publishedIndex: SessionIndex? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshotIndex
    }
    public var isMonitoring: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshotMonitoring
    }
    private var monitoring = false

    /// Resolution transitions can finish without changing member content.
    public func resolutionUpdates() -> AsyncStream<[String: MemberResolution]> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in self?.stateContinuations.removeValue(forKey: token) }
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.stateContinuations[token] = continuation
                continuation.yield(self.states)
            }
        }
    }

    /// Replay the latest engine publication, then deliver coalesced updates.
    public func snapshots() -> AsyncStream<EngineSnapshot> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in self?.engineContinuations.removeValue(forKey: token) }
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.engineContinuations[token] = continuation
                if let snapshot = self.lastEngineSnapshot { continuation.yield(snapshot) }
            }
        }
    }

    private func setStateLocked(_ id: String, to state: MemberResolution) {
        guard states[id] != state else { return }
        states[id] = state; statesDirty = true
    }

    private func snapshotLocked() {
        snapshotLock.lock()
        let changed = statesDirty
        if changed { snapshotStates = states; statesDirty = false }
        snapshotIndex = lastIndex; snapshotMonitoring = monitoring
        snapshotLock.unlock()
        if changed {
            engineContentDirty = true
            for continuation in stateContinuations.values { continuation.yield(states) }
        }
    }

    /// Content is published only after a whole batch has reconciled. Resolution
    /// notifications above retain their independent transition timing.
    private func publishEngineSnapshotLocked() {
        guard running, engineContentDirty || lastEngineSnapshot == nil, let lastIndex else { return }
        engineContentDirty = false
        let loadedSummaries = summaries.filter { id, _ in
            if case .loaded = states[id] { return true }
            return false
        }
        let snapshot = EngineSnapshot(generation: generation, resolutions: states,
            summaries: loadedSummaries, legacyIndex: lastIndex)
        if snapshot != lastEngineSnapshot {
            lastEngineSnapshot = snapshot
            for continuation in engineContinuations.values { continuation.yield(snapshot) }
        }
    }

    public func start() -> AsyncStream<SessionIndex> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard self?.streamID == id else { return }
                    self?.stopLocked()
                }
            }
            queue.async { [weak self] in
                guard let self else { return }
                self.stopLocked(preservePrestart: self.streamID == nil && !self.running)
                self.continuation = continuation
                self.streamID = id
                self.running = true
                self.generation &+= 1
                self.members.formUnion(self.initialMembers)
                self.reloadMembershipLocked()
                // The stream starts BEFORE the scan. Its serial-queue callbacks
                // buffer behind the scan and reconcile after the initial snapshot.
                self.armLocked()
                self.enumerateLocked()
                self.refreshTitlesLocked()
                for id in self.members { self.resolveLocked(id) }
                self.publishLocked()
                if !self.requests.isEmpty {
                    for requestID in self.requests.keys { self.scheduleAdoptionDeadlineLocked(requestID) }
                    self.sweepCandidatesLocked()
                }
            }
        }
    }

    public func stop() { queue.async { [weak self] in self?.stopLocked() } }

    private func stopLocked(preservePrestart: Bool = false) {
        if !preservePrestart {
            adoptionTimers.values.forEach { $0.cancel() }; adoptionTimers.removeAll()
            requests.removeAll(); candidates.removeAll(); seenCandidates.removeAll(); candidateSignatures.removeAll()
            unresolvedCandidates.removeAll(); claimed.removeAll(); awaiting.removeAll()
        }
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
        hintPathsByID.removeAll(); selectedCodexPaths.removeAll()
        signatures.removeAll(); sessions.removeAll(); summaries.removeAll()
        lastEngineSnapshot = nil
        lastIndex = nil
        states.removeAll(); statesDirty = true; snapshotLocked()
    }

    // Membership is observed only through this process's committed joins.
    // External-process joins (including templectl imports) are seen next launch;
    // there is no engine-only refresh that could leave the overlay out of sync.
    /// A leave invalidates membership. Recheck the row because callbacks can
    /// arrive after a newer re-import. The filename map is disk state and stays.
    public func forgetMember(_ id: String) {
        queue.async { [weak self] in
            guard let self, self.members.contains(id) else { return }
            if let database = self.database {
                do {
                    guard try database.sessionState(id) == nil else { return }
                } catch {
                    TempleCoreLog.watcher.error("leave membership check failed: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            self.members.remove(id)
            self.awaiting.remove(id)
            self.sessions.removeValue(forKey: id)
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
            if case .loaded = self.states[id], !awaitingCreation {
                let hint = try? self.database?.sessionState(id)?.transcriptPath
                if hint == nil || hint == self.sessions[id]?.filePath.path { return }
            }
            if awaitingCreation { self.awaiting.insert(id) }
            self.setStateLocked(id, to: awaitingCreation ? .awaitingCreation : .resolving)
            self.snapshotLocked()
            guard self.running else { self.snapshotLocked(); return }
            // Resolve a known hint/map first. A failed lookup gets a fresh name
            // map even if no filesystem event accompanied this explicit open.
            self.resolveLocked(id)
            if self.sessions[id] == nil {
                self.enumerateLocked()
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
            }
            catch { enumerationSucceeded = false }
        }
        for id in members where states[id] == nil { setStateLocked(id, to: .resolving) }
    }

    private func armLocked() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots = stores.flatMap(\.watchedURLs).map(RootMapping.init)
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
        let isTitle = stores.contains { $0.sharedTitleURLs.contains { SessionPaths.normalized($0.path) == path } }
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
        guard isTitle || isTranscript else { return }
        if isTitle { refreshTitlesLocked(); publishLocked(); return }
        let hintedMember = memberIDsByPath[path]?.isEmpty == false
        let filenameMember = stores.contains { store in
            store.acceptsTranscript(url) && store.filenameID(at: url).map { members.contains($0) } == true
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
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.work = nil
            let paths = self.pendingPaths; self.pendingPaths.removeAll()
            var changed = false
            for path in paths {
                if self.reconcileFileLocked(URL(fileURLWithPath: path)) { changed = true }
            }
            if changed { self.publishLocked() }
            else { self.publishEngineSnapshotLocked() }
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

    private func recoverLocked(subtree: String? = nil) {
        generation &+= 1
        engineContentDirty = true
        enumerateLocked(subtree: subtree); refreshTitlesLocked()
        for id in members {
            if let subtree {
                let mapped = (pathsByID[id] ?? []).contains { $0.hasPrefix(subtree + "/") }
                let old = sessions[id]?.filePath.path.hasPrefix(subtree + "/") == true
                let hinted = (try? database?.sessionState(id)?.transcriptPath)?.hasPrefix(subtree + "/") == true
                if !mapped && !old && !hinted { continue }
            }
            resolveLocked(id)
        }
        if !requests.isEmpty { sweepCandidatesLocked(subtree: subtree) }
        publishLocked()
    }

    private func resolveLocked(_ id: String) {
        guard members.contains(id) else { return }
        let row = try? database?.sessionState(id)
        // A committed hint can name a new revert that arrived while this ID
        // was still outside Temple. Include its filename before choosing the
        // thread's active rollout, without enumerating or reading other logs.
        if let hint = row?.transcriptPath, let agent = row?.agent,
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
        if let row, let hint = row.transcriptPath {
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
        if let loaded = sessions[id], selectedPath == nil || loaded.agent != .codex || loaded.filePath.path == selectedPath {
            paths.insert(loaded.filePath.path)
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
        for (path, signature) in ordered {
            guard let entry = files[path], let store = stores.first(where: { $0.agent == entry.1 }) else { continue }
            if signatures[id] == signature, let session = sessions[id], session.filePath.path == path {
                setStateLocked(id, to: .loaded(session.filePath)); return
            }
            let summary = (store as? any TranscriptSummaryStore)?.loadSummary(at: entry.0)
            // Legacy custom stores retain their API; never invent facts from display values.
            let parsed = store is any TranscriptSummaryStore
                ? summary.map { AgentSession(summary: $0) } : store.loadSession(at: entry.0)
            if let final = try? FileSignature(entry.0), final != signature {
                pendingPaths.insert(path); scheduleLocked()
            }
            guard let parsed, parsed.id == id else { unreadable = true; continue }
            if summaries[id] != summary { engineContentDirty = true }
            summaries[id] = summary
            signatures[id] = signature
            sessions[id] = parsed; setStateLocked(id, to: .loaded(parsed.filePath)); awaiting.remove(id)
            trackHintLocked(id, path: path)
            if database?.isReadOnly != true, row?.agent != parsed.agent || row?.transcriptPath != parsed.filePath.path {
                try? database?.updateTranscriptHint(sessionID: id, agent: parsed.agent, path: parsed.filePath)
            }
            return
        }
        sessions.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
        signatures.removeValue(forKey: id)
        // Only a completed enumeration proves absence. A listing failure is
        // unknown, not a verdict about a missing or unreadable transcript.
        setStateLocked(id, to: unreadable ? .unreadable :
            (awaiting.contains(id) ? .awaitingCreation :
                (enumerationSucceeded ? .confirmedAbsent : .resolving)))
    }

    private func reconcileFileLocked(_ url: URL) -> Bool {
        guard let store = stores.first(where: { $0.acceptsTranscript(url) }) else { return false }
        let path = url.path
        files[path] = (url, store.agent)
        var ids = memberIDsByPath[path] ?? []
        if let id = recordFilenameLocked(path, store: store), members.contains(id) { ids.insert(id) }
        var changed = false
        // Filename routing and validated hints are the only member discovery.
        // Outside writes never parse transcripts, read the DB, or publish state.
        for id in ids.sorted() {
            let old = sessions[id]
            resolveLocked(id)
            if old != sessions[id] { changed = true }
        }
        if store.agent == .codex, !requests.isEmpty {
            _ = readCandidateLocked(url, store: store)
        }
        if !ids.isEmpty { snapshotLocked() }
        return changed
    }

    private func refreshTitlesLocked() {
        guard let store = stores.first(where: { $0.agent == .codex }) else { return }
        let token = store.cacheInvalidationToken
        guard token != titleToken else { return }
        titleToken = token; titles = store.loadSharedTitles()
        let prompts = (store as? any TranscriptSummaryStore)?.loadSharedPrompts() ?? [:]
        for id in Array(summaries.keys) where summaries[id]?.agent == .codex {
            if summaries[id]?.historyPrompt != prompts[id] {
                summaries[id]?.historyPrompt = prompts[id]
                engineContentDirty = true
            }
        }
    }

    private func displayedSessionsLocked() -> [AgentSession] {
        sessions.values.map { session in
            guard session.agent == .codex, let title = titles[session.id] else { return session }
            return AgentSession(id: session.id, agent: session.agent, projectPath: session.projectPath,
                title: title, createdAt: session.createdAt, updatedAt: session.updatedAt,
                filePath: session.filePath, messageCount: session.messageCount, model: session.model,
                lastMessagePreview: session.lastMessagePreview, gitBranch: session.gitBranch, originator: session.originator)
        }
    }

    private func publishLocked() {
        let index = SessionIndex.grouping(displayedSessionsLocked())
        let changed = index != lastIndex
        if changed { engineContentDirty = true }
        lastIndex = index; snapshotLocked()
        publishEngineSnapshotLocked()
        if changed { continuation?.yield(index) }
    }

    /// Registers before spawn. Candidates never enter the member snapshot. The
    /// deadline sweep closes delivery gaps; eligibility uses metadata time.
    public func registerAdoption(projectPath: String, startedAt: Date, window: TimeInterval = 5,
                                 completion: @escaping @Sendable (CodexRolloutCandidate?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.requests.count < Self.adoptionRequestLimit else { completion(nil); return }
            let id = UUID()
            self.requests[id] = AdoptionRequest(cwd: projectPath, start: startedAt, window: window, completion: completion)
            let earliest = self.requests.values.map { $0.start.addingTimeInterval(-$0.window) }.min() ?? startedAt
            self.claimed = self.claimed.filter { $0.value >= earliest }
            if self.running { self.sweepCandidatesLocked() }
            if self.running, self.requests[id]?.decided == false { self.scheduleAdoptionDeadlineLocked(id) }
        }
    }

    private func scheduleAdoptionDeadlineLocked(_ id: UUID) {
        guard let request = requests[id], !request.decided, let generation = streamID else { return }
        adoptionTimers.removeValue(forKey: id)?.cancel()
        let delay = max(0, request.start.addingTimeInterval(request.window).timeIntervalSinceNow) + debounceInterval
        let timer = DispatchWorkItem { [weak self] in
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
        var result: CodexRolloutCandidate?
        let overlapping = requests.filter { $0.key != id && $0.value.cwd == request.cwd &&
            abs($0.value.start.timeIntervalSince(request.start)) <= $0.value.window + request.window }.count > 0
        if !request.failedSweep, !request.observationOverflow, unresolvedCandidates.isEmpty, !overlapping,
           eligible.count == 1, let seen = eligible.first,
           let candidate = candidates.values.first(where: { $0.sessionID == seen.sessionID && request.matches($0) }),
           claimed[candidate.sessionID] == nil, claimed.count < Self.candidateCacheLimit {
            claimed[candidate.sessionID] = candidate.createdAt; result = candidate
        }
        requests[id]?.decided = true
        adoptionTimers.removeValue(forKey: id)?.cancel()
        request.completion(result)
        if requests.values.allSatisfy(\.decided) { requests.removeAll(); seenCandidates.removeAll(); trimCandidateCacheLocked() }
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

private struct AdoptionRequest {
    let cwd: String
    let start: Date
    let window: TimeInterval
    let completion: @Sendable (CodexRolloutCandidate?) -> Void
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
