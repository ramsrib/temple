import Foundation
import TempleCore

/// What a remote source needs from its host for one query: an exec (the
/// host's connection with its resolved PATH) and, per requested id and
/// agent, where that session's transcripts are. Production is
/// `RemoteSessions`; tests hand one over directly.
public protocol RemoteTranscriptProvider: Sendable {
    /// Throws when the host can't be asked at all (its settings changed,
    /// ssh couldn't read its configuration): a transport failure.
    func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext
    /// A query failed in transit: the next one resolves the environment again.
    func transportFailed() async
}

public struct RemoteTranscriptContext: Sendable {
    public var exec: RemoteExec
    /// Per id and agent: where to look. A missing entry is a root Temple
    /// doesn't know, which is never searched (and never absence).
    public var roots: [String: [Agent: RemoteTranscriptRoot]]
    public init(exec: RemoteExec, roots: [String: [Agent: RemoteTranscriptRoot]]) {
        self.exec = exec; self.roots = roots
    }
}

/// A host's transcripts, read by known path over ssh (docs/designs/
/// remote-ssh.md section 6, phase 2). The v1 answers for what it cannot
/// know stand: no catalog, no live changes, `complete` always empty (a
/// `find` over ssh is not an audited listing), folder evidence unknown and
/// absence never proven, so a remote row is never dimmed, tagged or
/// auto-archived for a missing transcript. What it adds is `locate` and
/// `read`: a row that lacks a title, folder or date fills from its own
/// transcript, through the engine like any host's.
///
/// - `locate` looks up only the ids it is asked for (rows Temple has), in
///   one exec per call, `find` narrowed to those names under each
///   session's own root; nothing else on the host is listed.
/// - `read` is one exec (a second only when the format asks for a wider
///   head, or a Claude identity needs more than the first window); a file
///   whose opening and closing stats differ is read again, three times,
///   then `.changedDuringRead`.
/// - Transport failure is never absence: both throw `.transport`.
/// - One actor per host: two execs at a time, locates arriving within
///   250 ms answered by one exec, and a circuit breaker (three transport
///   failures in a row, then nothing is spawned for ten minutes; an
///   explicit open's `refresh` gets through once).
public struct RemoteSessionSource: HostSessionSource {
    public let host: HostID
    public var capabilities: Set<HostCapability> { [] }
    let access: RemoteTranscriptAccess?

    /// A source that reads nothing (no provider): every locate is empty
    /// and every read a transport failure.
    public init(host: HostID) {
        precondition(!host.isLocal)
        self.host = host
        access = nil
    }

    public init(host: HostID, provider: RemoteTranscriptProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(!host.isLocal)
        self.host = host
        access = RemoteTranscriptAccess(host: host, provider: provider, now: now)
    }

    public func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        let name = host.rawValue
        return AsyncThrowingStream { continuation in
            continuation.yield(.storeFailed(agent: nil, message: "Temple doesn't list sessions on \(name)."))
            continuation.finish()
        }
    }

    /// Identity on a host is `RemoteSessions`' (the process tree, or the
    /// user's yes); the seam's adoption window proves nothing here.
    public func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .incomplete }

    /// Nothing ever changes from here; the stream ends with its consumer.
    public func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { _ in }
    }

    public func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        guard let access else { return LocateResult(coverage: 0, candidates: [:], complete: [], sharedRevision: [:]) }
        return try await access.locate(requests)
    }

    public func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String,
                     facts: Bool) async throws -> TranscriptRead {
        guard let access else {
            throw TranscriptReadError.transport("Temple doesn't read transcripts on \(host.rawValue).")
        }
        guard locator.host == host else { throw TranscriptReadError.unreadable("not a transcript on \(host.rawValue)") }
        return try await access.read(locator, agent: agent, expecting: id, facts: facts)
    }

    public func directoryEvidence(_ path: String) async -> DirectoryEvidence { .unknown }

    public func proveAbsent(ids: Set<String>, agent: Agent) async -> AbsenceProof { .unproven }

    public func shutDown() async { await access?.shutDown() }

    /// What this source has spawned and parsed, for tests and diagnostics.
    public var counters: RemoteTranscriptCounters { access?.counters.value ?? RemoteTranscriptCounters() }
}

public extension RemoteSessionSource {
    /// The production source: the host's own `RemoteSessions` (its
    /// connection, PATH, environment and runs).
    @MainActor init(sessions: RemoteSessions) {
        self.init(host: sessions.host, provider: SessionsTranscriptProvider(sessions: sessions))
    }
}

struct SessionsTranscriptProvider: RemoteTranscriptProvider {
    let sessions: RemoteSessions
    func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext {
        try await sessions.transcriptContext(sessionIDs: sessionIDs, refresh: refresh)
    }
    func transportFailed() async { await sessions.enrichmentTransportFailed() }
}

public struct RemoteTranscriptCounters: Sendable, Equatable {
    /// Locate execs (each one `find` round trip).
    public var listings = 0
    /// Read execs, wider ones included.
    public var reads = 0
    public var widerReads = 0
    public var parses = 0
    /// Calls answered by the open breaker without spawning anything.
    public var refused = 0
    public init() {}
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counters = RemoteTranscriptCounters()
    var value: RemoteTranscriptCounters { lock.withLock { counters } }
    func update(_ body: (inout RemoteTranscriptCounters) -> Void) { lock.withLock { body(&counters) } }
}

/// The per-host actor behind `RemoteSessionSource`.
actor RemoteTranscriptAccess {
    let host: HostID
    let provider: RemoteTranscriptProvider
    let now: @Sendable () -> Date
    nonisolated let counters = CounterBox()

    init(host: HostID, provider: RemoteTranscriptProvider, now: @escaping @Sendable () -> Date) {
        self.host = host; self.provider = provider; self.now = now
    }

    // MARK: Breaker

    static let breakerThreshold = 3
    static let breakerPause: TimeInterval = 10 * 60
    private var failures = 0
    private var failingSince: Date?
    private var nextTry: Date?
    /// The coverage generation: moves on the first listing after a
    /// transport failure (what was seen before can't be vouched for).
    private var coverage: UInt64 = 1
    private var lostTransport = false

    /// Whether a query may spawn now; the breaker's words when not.
    private func admit(bypass: Bool) throws {
        guard let nextTry, now() < nextTry, !bypass else { return }
        counters.update { $0.refused += 1 }
        throw Breaker.tripped(message(until: nextTry))
    }

    private func message(until next: Date) -> String {
        let since = failingSince ?? next
        return "\(host.rawValue) unreachable since \(Self.clock(since)); next try at \(Self.clock(next))"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    enum Breaker: Error { case tripped(String) }

    private func succeeded() {
        failures = 0; failingSince = nil; nextTry = nil
    }

    private func transportFailed() async {
        failures += 1
        if failingSince == nil { failingSince = now() }
        lostTransport = true
        if failures >= Self.breakerThreshold { nextTry = now().addingTimeInterval(Self.breakerPause) }
        await provider.transportFailed()
    }

    // MARK: Two execs at a time

    static let concurrency = 2
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if running < Self.concurrency { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    // MARK: Locate

    static let coalescing: Duration = .milliseconds(250)
    typealias Waiter = CheckedContinuation<Result<LocateResult, Error>, Never>

    /// Locates answered by one exec: collecting for 250 ms from the first,
    /// then listing. Unanswered waiters are resumed exactly once, with the
    /// listing's result, a cancellation, or the quit.
    private final class Batch {
        let id = UUID()
        var requests: [LocateRequest] = []
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
    }
    /// The batch still collecting, if any.
    private var collecting: Batch?
    /// Every batch not yet answered, collecting or listing.
    private var batches: [UUID: Batch] = [:]
    private var shut = false
    /// Each listed Codex file's canonical home, for the shared inputs a read
    /// of it takes.
    private var codexHomes: [String: String] = [:]

    func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        guard !shut else { throw LocateError.transport("Temple is quitting") }
        let wanted = Set(requests.map(\.id))
        let waiter = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enlist(requests, waiter: waiter, continuation)
            }
        } onCancel: {
            Task { await self.abandon(waiter) }
        }
        let located = try result.get()
        return LocateResult(coverage: located.coverage, candidates: located.candidates.filter { wanted.contains($0.key) },
                            complete: [], sharedRevision: [:])
    }

    private func enlist(_ requests: [LocateRequest], waiter: UUID, _ continuation: Waiter) {
        guard !shut else { return continuation.resume(returning: .failure(LocateError.transport("Temple is quitting"))) }
        guard !Task.isCancelled else { return continuation.resume(returning: .failure(Self.cancelled)) }
        let batch: Batch
        if let current = collecting {
            batch = current
        } else {
            batch = Batch()
            collecting = batch
            batches[batch.id] = batch
            batch.task = Task { [weak self] in
                try? await Task.sleep(for: Self.coalescing)
                await self?.flush(batch)
            }
        }
        batch.requests += requests
        batch.waiters[waiter] = continuation
    }

    static let cancelled = LocateError.transport("the lookup was cancelled")

    /// A caller went away: it is answered now, and a batch nobody waits for
    /// any more is cancelled (its exec killed if one runs).
    private func abandon(_ waiter: UUID) {
        guard let batch = batches.values.first(where: { $0.waiters[waiter] != nil }),
              let continuation = batch.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: .failure(Self.cancelled))
        if batch.waiters.isEmpty {
            if collecting === batch { collecting = nil }
            batch.task?.cancel()
        }
    }

    /// The batch's one listing, in the batch's own task, so a quit (or the
    /// last caller leaving) cancels the exec in flight and its ssh process
    /// is killed rather than left to run on.
    private func flush(_ batch: Batch) async {
        if collecting === batch { collecting = nil }
        let result: Result<LocateResult, Error>
        if shut {
            result = .failure(LocateError.transport("Temple is quitting"))
        } else if Task.isCancelled || batch.waiters.isEmpty {
            result = .failure(Self.cancelled)
        } else {
            do { result = .success(try await listing(batch.requests)) } catch { result = .failure(error) }
        }
        batches[batch.id] = nil
        let waiters = batch.waiters.values
        batch.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func shutDown() {
        shut = true
        collecting = nil
        for batch in batches.values {
            batch.task?.cancel()
            let waiters = batch.waiters.values
            batch.waiters.removeAll()
            for waiter in waiters { waiter.resume(returning: .failure(LocateError.transport("Temple is quitting"))) }
        }
        batches.removeAll()
    }

    private struct Group: Hashable {
        let agent: Agent
        let root: RemoteTranscriptRoot
    }

    private func listing(_ requests: [LocateRequest]) async throws -> LocateResult {
        do { try admit(bypass: requests.contains(where: \.refresh)) } catch Breaker.tripped(let words) {
            throw LocateError.transport(words)
        }
        // Only ids that can be named on a host; a hint only on this host,
        // and only an absolute path.
        let named = requests.filter { RemoteQuoting.isSafeToken($0.id) }
        let ids = Array(Set(named.map(\.id))).sorted()
        await acquire()
        defer { release() }
        let context: RemoteTranscriptContext
        do {
            context = try await provider.transcriptContext(sessionIDs: ids, refresh: requests.contains(where: \.refresh))
        } catch {
            await transportFailed()
            throw LocateError.transport(error.localizedDescription)
        }
        var groups: [Group] = []
        var members: [Group: [String]] = [:]
        for request in named {
            for agent in request.agent.map({ [$0] }) ?? Agent.allCases {
                guard let root = context.roots[request.id]?[agent] else { continue }
                let group = Group(agent: agent, root: root)
                if members[group] == nil { groups.append(group) }
                if members[group]?.contains(request.id) != true { members[group, default: []].append(request.id) }
            }
        }
        let hints = Array(Set(named.compactMap { request -> String? in
            guard let hint = request.hint, hint.host == host, hint.path.hasPrefix("/") else { return nil }
            return hint.path
        })).sorted()
        var args: [String] = []
        for group in groups {
            args += [group.agent.rawValue, group.root.state, group.root.value, group.root.base,
                     members[group, default: []].joined(separator: " ")]
        }
        args += ["--"] + hints
        counters.update { $0.listings += 1 }
        let output: RemoteOutput
        do {
            output = try await context.exec.run(script: RemoteTranscripts.locateScript, args: args,
                                                deadline: RemoteTranscripts.locateDeadline)
        } catch {
            // A cancellation (a quit) says nothing about the host.
            if !(error is CancellationError) { await transportFailed() }
            throw LocateError.transport(error.localizedDescription)
        }
        guard output.reachedCommand, output.status == 0,
              let answer = RemoteTranscripts.parseLocate(output.data, groups: groups.count) else {
            await transportFailed()
            throw LocateError.transport(Self.failureLine(output, what: "the lookup"))
        }
        succeeded()
        if lostTransport { lostTransport = false; coverage &+= 1 }

        var candidates: [String: [TranscriptCandidate]] = [:]
        for request in named {
            var list: [TranscriptCandidate] = []
            for agent in request.agent.map({ [$0] }) ?? Agent.allCases {
                guard let root = context.roots[request.id]?[agent],
                      let index = groups.firstIndex(of: Group(agent: agent, root: root)),
                      case .ok(let canonical)? = answer.roots[index],
                      let files = answer.lists[index] ?? nil else { continue }
                let format = TranscriptFormats.format(for: agent)
                let store = canonical == "/" ? "/" + (agent == .claude ? "projects/" : "sessions/")
                    : canonical + (agent == .claude ? "/projects/" : "/sessions/")
                var stats: [String: CandidateStat] = [:]
                for file in files where file.path.hasPrefix(store) { stats[file.path] = .present(file.signature) }
                // The row's recorded path, when it lies in this root's store.
                var hintPath: String?
                if let hint = request.hint?.path, hint.hasPrefix(store), let stat = answer.hints[hint] {
                    hintPath = hint
                    if stats[hint] == nil { stats[hint] = stat }
                }
                let hintPresent = hintPath.map { stats[$0] != .missing } ?? false
                for assignment in TranscriptCandidates.assign(id: request.id, format: format, listed: files.map(\.path).sorted(),
                                                             hint: hintPath, hintPresent: hintPresent) {
                    let stat = stats[assignment.path] ?? .missing
                    // A hint whose file is gone is no candidate.
                    if assignment.role == .hinted, stat == .missing { continue }
                    if agent == .codex { remember(codexHome: canonical, for: assignment.path) }
                    list.append(TranscriptCandidate(locator: TranscriptLocator(host: host, path: assignment.path),
                                                    agent: agent, role: assignment.role, stat: stat))
                }
            }
            candidates[request.id] = list
        }
        for request in requests where candidates[request.id] == nil { candidates[request.id] = [] }
        return LocateResult(coverage: coverage, candidates: candidates, complete: [], sharedRevision: [:])
    }

    private func remember(codexHome: String, for path: String) {
        if codexHomes.count > 4096 { codexHomes.removeAll() }
        codexHomes[path] = codexHome
    }

    static func failureLine(_ output: RemoteOutput, what: String) -> String {
        if !output.reachedCommand || output.status != 0 {
            return output.firstErrorLine ?? "ssh exited with status \(output.status)"
        }
        return "\(what)'s answer was cut short"
    }

    // MARK: Read

    static let attempts = 3

    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        guard !shut else { throw TranscriptReadError.transport("Temple is quitting") }
        do { try admit(bypass: false) } catch Breaker.tripped(let words) { throw TranscriptReadError.transport(words) }
        let format = TranscriptFormats.format(for: agent)
        let window = TranscriptBytes.defaultWindow
        var headBytes = window
        if case .firstLine(let cap) = format.identityScan { headBytes = max(headBytes, cap) }
        // Shared inputs (Codex), the session's lines only, from its own home.
        let home = facts && agent == .codex ? codexHomes[locator.path] ?? Self.codexHome(of: locator.path) : nil
        let shareID = RemoteQuoting.isSafeToken(id) ? id : ""
        var changes = 0
        var widened = false
        while true {
            let answer = try await readOnce(locator.path, headBytes: headBytes, window: window, facts: facts,
                                            home: home.flatMap { shareID.isEmpty ? nil : $0 } ?? "", id: shareID)
            let bytes: RemoteTranscripts.ReadBytes
            switch answer {
            case .missing: throw TranscriptReadError.missing
            case .unreadable(let why): throw TranscriptReadError.unreadable(why)
            case .bytes(let read): bytes = read
            }
            guard bytes.opening == bytes.closing else {
                changes += 1
                if changes >= Self.attempts { throw TranscriptReadError.changedDuringRead }
                continue
            }
            let size = bytes.closing.size
            guard let identity = try RemoteTranscripts.identity(format, head: bytes.head, size: size, expecting: id) else {
                // Undecided in the first window: the identity scan's full cap.
                if case .lines(let cap) = format.identityScan, headBytes < cap { headBytes = cap; continue }
                throw TranscriptReadError.unreadable("the transcript's identity couldn't be read")
            }
            var used = identity.bytesRead
            var summary: TranscriptSummary?
            if facts, identity.verdict == .verified {
                let head = Data(bytes.head.prefix(window))
                var transcript = TranscriptBytes(head: head, tail: bytes.tail, fileSize: size, window: window)
                let name = format.name(path: locator.path)
                let shared = format.sharedFacts(bytes.shared)
                var parsed = format.facts(transcript, name: name, locator: locator, modifiedAt: bytes.closing.modifiedAt,
                                          shared: shared)
                if case .needsWiderHead(let wider) = parsed {
                    if bytes.head.count < min(wider, size), headBytes < wider, !widened {
                        // One more exec, for the wider head.
                        widened = true
                        headBytes = wider
                        counters.update { $0.widerReads += 1 }
                        continue
                    }
                    transcript = transcript.with(widerHead: Data(bytes.head.prefix(wider)))
                    used += min(wider, bytes.head.count)
                    parsed = format.facts(transcript, name: name, locator: locator, modifiedAt: bytes.closing.modifiedAt,
                                          shared: shared)
                }
                counters.update { $0.parses += 1 }
                used += head.count + (bytes.tail?.count ?? 0) + bytes.shared.values.reduce(0) { $0 + $1.count }
                if case .summary(let value) = parsed { summary = value }
            }
            return TranscriptRead(identity: identity.verdict, summary: summary, signature: bytes.closing,
                                  bytesRead: used, sharedRevision: nil)
        }
    }

    private func readOnce(_ path: String, headBytes: Int, window: Int, facts: Bool, home: String,
                          id: String) async throws -> RemoteTranscripts.ReadAnswer {
        do { try admit(bypass: false) } catch Breaker.tripped(let words) { throw TranscriptReadError.transport(words) }
        await acquire()
        defer { release() }
        let context: RemoteTranscriptContext
        do { context = try await provider.transcriptContext(sessionIDs: [], refresh: false) } catch {
            await transportFailed()
            throw TranscriptReadError.transport(error.localizedDescription)
        }
        counters.update { $0.reads += 1 }
        let output: RemoteOutput
        do {
            output = try await context.exec.run(script: RemoteTranscripts.readScript,
                                                args: [path, String(headBytes), String(window), facts ? "1" : "0", home, id],
                                                deadline: RemoteTranscripts.readDeadline)
        } catch {
            if !(error is CancellationError) { await transportFailed() }
            throw TranscriptReadError.transport(error.localizedDescription)
        }
        guard output.reachedCommand, output.status == 0, let answer = RemoteTranscripts.parseRead(output.data) else {
            await transportFailed()
            throw TranscriptReadError.transport(Self.failureLine(output, what: "the read"))
        }
        succeeded()
        return answer
    }

    /// A rollout's Codex home from its path's own shape
    /// (`<home>/sessions/YYYY/MM/DD/rollout-….jsonl`), for a file no
    /// listing named; nil for any other shape.
    static func codexHome(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 7, parts.last?.hasPrefix("rollout-") == true, parts[parts.count - 5] == "sessions" else { return nil }
        let digits = { (part: Substring, count: Int) in part.count == count && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) }
        guard digits(parts[parts.count - 4], 4), digits(parts[parts.count - 3], 2), digits(parts[parts.count - 2], 2) else { return nil }
        let home = parts[..<(parts.count - 5)].joined(separator: "/")
        return home.isEmpty ? nil : home
    }
}
