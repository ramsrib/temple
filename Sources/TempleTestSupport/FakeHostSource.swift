import Foundation
import TempleCore

/// An in-memory host for tests: transcripts are bytes at opaque paths, read
/// through the same `TempleCore/Formats` every real host uses, so a test of
/// the engine or the contract exercises the agent formats and nothing local.
/// Every operation counts its round trips; failures and gates are scriptable.
public final class FakeHostSource: HostSessionSource, HostSourceDiagnostics, @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        /// Transport round trips, one per operation (plus one per wider head).
        public var roundTrips = 0
        public var locates = 0
        /// Listing passes (each `locate` lists once, like one `find`).
        public var listings = 0
        public var reads = 0
        /// Member reads that parsed facts.
        public var parses = 0
        /// Transcripts the catalog parsed (a kept summary is not one).
        public var catalogParses = 0
        public var widerReads = 0
        public var bytesRead = 0
        /// The ids each `locate` asked about, in order.
        public var locatedIDs: [[String]] = []
        /// Folder-evidence checks begun, and those abandoned on cancellation
        /// while held at `evidenceGate`.
        public var evidenceChecks = 0
        public var evidenceCancelled = 0
    }

    public let host: HostID
    public let capabilities: Set<HostCapability> = [.liveChanges, .catalog]
    /// Whether this host has file identities (inodes). Without them a
    /// signature's identity is always 0.
    public let hasInodes: Bool
    /// Opened before a `read` or `locate` returns, when set — a test can hold
    /// an operation in flight.
    public var readGate: FakeGate? { get { locked { gates.read } } set { locked { gates.read = newValue } } }
    public var locateGate: FakeGate? { get { locked { gates.locate } } set { locked { gates.locate = newValue } } }
    /// Holds every folder-evidence check until it opens — or until the
    /// asking task is cancelled, which answers `.unknown`.
    public var evidenceGate: FakeGate? { get { locked { gateForEvidence } } set { locked { gateForEvidence = newValue } } }
    private var gateForEvidence: FakeGate?
    /// Runs inside every read, after its bytes and before its closing stat,
    /// without the host's lock: a test can change the file mid-read.
    public var readPhaseHook: (@Sendable (String) -> Void)? {
        get { locked { hook } } set { locked { hook = newValue } }
    }
    private var hook: (@Sendable (String) -> Void)?

    private struct File {
        var agent: Agent
        var data: Data
        var modifiedAt: Date
        var identity: UInt64
        var unreadable = false
        /// The host's change time: moves on every write and every change
        /// of access, and nothing sets it back.
        var changed: UInt64 = 0
    }
    /// The catalog's kept summaries (ADR-032), as a remote source would keep
    /// them: by path, under the stamp the read saw, shared fields stripped.
    private struct Kept {
        let stamp: KeptStamp
        let summary: TranscriptSummary?
    }
    private struct KeptStamp: Equatable {
        let modifiedAt: Date
        let size: Int
        let identity: UInt64
        let changed: UInt64
    }
    private var kept: [String: Kept] = [:]
    private var changeClock: UInt64 = 0
    private let lock = NSLock()
    private var files: [String: File] = [:]
    /// Paths listings still name after their file went (`removeKeepingListing`).
    private var staleListed: [String: Agent] = [:]
    private var shared: [Agent: [String: Data]] = [:]
    private var sharedRevisions: [Agent: UInt64] = [:]
    private var directories: Set<String> = []
    private var unsearchable: Set<String> = []
    private var brokenListings: Set<Agent> = []
    private var transportBroken = false
    private var coverage: UInt64 = 1
    private var nextIdentity: UInt64 = 1
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var continuations: [UUID: AsyncThrowingStream<SourceChange, Error>.Continuation] = [:]
    private var counts = Counters()
    private var gates: (read: FakeGate?, locate: FakeGate?) = (nil, nil)

    public init(host: HostID = HostID(rawValue: "fake-remote"), hasInodes: Bool = true) {
        self.host = host
        self.hasInodes = hasInodes
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    public var counters: Counters { locked { counts } }
    public var isMonitoring: Bool { locked { !continuations.isEmpty } }
    public var metrics: EngineMetrics {
        let c = counters
        return EngineMetrics(parses: UInt64(c.parses), locates: UInt64(c.locates), reads: UInt64(c.reads),
                             widerReads: UInt64(c.widerReads))
    }

    // MARK: Scripting the host

    /// Writes (or replaces) a transcript. A replacement is a new file — a new
    /// identity — unless `inPlace`. The modification time advances a second
    /// per write unless given.
    @discardableResult
    public func write(_ path: String, agent: Agent, data: Data, modifiedAt: Date? = nil, inPlace: Bool = false) -> TranscriptLocator {
        let locator = TranscriptLocator(host: host, path: path)
        let change: SourceChange = locked {
            clock = clock.addingTimeInterval(1)
            let identity: UInt64
            if inPlace, let old = files[path] { identity = old.identity } else { identity = hasInodes ? nextIdentity : 0; nextIdentity += 1 }
            changeClock += 1
            files[path] = File(agent: agent, data: data, modifiedAt: modifiedAt ?? clock, identity: identity, changed: changeClock)
            staleListed.removeValue(forKey: path)
            return changeLocked(path, agent: agent)
        }
        emit(change)
        return locator
    }

    public func append(_ path: String, _ data: Data) {
        let change: SourceChange? = locked {
            guard var file = files[path] else { return nil }
            clock = clock.addingTimeInterval(1)
            changeClock += 1
            file.data.append(data); file.modifiedAt = clock; file.changed = changeClock
            files[path] = file
            return changeLocked(path, agent: file.agent)
        }
        change.map(emit)
    }

    public func truncate(_ path: String, to size: Int) {
        let change: SourceChange? = locked {
            guard var file = files[path] else { return nil }
            clock = clock.addingTimeInterval(1)
            changeClock += 1
            file.data = file.data.prefix(size); file.modifiedAt = clock; file.changed = changeClock
            files[path] = file
            return changeLocked(path, agent: file.agent)
        }
        change.map(emit)
    }

    public func remove(_ path: String) {
        let change: SourceChange? = locked {
            guard let file = files.removeValue(forKey: path) else { return nil }
            return changeLocked(path, agent: file.agent)
        }
        change.map(emit)
    }

    /// The file goes, but listings still name it, and no change is
    /// reported: a `find` that raced the delete, a filename map that missed
    /// it. Its candidates stat as missing.
    public func removeKeepingListing(_ path: String) {
        locked { if let file = files.removeValue(forKey: path) { staleListed[path] = file.agent } }
    }

    public func setUnreadable(_ path: String, _ unreadable: Bool = true) {
        locked {
            guard let file = files[path] else { return }
            changeClock += 1
            files[path]?.unreadable = unreadable; files[path]?.changed = changeClock
            recordLocked(ScopeEvent(path: path, kind: .file), agent: file.agent)
        }
    }

    /// Rewrites a file in place to `data` and puts its old modification time
    /// back — what a restore tool does. Only the change time tells.
    public func rewriteRestoringModificationTime(_ path: String, _ data: Data) {
        locked {
            guard var file = files[path] else { return }
            changeClock += 1
            file.data = data; file.changed = changeClock
            files[path] = file
            recordLocked(ScopeEvent(path: path, kind: .file), agent: file.agent)
        }
    }

    /// Summaries the catalog keeps now.
    public var keptSummaries: Int { locked { kept.count } }

    /// Replaces one of an agent's shared inputs (nil removes it), bumping its revision.
    public func setShared(_ agent: Agent, _ name: String, _ data: Data?) {
        let revision: UInt64 = locked {
            shared[agent, default: [:]][name] = data
            sharedRevisions[agent, default: 0] += 1
            return sharedRevisions[agent, default: 0]
        }
        emit(.sharedFacts(agent, revision: revision))
    }

    public func addDirectory(_ path: String) { locked { _ = directories.insert(path) } }
    public func removeDirectory(_ path: String) { locked { _ = directories.remove(path) } }
    /// Directories under this path cannot be checked: evidence is unknown.
    public func makeUnsearchable(_ path: String) { locked { _ = unsearchable.insert(path) } }
    public func breakListing(_ agent: Agent, _ broken: Bool = true) {
        locked { if broken { brokenListings.insert(agent) } else { brokenListings.remove(agent) } }
    }

    /// The agent's listing meets something it cannot see past (a link, a
    /// hidden entry, ADR-032): it lists, but proves no absence.
    public func setNotExhaustive(_ agent: Agent, _ value: Bool = true) {
        locked { if value { notExhaustive.insert(agent) } else { notExhaustive.remove(agent) } }
    }
    private var notExhaustive: Set<Agent> = []

    /// A new folder where the agent's transcripts are listed.
    public func makeFolder(_ agent: Agent) {
        record(ScopeEvent(path: "/new-folder", kind: .directory), agent: agent)
    }

    /// Runs inside every `proveAbsent`, after its listing and before its
    /// wait, without the host's lock: a test can change the store mid-proof.
    public var proofHook: (@Sendable () -> Void)? {
        get { locked { hookForProof } } set { locked { hookForProof = newValue } }
    }
    private var hookForProof: (@Sendable () -> Void)?
    /// Per running proof: its agent, and what happened in that agent's store.
    private var proofWatches: [UUID: (agent: Agent?, events: [ScopeEvent])] = [:]

    /// Something happened in an agent's store (nil: everywhere).
    private func record(_ event: ScopeEvent, agent: Agent?) {
        locked { recordLocked(event, agent: agent) }
    }
    private func recordLocked(_ event: ScopeEvent, agent: Agent?) {
        for (token, watch) in proofWatches where agent == nil || watch.agent == agent {
            proofWatches[token]?.events.append(event)
        }
    }
    /// A transport that drops takes every running proof's observation with it.
    public func breakTransport(_ broken: Bool = true) {
        locked {
            transportBroken = broken
            if broken { recordLocked(ScopeEvent(path: "", kind: .lost), agent: nil) }
        }
    }

    /// Held, when set, inside every `proveAbsent`'s listing: a test can
    /// cancel a proof while it lists.
    public var proofListingGate: FakeGate? {
        get { locked { gateForProofListing } } set { locked { gateForProofListing = newValue } }
    }
    private var gateForProofListing: FakeGate?

    /// What a dropped event stream (or a reconnect) does: coverage moves on.
    /// Unannounced, a consumer learns of it from its next `locate`.
    public func dropEvents(announce: Bool = true) {
        let next: UInt64 = locked { coverage += 1; recordLocked(ScopeEvent(path: "", kind: .lost), agent: nil); return coverage }
        if announce { emit(.coverageReset(coverage: next)) }
    }

    /// The next `count` reads throw `error` (after their round trip), while
    /// listings keep working: a transport that fails mid-operation.
    public func failNextReads(_ count: Int, with error: TranscriptReadError) {
        locked { readFailures = (count, error) }
    }
    private var readFailures: (count: Int, error: TranscriptReadError)?

    /// The next `count` locates throw a transport error once they run (after
    /// any gate), whatever the transport's state.
    public func failNextLocates(_ count: Int) { locked { locateFailures = count } }
    private var locateFailures = 0

    /// Ends every open change stream (a dropped connection), with an error
    /// or without one. A consumer is expected to subscribe again.
    public func endChanges(throwing error: Error? = nil) {
        let targets: [AsyncThrowingStream<SourceChange, Error>.Continuation] = locked {
            let all = Array(continuations.values); continuations.removeAll(); return all
        }
        for continuation in targets { continuation.finish(throwing: error) }
    }

    /// How many change streams are open.
    public var subscribers: Int { locked { continuations.count } }

    /// What a listing names for an agent: its files, and any stale entries.
    private func listedPathsLocked(_ agent: Agent) -> [String] {
        (files.filter { $0.value.agent == agent }.map(\.key) + staleListed.filter { $0.value == agent }.map(\.key)).sorted()
    }

    private func changeLocked(_ path: String, agent: Agent) -> SourceChange {
        recordLocked(ScopeEvent(path: path, kind: .file), agent: agent)
        let id = TranscriptFormats.format(for: agent).name(path: path)?.threadID
        return .transcripts(ids: id.map { [$0] } ?? [], locators: [TranscriptLocator(host: host, path: path)])
    }

    private func emit(_ change: SourceChange) {
        let targets = locked { Array(continuations.values) }
        for continuation in targets { continuation.yield(change) }
    }

    private func signature(_ file: File) -> TranscriptSignature {
        TranscriptSignature(modifiedAt: file.modifiedAt, size: file.data.count, identity: file.identity)
    }

    private func sharedFacts(_ agent: Agent) -> (SharedFacts, UInt64?) {
        let format = TranscriptFormats.format(for: agent)
        guard !format.sharedInputs.isEmpty else { return (.empty, nil) }
        return (format.sharedFacts(shared[agent] ?? [:]), sharedRevisions[agent, default: 0])
    }

    // MARK: HostSessionSource

    public func changes() -> AsyncThrowingStream<SourceChange, Error> {
        let token = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.locked { _ = self?.continuations.removeValue(forKey: token) } }
            locked { continuations[token] = continuation }
        }
    }

    public func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        await locateGate?.wait()
        return try locked {
            counts.roundTrips += 1
            counts.locates += 1
            counts.locatedIDs.append(requests.map(\.id).sorted())
            if locateFailures > 0 { locateFailures -= 1; throw LocateError.transport("fake transport dropped") }
            guard !transportBroken else { throw LocateError.transport("fake transport down") }
            counts.listings += 1
            var candidates: [String: [TranscriptCandidate]] = [:]
            for request in requests {
                var list: [TranscriptCandidate] = []
                for agent in Agent.allCases where request.agent == nil || request.agent == agent {
                    let format = TranscriptFormats.format(for: agent)
                    let listed = brokenListings.contains(agent) ? [] : listedPathsLocked(agent).filter { path in
                        format.name(path: path)?.threadID == request.id
                    }
                    // A hint is this agent's when its file is this agent's, or gone.
                    let hint = request.hint.flatMap { $0.host == host ? $0.path : nil }
                        .flatMap { files[$0] == nil || files[$0]?.agent == agent ? $0 : nil }
                    let hintPresent = hint.map { files[$0] != nil } ?? false
                    for assignment in TranscriptCandidates.assign(id: request.id, format: format, listed: listed,
                                                                 hint: hint, hintPresent: hintPresent) {
                        let stat: CandidateStat
                        if let file = files[assignment.path] { stat = file.unreadable ? .unreadable : .present(signature(file)) }
                        else { stat = .missing }
                        if assignment.role == .hinted, stat == .missing { continue }
                        list.append(TranscriptCandidate(locator: TranscriptLocator(host: host, path: assignment.path),
                                                        agent: agent, role: assignment.role, stat: stat))
                    }
                }
                candidates[request.id] = list
            }
            var revisions: [Agent: UInt64] = [:]
            for agent in Agent.allCases where !TranscriptFormats.format(for: agent).sharedInputs.isEmpty {
                revisions[agent] = sharedRevisions[agent, default: 0]
            }
            return LocateResult(coverage: coverage, candidates: candidates,
                                complete: Set(Agent.allCases).subtracting(brokenListings), sharedRevision: revisions)
        }
    }

    /// Like a transport, a read is several trips over the path — identity,
    /// facts, a closing stat — with the host free to change in between (the
    /// lock is not held across them; `readPhaseHook` runs between the bytes
    /// and the stat). A read that straddled a change is retried, and one that
    /// never settles throws `changedDuringRead`.
    public func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        await readGate?.wait()
        let injected: TranscriptReadError? = locked {
            guard let failure = readFailures, failure.count > 0 else { return nil }
            counts.reads += 1
            counts.roundTrips += 1
            readFailures = failure.count > 1 ? (failure.count - 1, failure.error) : nil
            return failure.error
        }
        if let injected { throw injected }
        let format = TranscriptFormats.format(for: agent)
        func current() throws -> File {
            guard !transportBroken else { throw TranscriptReadError.transport("fake transport down") }
            guard locator.host == host, let file = files[locator.path], file.agent == agent else { throw TranscriptReadError.missing }
            guard !file.unreadable else { throw TranscriptReadError.unreadable("permission denied") }
            return file
        }
        locked { counts.reads += 1 }
        for _ in 0..<3 {
            // Trip 1: identity.
            let (identityVersion, verdict, scanned): (TranscriptSignature, TranscriptVerification, Int) = try locked {
                counts.roundTrips += 1
                let file = try current()
                let (lines, scanned) = try Self.identityLines(file.data, scan: format.identityScan)
                return (signature(file), format.identity(lines: lines, expecting: id), scanned)
            }
            var bytes = scanned
            var summary: TranscriptSummary?
            var revision: UInt64?
            var factsVersion = identityVersion
            if facts, verdict == .verified {
                // Trip 2: facts, from whatever the path holds now.
                try locked {
                    counts.roundTrips += 1
                    counts.parses += 1
                    let file = try current()
                    factsVersion = signature(file)
                    let window = TranscriptBytes.defaultWindow
                    let head = file.data.prefix(window)
                    let tail = file.data.count > window ? file.data.suffix(min(window, file.data.count - window)) : nil
                    var input = TranscriptBytes(head: Data(head), tail: tail.map { Data($0) }, fileSize: file.data.count)
                    bytes += head.count + (tail?.count ?? 0)
                    let (shared, sharedRevision) = sharedFacts(agent)
                    revision = sharedRevision
                    let name = format.name(path: locator.path)
                    var result = format.facts(input, name: name, locator: locator, modifiedAt: file.modifiedAt, shared: shared)
                    if case .needsWiderHead(let size) = result {
                        counts.roundTrips += 1
                        counts.widerReads += 1
                        let wider = Data(file.data.prefix(size))
                        bytes += wider.count
                        input = input.with(widerHead: wider)
                        result = format.facts(input, name: name, locator: locator, modifiedAt: file.modifiedAt, shared: shared)
                    }
                    if case .summary(let parsed) = result { summary = parsed }
                }
            }
            readPhaseHook?(locator.path)
            // Trip 3: the closing stat.
            let closing: TranscriptSignature = try locked {
                counts.roundTrips += 1
                counts.bytesRead += bytes
                return signature(try current())
            }
            guard closing == identityVersion, closing == factsVersion else { continue }
            return TranscriptRead(identity: verdict, summary: summary, signature: closing,
                                  bytesRead: bytes, sharedRevision: revision)
        }
        throw TranscriptReadError.changedDuringRead
    }

    /// What a transport reading under `scan` would hand the format, and how much it read.
    private static func identityLines(_ data: Data, scan: IdentityScan) throws -> ([Data], Int) {
        switch scan {
        case .firstLine(let maxBytes):
            let prefix = data.prefix(maxBytes)
            if let newline = prefix.firstIndex(of: 0x0a) { return ([Data(prefix[..<newline])], newline - prefix.startIndex + 1) }
            guard data.count <= maxBytes else { throw TranscriptReadError.unreadable("header longer than \(maxBytes) bytes") }
            return ([Data(prefix)], prefix.count)
        case .lines(let maxBytes):
            let prefix = data.prefix(maxBytes)
            var parts = prefix.split(separator: 0x0a, omittingEmptySubsequences: false).map { Data($0) }
            // The final piece is a line only if the file ended inside the scan.
            if data.count >= maxBytes || prefix.last == 0x0a { parts.removeLast() }
            return (parts, prefix.count)
        }
    }

    public func directoryEvidence(_ path: String) async -> DirectoryEvidence {
        let gate: FakeGate? = locked { counts.evidenceChecks += 1; return gateForEvidence }
        if let gate {
            await gate.waitUnlessCancelled()
            if Task.isCancelled { locked { counts.evidenceCancelled += 1 }; return .unknown }
        }
        return locked {
            if directories.contains(path) { return .exists }
            if unsearchable.contains(where: { path.hasPrefix($0 + "/") }) { return .unknown }
            return .missing
        }
    }

    public func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                if self.locked({ self.transportBroken }) {
                    continuation.finish(throwing: LocateError.transport("fake transport broken"))
                    return
                }
                let (failed, summaries, candidates) = self.catalogSnapshot(query)
                for agent in failed { continuation.yield(.storeFailed(agent: agent, message: "fake listing failed")) }
                continuation.yield(.listed(total: summaries.count))
                var start = 0
                while start < summaries.count {
                    if Task.isCancelled { break }
                    let end = min(start + query.batchSize, summaries.count)
                    continuation.yield(.sessions(Array(summaries[start..<end]), read: end, total: summaries.count))
                    start = end
                    await Task.yield()
                }
                if !Task.isCancelled {
                    continuation.yield(.completed(candidates: candidates.filter { !failed.contains($0.key) }))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The agent's own pick per thread, parsed, newest first.
    /// `candidates`: per listed agent, every thread id a listed file is
    /// named for, however it then read.
    private func catalogSnapshot(_ query: CatalogQuery) -> (failed: [Agent], summaries: [TranscriptSummary], candidates: [Agent: Set<String>]) {
        let paths: [(Agent, String)] = locked {
            counts.roundTrips += 1
            counts.listings += 1
            return Agent.allCases.filter { query.agents.contains($0) && !brokenListings.contains($0) }
                .flatMap { agent in listedPathsLocked(agent).map { (agent, $0) } }
        }
        let broken = locked { brokenListings }
        let failed = Agent.allCases.filter { query.agents.contains($0) && broken.contains($0) }
        // The same per-thread pick as the local catalog and member
        // resolution, made before anything is parsed — or looked up.
        var summaries: [TranscriptSummary] = []
        var candidates: [Agent: Set<String>] = [:]
        for agent in Agent.allCases {
            let format = TranscriptFormats.format(for: agent)
            let (shared, _) = locked { sharedFacts(agent) }
            let threads = TranscriptCandidates.catalogThreads(format: format, listed: paths.filter { $0.0 == agent }.map(\.1))
            if query.agents.contains(agent) { candidates[agent] = Set(threads.map { format.candidateKey($0.threadID) }) }
            for thread in threads {
                let picked = TranscriptCandidates.catalogPick(thread) { path -> TranscriptCandidates.CatalogAttempt<TranscriptSummary> in
                    locked {
                        guard let file = files[path] else { kept[path] = nil; return .missing }
                        let stamp = KeptStamp(modifiedAt: file.modifiedAt, size: file.data.count, identity: file.identity, changed: file.changed)
                        if let entry = kept[path], entry.stamp == stamp {
                            guard let summary = entry.summary, summary.id == thread.threadID else { return .failed }
                            return .read(format.withShared(summary, shared))
                        }
                        kept[path] = nil
                        guard !file.unreadable else { return .failed }
                        // The recorded identity decides, as for a member's
                        // read: a file named for this thread that records
                        // another session, or none, is not this thread's.
                        guard let (lines, _) = try? Self.identityLines(file.data, scan: format.identityScan),
                              format.identity(lines: lines, expecting: thread.threadID) == .verified else { return .failed }
                        counts.catalogParses += 1
                        let locator = TranscriptLocator(host: host, path: path)
                        let window = TranscriptBytes.defaultWindow
                        var input = TranscriptBytes(head: Data(file.data.prefix(window)),
                                                    tail: file.data.count > window ? Data(file.data.suffix(min(window, file.data.count - window))) : nil,
                                                    fileSize: file.data.count)
                        var result = format.facts(input, name: format.name(path: path), locator: locator, modifiedAt: file.modifiedAt, shared: shared)
                        if case .needsWiderHead(let size) = result {
                            counts.widerReads += 1
                            input = input.with(widerHead: Data(file.data.prefix(size)))
                            result = format.facts(input, name: format.name(path: path), locator: locator, modifiedAt: file.modifiedAt, shared: shared)
                        }
                        if case .summary(let summary) = result, summary.id == thread.threadID {
                            kept[path] = Kept(stamp: stamp, summary: format.withShared(summary, .empty))
                            return .read(summary)
                        }
                        if case .unparseable = result { kept[path] = Kept(stamp: stamp, summary: nil) }
                        return .failed
                    }
                }
                if let picked { summaries.append(picked) }
            }
        }
        // A completed listing: nothing is kept for a path it did not name.
        locked {
            let listed = Set(paths.map(\.1))
            let complete = Set(Agent.allCases.filter { query.agents.contains($0) && !broken.contains($0) })
            kept = kept.filter { path, entry in
                listed.contains(path) || !(entry.summary.map { complete.contains($0.agent) } ?? true)
            }
        }
        summaries.sort { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt ? lhs.id < rhs.id
                : (query.newestFirst ? lhs.modifiedAt > rhs.modifiedAt : lhs.modifiedAt < rhs.modifiedAt)
        }
        return (failed, summaries, candidates)
    }

    /// One listing of the agent's files, the hook, a turn, then what was
    /// recorded meanwhile: the same decision every host makes.
    public func proveAbsent(ids: Set<String>, agent: Agent) async -> AbsenceProof {
        guard !Task.isCancelled else { return .unproven }
        let token = UUID()
        locked { proofWatches[token] = (agent, []) }
        func unproven() -> AbsenceProof { locked { proofWatches[token] = nil }; return .unproven }
        await proofListingGate?.wait()
        guard !Task.isCancelled else { return unproven() }
        let (listed, exhaustive, observing): ([String]?, Bool, Bool) = locked {
            counts.roundTrips += 1
            guard !transportBroken else { return (nil, false, false) }
            guard !brokenListings.contains(agent) else { return (nil, false, true) }
            return (listedPathsLocked(agent), !notExhaustive.contains(agent), true)
        }
        proofHook?()
        await Task.yield()
        guard !Task.isCancelled else { return unproven() }
        // Observation must have lasted to the end: a transport that dropped
        // meanwhile left its mark, and one that is down now proves nothing.
        let (events, stillObserving) = locked { (proofWatches.removeValue(forKey: token)?.events ?? [], !transportBroken) }
        return AbsenceProof.decide(ids: ids, format: TranscriptFormats.format(for: agent), listed: listed,
                                   exhaustive: exhaustive, events: events, observing: observing && stillObserving)
    }

    /// Codex only: the one rollout header in the window for this folder.
    public func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult {
        try Task.checkCancellation()
        return locked {
            counts.roundTrips += 1
            if transportBroken || brokenListings.contains(.codex) { return .incomplete }
            let format = CodexFormat()
            var matches: [(String, AdoptionCandidate)] = []
            for (path, file) in files where file.agent == .codex {
                let line = file.data.prefix { $0 != 0x0a }
                do {
                    guard let header = try format.header(firstLine: Data(line)) else { continue }
                    if header.cwd == request.directory, abs(header.createdAt.timeIntervalSince(request.startedAt)) <= request.window {
                        matches.append((path, header))
                    }
                } catch {
                    if abs(file.modifiedAt.timeIntervalSince(request.startedAt)) <= request.window { return .incomplete }
                }
            }
            switch matches.count {
            case 0: return .none
            case 1: return .adopted(id: matches[0].1.id, locator: TranscriptLocator(host: host, path: matches[0].0))
            default: return .ambiguous
            }
        }
    }
}

/// A one-shot gate: everything waiting on it resumes when it opens.
public final class FakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellable: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) public var arrivals = 0
    public init() {}

    /// Like `wait()`, but a cancelled waiter stops waiting: it returns at
    /// once, gate still shut, as a transport that honours cancellation would.
    public func waitUnlessCancelled() async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                arrivals += 1
                if isOpen || Task.isCancelled { lock.unlock(); continuation.resume(); return }
                cancellable[token] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock(); let continuation = cancellable.removeValue(forKey: token); lock.unlock()
            continuation?.resume()
        }
    }
    public func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            arrivals += 1
            if isOpen { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
    public func open() {
        lock.lock(); isOpen = true
        let pending = waiters + Array(cancellable.values); waiters.removeAll(); cancellable.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// Every SQL statement a traced database ran (`TempleDB.inMemory(tracing:)`).
public final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    public init() {}
    public func record(_ statement: String) { lock.lock(); recorded.append(statement); lock.unlock() }
    public var statements: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// Statements that write session rows (`UPDATE session_state`).
    public var sessionRowUpdates: Int { statements.filter { $0.uppercased().hasPrefix("UPDATE SESSION_STATE") }.count }
    public func reset() { lock.lock(); recorded.removeAll(); lock.unlock() }

    /// An in-memory database whose statements land in a new trace.
    public static func database() throws -> (TempleDB, SQLTrace) {
        let trace = SQLTrace()
        return (try TempleDB.inMemory(tracing: { trace.record($0) }), trace)
    }
}
