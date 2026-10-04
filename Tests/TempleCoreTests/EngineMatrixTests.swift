import XCTest
@testable import TempleCore
import TempleTestSupport

/// The engine's commit gate, authorization and revocation, against a
/// scripted host (`FakeHostSource`) and a SQL-tracing database. "No stale
/// write" is asserted on the statements the consumer's persister actually
/// ran (`SQLTrace.sessionRowUpdates`), not on engine bookkeeping.
final class EngineMatrixTests: XCTestCase {
    // MARK: Fixtures

    static let remote = HostID(rawValue: "fake-remote")

    func uuid() -> String { UUID().uuidString.lowercased() }

    func claudePath(_ id: String) -> String { "/home/me/.agent-a/projects/-work/\(id).jsonl" }
    func codexPath(_ id: String, stamp: String = "2026-10-01T10-00-00") -> String {
        "/home/me/.agent-b/sessions/2026/10/01/rollout-\(stamp)-\(id).jsonl"
    }

    func claudeData(_ id: String, cwd: String = "/work/project", prompt: String? = "First prompt") -> Data {
        var lines = [#"{"type":"system","sessionId":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-01T10:00:00Z"}"#]
        if let prompt { lines.append(#"{"type":"user","sessionId":"\#(id)","message":{"content":"\#(prompt)"}}"#) }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func codexData(_ id: String, cwd: String = "/work/project", prompt: String? = nil) -> Data {
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-01T10:00:00Z"}}"#]
        if let prompt { lines.append(#"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#) }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func history(_ id: String, _ text: String) -> Data {
        Data(#"{"session_id":"\#(id)","ts":1,"text":"\#(text)"}"#.utf8 + [0x0a])
    }

    /// A clock tests move by hand; the engine's sleeps move it too (after a
    /// short real pause, so a retry loop cannot spin).
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
        func advance(_ duration: Duration) {
            let parts = duration.components
            advance(TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
        }
    }

    /// The consumer's writes, failing on demand, with every attempt recorded.
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private let persister: FactPersister
        private var failures = 0
        private(set) var attempts: [AuthorizedFacts] = []
        private(set) var successes: [AuthorizedFacts] = []
        init(_ database: TempleDB) { persister = FactPersister(database: database) }
        func failNext(_ count: Int) { lock.lock(); failures = count; lock.unlock() }
        var attempted: [AuthorizedFacts] { lock.lock(); defer { lock.unlock() }; return attempts }
        var succeeded: [AuthorizedFacts] { lock.lock(); defer { lock.unlock() }; return successes }
        func persist(_ id: String, _ facts: AuthorizedFacts) throws -> SessionWriteOutcome {
            lock.lock()
            attempts.append(facts)
            if failures > 0 { failures -= 1; lock.unlock(); throw CocoaError(.fileWriteUnknown) }
            lock.unlock()
            let outcome = try persister.persist(id, facts)
            lock.lock(); successes.append(facts); lock.unlock()
            return outcome
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [EngineSnapshot] = []
        func append(_ snapshot: EngineSnapshot) { lock.lock(); all.append(snapshot); lock.unlock() }
        var snapshots: [EngineSnapshot] { lock.lock(); defer { lock.unlock() }; return all }
        var latest: EngineSnapshot? { snapshots.last }
    }

    struct Harness {
        let source: FakeHostSource
        let db: TempleDB
        let trace: SQLTrace
        let engine: SessionEngine
        let clock: Clock
        let writes: Writes
        let committer: FactCommitter
        let recorder: Recorder
    }

    private var tasks: [Task<Void, Never>] = []
    private var engines: [SessionEngine] = []

    override func tearDown() async throws {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        for engine in engines { await engine.stop() }
        engines.removeAll()
        try await super.tearDown()
    }

    /// `consume: false` leaves the snapshots to the test (no automatic writes).
    func harness(host: HostID = remote, hasInodes: Bool = true, database: TempleDB? = nil, trace: SQLTrace? = nil,
                 consume: Bool = true) throws -> Harness {
        let source = FakeHostSource(host: host, hasInodes: hasInodes)
        let (db, trace) = try database.map { ($0, trace ?? SQLTrace()) } ?? SQLTrace.database()
        let clock = Clock()
        let engine = SessionEngine(source: source, database: db, now: { clock.now },
                                   sleep: { duration in
                                       try await Task.sleep(for: .milliseconds(15))
                                       clock.advance(duration)
                                   })
        engines.append(engine)
        let writes = Writes(db)
        let committer = FactCommitter(persist: { try writes.persist($0, $1) }, now: { clock.now })
        let recorder = Recorder()
        let stream = engine.snapshots()
        tasks.append(Task {
            for await snapshot in stream {
                // Received before it is recorded: a test that sees a
                // snapshot recorded knows the consumer has it.
                if consume { committer.receive(snapshot.facts) }
                recorder.append(snapshot)
            }
        })
        return Harness(source: source, db: db, trace: trace, engine: engine, clock: clock, writes: writes,
                       committer: committer, recorder: recorder)
    }

    func join(_ h: Harness, _ id: String, agent: Agent? = .claude, path: String? = nil, host: HostID? = nil,
              core: SessionCore? = nil) throws {
        let host = host ?? h.source.host
        try h.db.join(sessionID: id, via: .imported, agent: agent,
                      locator: path.map { TranscriptLocator(host: host, path: $0) },
                      core: core ?? SessionCore(host: host))
    }

    func complete(_ h: Harness, _ id: String) throws {
        try h.db.fillCoreFields(sessionID: id, host: h.source.host, agent: .claude, directory: "/done",
                                title: "Done", lastActiveAt: Date(timeIntervalSince1970: 1))
    }

    func waitUntil(timeout: TimeInterval = 5, _ message: String = "condition", _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            guard Date() < deadline else { XCTFail("timed out: \(message)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits for a condition at most `timeout`, without failing: for what
    /// the code under test should do, where the old code never would.
    func briefly(_ timeout: TimeInterval = 1, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Holds every listing from now on until the returned gate opens.
    func holdListings(_ h: Harness) -> FakeGate {
        let gate = FakeGate()
        h.source.locateGate = gate
        return gate
    }

    /// The failed write's retry comes due now, while the listing that would
    /// follow the invalidation is still held.
    func retryNow(_ h: Harness) {
        h.clock.advance(5)
        h.committer.retryDue()
    }

    /// Lets queued work run without a condition to wait for.
    func settle(_ milliseconds: Int = 150) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    func row(_ h: Harness, _ id: String) throws -> SessionState? { try h.db.sessionState(id) }

    func resolution(_ h: Harness, _ id: String) -> MemberResolution? { h.engine.latestSnapshot?.resolutions[id] }

    func isLoaded(_ h: Harness, _ id: String) -> Bool {
        if case .loaded? = resolution(h, id) { return true }
        return false
    }

    /// Holds the next read in flight; returns the gate once it has arrived.
    func holdNextRead(_ h: Harness, start: Bool = true) async throws -> FakeGate {
        let gate = FakeGate()
        h.source.readGate = gate
        if start { await h.engine.start() }
        try await waitUntil("a read in flight") { gate.arrivals >= 1 }
        return gate
    }

    // MARK: §2.6 suspended-read matrix

    /// 1. A leave while the read is in flight: nothing is written, the member
    /// is gone, and the read was the only one.
    func testLeaveDuringReadWritesNothing() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
        try await waitUntil("member gone") { h.engine.latestSnapshot?.resolutions[id] == nil }
        h.trace.reset()
        gate.open()
        try await settle()
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
        XCTAssertEqual(h.source.counters.reads, 1)
        XCTAssertNil(h.engine.latestSnapshot?.resolutions[id])
        XCTAssertTrue(h.writes.attempted.isEmpty)
    }

    /// 2. Leave and rejoin on the same host mid-read: the old read is
    /// dropped, exactly one new read happens, and one fill lands — under the
    /// new membership.
    func testLeaveAndRejoinSameHostDuringReadReadsOnceMoreAndFillsOnce() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id, prompt: "Rejoined prompt"))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
        try join(h, id, path: claudePath(id))
        let incarnation = try XCTUnwrap(try row(h, id)?.incarnation)
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(h.source.counters.reads, 2)
        XCTAssertEqual(h.trace.sessionRowUpdates, 1, "one fill")
        XCTAssertEqual(h.writes.succeeded.map(\.incarnation), [incarnation])
        XCTAssertEqual(try row(h, id)?.title, "Rejoined prompt")
    }

    /// 3. Leave and rejoin on another host mid-read: this engine writes
    /// nothing and drops the member; the database refuses stale facts too.
    func testRejoinOnAnotherHostDuringReadWritesNothing() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let stale = try XCTUnwrap(try row(h, id)?.incarnation)
        let gate = try await holdNextRead(h)
        XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
        try h.db.join(sessionID: id, via: .imported, agent: .claude, core: SessionCore(host: .local))
        try await waitUntil("member gone") { h.engine.latestSnapshot?.resolutions[id] == nil }
        h.trace.reset()
        gate.open()
        try await settle()
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
        XCTAssertTrue(h.writes.attempted.isEmpty)
        // The predicate: facts for the old membership on the old host.
        let facts = AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 0, incarnation: stale),
            locator: TranscriptLocator(host: h.source.host, path: claudePath(id)), agent: .claude,
            signature: TranscriptSignature(modifiedAt: Date(), size: 1, identity: 1), coverage: 1,
            sharedRevision: nil, summary: nil)
        XCTAssertEqual(try FactPersister(database: h.db).persist(id, facts), .ownershipMismatch)
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
    }

    /// 4. Stop and start mid-read: the old run's read is dropped; the fresh
    /// run resolves with its own read.
    func testStopStartDuringReadDropsTheOldRunsResult() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        await h.engine.stop()
        await h.engine.start()
        try await waitUntil("second read in flight") { gate.arrivals >= 2 }
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(h.source.counters.reads, 2)
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
        // Epochs: 1 (first start), 2 (stop), 3 (second start).
        XCTAssertEqual(Set(h.writes.succeeded.map(\.authorization.runEpoch)), [3], "only the fresh run's facts")
    }

    /// 5. A coverage reset mid-read: dropped, and queued again exactly once.
    func testCoverageResetDuringReadIsDroppedAndRequeuedOnce() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        let before = await h.engine.currentCoverage
        h.source.dropEvents()
        try await waitUntil("coverage moved") { await h.engine.currentCoverage > before }
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(h.source.counters.reads, 2)
        XCTAssertEqual(h.source.counters.locates, 2)
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
    }

    /// 6. An explicit open mid-read: dropped, queued again once with a
    /// refreshed listing and a reset parse budget.
    func testExplicitRequestDuringReadIsDroppedAndRequeuedOnce() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        await h.engine.requestResolution(id)
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(h.source.counters.reads, 2)
        XCTAssertEqual(h.source.counters.locates, 2)
        XCTAssertEqual(h.source.counters.parses, 2, "the budget was reset: the second read parsed too")
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
    }

    /// 7. New shared facts mid-read, for a member that wants a title: the
    /// in-flight read is an invalidated operation (E1) and writes nothing;
    /// the re-read carries the new shared title. One fill.
    func testSharedFactsDuringReadFillOnceFromTheReRead() async throws {
        let h = try harness()
        let id = uuid()
        h.source.setShared(.codex, CodexFormat.historyInput, Data())
        h.source.write(codexPath(id), agent: .codex, data: codexData(id, cwd: "/work/shared"))
        try join(h, id, agent: .codex, path: codexPath(id))
        let gate = try await holdNextRead(h)
        h.source.setShared(.codex, CodexFormat.historyInput, history(id, "Shared title"))
        try await waitUntil("invalidated") { (await h.engine.operationRevision(id) ?? 0) > 0 }
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        // The dropped read was charged (the parse backoff stands across a
        // shared-facts change), so the re-read waits it out: an identity
        // read first, then the facts read. Two parses, one fill.
        XCTAssertEqual(h.source.counters.parses, 2)
        XCTAssertEqual(h.source.counters.reads, 3)
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
        XCTAssertEqual(try row(h, id)?.title, "Shared title")
        XCTAssertEqual(try row(h, id)?.directory, "/work/shared")
    }

    /// 8. A newer revert appears while the old selected rollout is being
    /// read: the old read is dropped, and the fill is the new file's.
    func testANewSelectedRolloutWhileAReadIsInFlightDropsTheRead() async throws {
        let h = try harness()
        let id = uuid()
        let old = codexPath(id), new = codexPath(id, stamp: "2026-10-01T11-00-00")
        h.source.write(old, agent: .codex, data: codexData(id, cwd: "/old", prompt: "Old"))
        try join(h, id, agent: .codex, path: old)
        let gate = try await holdNextRead(h)
        h.source.write(new, agent: .codex, data: codexData(id, cwd: "/new", prompt: "New"))
        try await waitUntil("invalidated") { (await h.engine.operationRevision(id) ?? 0) > 0 }
        h.trace.reset()
        gate.open()
        try await waitUntil("filled") { try self.row(h, id)?.directory != nil }
        try await settle()
        XCTAssertEqual(try row(h, id)?.directory, "/new")
        XCTAssertEqual(try row(h, id)?.title, "New")
        XCTAssertEqual(try row(h, id)?.transcriptPath, new)
        XCTAssertFalse(h.writes.attempted.isEmpty)
        XCTAssertTrue(h.writes.attempted.allSatisfy { $0.locator.path == new }, "the old rollout's facts were never offered")
        XCTAssertEqual(resolution(h, id), .loaded(TranscriptLocator(host: h.source.host, path: new)))
    }

    /// 9. A fill that throws and then succeeds: one parse, two attempts, and
    /// the member loaded throughout.
    func testAFailedFillIsRetriedWithoutAReparse() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        h.writes.failNext(1)
        h.trace.reset()
        await h.engine.start()
        try await waitUntil("first attempt") { h.writes.attempted.count == 1 }
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
        h.clock.advance(2)
        h.committer.retryDue()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(h.source.counters.parses, 1)
        XCTAssertEqual(h.writes.attempted.count, 2)
        XCTAssertEqual(h.writes.attempted[0].authorization, h.writes.attempted[1].authorization)
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
        let firstLoaded = try XCTUnwrap(h.recorder.snapshots.firstIndex { if case .loaded? = $0.resolutions[id] { return true }; return false })
        XCTAssertTrue(h.recorder.snapshots[firstLoaded...].allSatisfy { if case .loaded? = $0.resolutions[id] { return true }; return false })
    }

    /// 10. A read-only database: loaded, nothing parsed, nothing authorized,
    /// and no loop.
    func testAReadOnlyDatabaseLoadsWithoutParsingOrAuthorizing() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/temple-engine-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")
        let id = uuid()
        do {
            let writer = try TempleDB(path: path)
            try writer.join(sessionID: id, via: .imported, agent: .claude,
                            locator: TranscriptLocator(host: Self.remote, path: claudePath(id)), core: SessionCore(host: Self.remote))
        }
        let readOnly = try TempleDB(readOnlyPath: path)
        let h = try harness(database: readOnly)
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        await h.engine.start()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        try await settle(300)
        XCTAssertEqual(h.source.counters.parses, 0)
        XCTAssertEqual(h.source.counters.reads, 1)
        XCTAssertEqual(h.source.counters.locates, 1)
        XCTAssertTrue(h.recorder.snapshots.allSatisfy { $0.facts.isEmpty })
        XCTAssertTrue(h.writes.attempted.isEmpty)
        XCTAssertNil(try readOnly.sessionState(id)?.title)
    }

    /// 11. Another writer fills the row while the read is in flight: the
    /// engine offers nothing (the row wants nothing), and reads no more.
    func testARowFilledElsewhereMidReadNeedsNoWriteAndNoMoreReads() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = try await holdNextRead(h)
        try complete(h, id)
        try await settle(80)
        h.trace.reset()
        gate.open()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        try await settle(300)
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
        XCTAssertEqual(h.source.counters.reads, 1)
        XCTAssertEqual(h.engine.latestSnapshot?.facts[id], nil)
        XCTAssertEqual(try row(h, id)?.title, "Done")
    }

    /// 12. The change stream ends (and throws): verdicts stand, the engine
    /// subscribes again after a backoff, and every member is located once.
    func testAnEndedChangeStreamResubscribesAndRelocatesEveryMemberOnce() async throws {
        let h = try harness()
        let ids = [uuid(), uuid()]
        for id in ids {
            h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
            try join(h, id, path: claudePath(id))
            try complete(h, id)
        }
        await h.engine.start()
        try await waitUntil("loaded") { ids.allSatisfy { self.isLoaded(h, $0) } }
        for (round, error) in [(1, nil), (2, CocoaError(.fileReadUnknown) as Error?)] {
            let locates = h.source.counters.locates
            let observed = h.recorder.snapshots.count
            h.source.endChanges(throwing: error)
            try await waitUntil("resubscribed") { await h.engine.currentReconnects == UInt64(round) && h.source.subscribers == 1 }
            try await waitUntil("relocated") { h.source.counters.locates == locates + 1 }
            try await settle()
            XCTAssertEqual(h.source.counters.locates, locates + 1)
            XCTAssertTrue(h.recorder.snapshots[observed...].allSatisfy { snapshot in
                ids.allSatisfy { if case .loaded? = snapshot.resolutions[$0] { return true }; return false }
            }, "verdicts kept")
        }
    }

    /// 13. The membership read fails in `start`: an empty snapshot, then a
    /// retry, then the members.
    func testAFailedMembershipReadPublishesEmptyAndRetries() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        await h.engine.failMembershipReads(1)
        await h.engine.start()
        try await waitUntil("first snapshot") { h.recorder.latest != nil }
        XCTAssertEqual(h.recorder.snapshots.first?.resolutions, [:])
        try await waitUntil("members appear") { self.isLoaded(h, id) }
    }

    /// 14. Transport failures: a verified member keeps its verdict, a new one
    /// is incomplete, and both resolve once the host is back.
    func testTransportFailuresKeepVerdictsAndRetryAfterABackoff() async throws {
        let h = try harness()
        let known = uuid(), new = uuid()
        h.source.write(claudePath(known), agent: .claude, data: claudeData(known))
        try join(h, known, path: claudePath(known))
        try complete(h, known)
        await h.engine.start()
        try await waitUntil("loaded") { self.isLoaded(h, known) }
        h.source.breakTransport()
        h.source.write(claudePath(new), agent: .claude, data: claudeData(new))
        try join(h, new, path: claudePath(new))
        h.source.append(claudePath(known), Data("\n{}".utf8))
        try await waitUntil("new is incomplete") { self.resolution(h, new) == .incomplete }
        XCTAssertTrue(isLoaded(h, known))
        XCTAssertGreaterThan(h.engine.metrics.retries, 0)
        h.source.breakTransport(false)
        try await waitUntil("recovered") { self.isLoaded(h, new) }
        XCTAssertTrue(isLoaded(h, known))
        XCTAssertTrue(h.recorder.snapshots.allSatisfy { snapshot in
            guard let verdict = snapshot.resolutions[known] else { return true }
            if case .loaded = verdict { return true }
            return verdict == .resolving
        }, "the verified member never lost its verdict")
    }

    /// 15. A transcript rewritten in place — same size, same inode where
    /// the host has inodes, different bytes — is a different transcript:
    /// the facts issued for the old bytes are revoked at once (a retry of
    /// their failed write, due while the next listing is held, writes
    /// nothing), identity is verified again and the row is filled from the
    /// new bytes.
    func testASameSizeRewriteRevokesFactsAndFillsFromTheNewBytes() async throws {
        for hasInodes in [true, false] {
            let h = try harness(hasInodes: hasInodes)
            let id = uuid()
            h.source.write(claudePath(id), agent: .claude, data: claudeData(id, cwd: "/aaaa", prompt: "First"))
            try join(h, id, path: claudePath(id))
            h.writes.failNext(1)
            await h.engine.start()
            try await waitUntil("first write failed") { h.writes.attempted.count == 1 }
            let reads = h.source.counters.reads
            let listings = holdListings(h)
            let rewritten = claudeData(id, cwd: "/bbbb", prompt: "Secnd")
            XCTAssertEqual(rewritten.count, claudeData(id, cwd: "/aaaa", prompt: "First").count)
            h.source.write(claudePath(id), agent: .claude, data: rewritten, inPlace: true)
            try await briefly { h.recorder.latest?.facts[id] == nil }
            retryNow(h)
            XCTAssertNil(try row(h, id)?.directory, "hasInodes: \(hasInodes): the old bytes' facts were written")
            listings.open()
            try await waitUntil("filled from the new bytes") { try self.row(h, id)?.directory != nil }
            XCTAssertEqual(try row(h, id)?.directory, "/bbbb", "hasInodes: \(hasInodes)")
            XCTAssertEqual(try row(h, id)?.title, "Secnd")
            XCTAssertGreaterThan(h.source.counters.reads, reads, "identity read again")
            await h.engine.stop()
        }
    }

    /// The same rewrite naming another session (same size, same inode):
    /// nothing from either version is written, and the verdict is mismatch.
    func testASameSizeRewriteToAnotherSessionWritesNothing() async throws {
        let h = try harness()
        let id = uuid(), other = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id, cwd: "/mine"))
        try join(h, id, path: claudePath(id))
        h.writes.failNext(1)
        await h.engine.start()
        try await waitUntil("first write failed") { h.writes.attempted.count == 1 }
        let listings = holdListings(h)
        h.source.write(claudePath(id), agent: .claude, data: claudeData(other, cwd: "/mine"), inPlace: true)
        try await briefly { h.recorder.latest?.facts[id] == nil }
        retryNow(h)
        listings.open()
        try await waitUntil("mismatch") { self.resolution(h, id) == .mismatch }
        try await settle()
        XCTAssertNil(try row(h, id)?.directory)
        XCTAssertTrue(h.writes.succeeded.isEmpty)
    }

    /// Truncated, then grown past its old size with new bytes (same inode):
    /// the old facts are never written, the new ones are.
    func testTruncateThenGrowRevokesFactsAndFillsFromTheNewBytes() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id, cwd: "/old", prompt: "Old"))
        try join(h, id, path: claudePath(id))
        h.writes.failNext(1)
        await h.engine.start()
        try await waitUntil("first write failed") { h.writes.attempted.count == 1 }
        let listings = holdListings(h)
        h.source.truncate(claudePath(id), to: 0)
        h.source.append(claudePath(id), claudeData(id, cwd: "/grown/much/longer", prompt: "Regrown"))
        try await briefly { h.recorder.latest?.facts[id] == nil }
        retryNow(h)
        XCTAssertNil(try row(h, id)?.directory, "the old bytes' facts were written")
        listings.open()
        try await waitUntil("filled") { try self.row(h, id)?.directory != nil }
        XCTAssertEqual(try row(h, id)?.directory, "/grown/much/longer")
        XCTAssertEqual(try row(h, id)?.title, "Regrown")
    }

    /// A newer revert appears after a failed write of the old rollout's
    /// facts; the retry comes due while the listing that would show the
    /// revert is held: the old rollout's folder and title are never
    /// persisted, and the revert's are.
    func testARevertAfterAFailedWriteNeverPersistsTheOldRollout() async throws {
        let h = try harness()
        let id = uuid()
        let old = codexPath(id), revert = codexPath(id, stamp: "2026-10-01T11-00-00")
        h.source.write(old, agent: .codex, data: codexData(id, cwd: "/old", prompt: "Old"))
        try join(h, id, agent: .codex, path: old)
        h.writes.failNext(1)
        await h.engine.start()
        try await waitUntil("first write failed") { h.writes.attempted.count == 1 }
        let listings = holdListings(h)
        h.source.write(revert, agent: .codex, data: codexData(id, cwd: "/new", prompt: "New"))
        try await briefly { h.recorder.latest?.facts[id] == nil }
        retryNow(h)
        XCTAssertNil(try row(h, id)?.directory, "the old rollout's folder was persisted")
        XCTAssertNil(try row(h, id)?.title)
        listings.open()
        try await waitUntil("filled") { try self.row(h, id)?.directory != nil }
        XCTAssertEqual(try row(h, id)?.directory, "/new")
        XCTAssertEqual(try row(h, id)?.title, "New")
        XCTAssertEqual(try row(h, id)?.transcriptPath, revert)
    }

    /// A listing that fails after the member left and rejoined (it was for
    /// the old membership) neither marks the new membership incomplete nor
    /// defers it; the new membership's own listing resolves it.
    func testAFailedListingForAnOldMembershipLeavesTheNewOneAlone() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        let gate = holdListings(h)
        await h.engine.start()
        try await waitUntil("listing held") { gate.arrivals == 1 }
        h.source.failNextLocates(1)
        XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
        try join(h, id, path: claudePath(id))
        let fresh = try XCTUnwrap(try row(h, id)?.incarnation)
        try await waitUntil("rejoin seen") { (await h.engine.operationRevision(id) ?? 0) > 0 }
        let mark = h.recorder.snapshots.count
        gate.open()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        XCTAssertFalse(h.recorder.snapshots[mark...].contains { $0.resolutions[id] == .incomplete },
                       "the old membership's failed listing marked the new one")
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        XCTAssertEqual(h.writes.succeeded.map(\.incarnation), [fresh])
    }

    /// `confirmAbsence` asked while an older listing is held: that listing's
    /// failure does not answer it; its own listing (complete, nothing
    /// there) does — true.
    func testAFailedOlderListingDoesNotAnswerANewerAbsenceCheck() async throws {
        let h = try harness()
        let id = uuid()
        try join(h, id)
        await h.engine.start()
        try await waitUntil("absent") { self.resolution(h, id) == .confirmedAbsent }
        let gate = holdListings(h)
        await h.engine.requestResolution(id)
        try await waitUntil("listing held") { gate.arrivals == 1 }
        h.source.failNextLocates(1)
        let answer = Task { await h.engine.confirmAbsence(id) }
        try await waitUntil("asked") { (await h.engine.operationRevision(id) ?? 0) >= 2 }
        gate.open()
        let absent = await answer.value
        XCTAssertTrue(absent, "the older listing's failure answered the newer check")
    }

    // MARK: Complete members: an append is a stat

    /// A complete member has no facts a stale read could persist: appends to
    /// the same file are stats — no read, no publication.
    func testAppendsToACompleteMemberAreStatsOnly() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        try complete(h, id)
        await h.engine.start()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        try await settle()
        let reads = h.source.counters.reads, publications = h.engine.metrics.publications
        let observed = h.engine.metrics.observations
        for n in 0..<100 { h.source.append(claudePath(id), Data("\n{\"n\":\(n)}".utf8)) }
        try await waitUntil("observed") { h.engine.metrics.observations >= observed + 1 }
        try await settle(300)
        XCTAssertEqual(h.source.counters.reads, reads, "no read")
        XCTAssertEqual(h.engine.metrics.publications, publications, "no publication")
        XCTAssertTrue(isLoaded(h, id))
    }

    /// A complete member re-verifies on anything but an append: a same-size
    /// rewrite (one identity read; another session's id is a mismatch), a
    /// growth on a host without file identities, a coverage reset.
    func testACompleteMemberReverifiesOnEverythingButAnAppend() async throws {
        func loadedComplete(hasInodes: Bool = true) async throws -> (Harness, String) {
            let h = try harness(hasInodes: hasInodes)
            let id = uuid()
            h.source.write(claudePath(id), agent: .claude, data: claudeData(id, cwd: "/aaaa"))
            try join(h, id, path: claudePath(id))
            try complete(h, id)
            await h.engine.start()
            try await waitUntil("loaded") { self.isLoaded(h, id) }
            try await settle()
            return (h, id)
        }
        do {   // same-size rewrite, same session
            let (h, id) = try await loadedComplete()
            let reads = h.source.counters.reads
            h.source.write(claudePath(id), agent: .claude, data: claudeData(id, cwd: "/bbbb"), inPlace: true)
            try await waitUntil("re-verified") { h.source.counters.reads == reads + 1 }
            try await settle()
            XCTAssertEqual(h.source.counters.reads, reads + 1)
            XCTAssertEqual(h.source.counters.parses, 0)
            XCTAssertTrue(isLoaded(h, id))
            await h.engine.stop()
        }
        do {   // same-size rewrite naming another session
            let (h, id) = try await loadedComplete()
            h.source.write(claudePath(id), agent: .claude, data: claudeData(uuid(), cwd: "/aaaa"), inPlace: true)
            try await waitUntil("mismatch") { self.resolution(h, id) == .mismatch }
            await h.engine.stop()
        }
        do {   // growth where the host has no file identities
            let (h, id) = try await loadedComplete(hasInodes: false)
            let reads = h.source.counters.reads
            h.source.append(claudePath(id), Data("\n{}".utf8))
            try await waitUntil("re-verified") { h.source.counters.reads == reads + 1 }
            await h.engine.stop()
        }
        do {   // coverage reset
            let (h, id) = try await loadedComplete()
            let reads = h.source.counters.reads
            h.source.dropEvents()
            try await waitUntil("re-verified") { h.source.counters.reads == reads + 1 }
            XCTAssertTrue(isLoaded(h, id))
            await h.engine.stop()
        }
    }

    /// A complete member whose row starts wanting a field again (cleared)
    /// is guarded from then on: it is read with facts and filled, and its
    /// next append revokes and reads again.
    func testACompleteMemberThatStartsWantingAFieldIsGuarded() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id, prompt: "From the transcript"))
        try join(h, id, path: claudePath(id))
        try complete(h, id)
        await h.engine.start()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        try await settle()
        h.source.append(claudePath(id), Data("\n{}".utf8))
        try await settle()
        let reads = h.source.counters.reads
        try h.db.setTitle(nil, sessionID: id, host: h.source.host)
        try await waitUntil("filled again") { try self.row(h, id)?.title == "From the transcript" }
        XCTAssertGreaterThan(h.source.counters.reads, reads)
        XCTAssertEqual(h.source.counters.parses, 1)
    }

    /// 16. Round trips: one listing for a batch, one read per member that
    /// needs one, a stat for a write to a complete member, and nothing for
    /// a write to a non-member.
    func testRoundTripsMatchThePlan() async throws {
        // Hinted, complete members: one locate + N identity reads, no parse.
        do {
            let h = try harness()
            let ids = (0..<5).map { _ in uuid() }
            for id in ids {
                h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
                try join(h, id, path: claudePath(id))
                try complete(h, id)
            }
            await h.engine.start()
            try await waitUntil("loaded") { ids.allSatisfy { self.isLoaded(h, $0) } }
            try await settle()
            XCTAssertEqual(h.source.counters.locates, 1)
            XCTAssertEqual(h.source.counters.reads, 5)
            XCTAssertEqual(h.source.counters.parses, 0)
            // An append to a complete member: one locate (the stat), no read.
            h.source.append(claudePath(ids[0]), Data("\n{}".utf8))
            try await waitUntil("relocated") { h.source.counters.locates == 2 }
            try await settle()
            XCTAssertEqual(h.source.counters.reads, 5)
            XCTAssertEqual(h.source.counters.parses, 0)
            // A write to a non-member: nothing.
            let outside = uuid()
            h.source.write(claudePath(outside), agent: .claude, data: claudeData(outside))
            try await settle()
            XCTAssertEqual(h.source.counters.locates, 2)
            XCTAssertEqual(h.source.counters.reads, 5)
            await h.engine.stop()
        }
        // Members with NULL fields: one locate + N reads with facts.
        do {
            let h = try harness()
            let ids = (0..<5).map { _ in uuid() }
            for id in ids {
                h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
                try join(h, id, path: claudePath(id))
            }
            h.trace.reset()
            await h.engine.start()
            try await waitUntil("filled") { try ids.allSatisfy { try self.row(h, $0)?.title != nil } }
            try await settle()
            XCTAssertEqual(h.source.counters.locates, 1)
            XCTAssertEqual(h.source.counters.reads, 5)
            XCTAssertEqual(h.source.counters.parses, 5)
            XCTAssertEqual(h.trace.sessionRowUpdates, 5)
            // The fills' own row callbacks find nothing new: no locate.
            XCTAssertEqual(h.source.counters.locates, 1)
            await h.engine.stop()
        }
    }

    // MARK: E1 — every invalidation revokes retained facts

    private enum Invalidation: CaseIterable {
        case coverageReset, coverageFromLocate, reconnect, stopStart, sharedFacts, explicitRefresh, candidateReplacement, rejoin
    }

    /// Each invalidation, after a failed fill: the failed facts are never
    /// written (their retry finds them revoked), and the re-read's facts are
    /// written exactly once.
    func testEveryInvalidationRevokesAFailedFillAndTheReReadFillsOnce() async throws {
        for kind in Invalidation.allCases {
            let h = try harness()
            let id = uuid()
            let codex = kind == .sharedFacts || kind == .candidateReplacement
            let path = codex ? codexPath(id) : claudePath(id)
            if codex {
                h.source.setShared(.codex, CodexFormat.historyInput, Data())
                h.source.write(path, agent: .codex, data: codexData(id, cwd: "/before", prompt: kind == .sharedFacts ? nil : "Before"))
            } else {
                h.source.write(path, agent: .claude, data: claudeData(id, cwd: "/before", prompt: "Before"))
            }
            try join(h, id, agent: codex ? .codex : .claude, path: path)
            h.writes.failNext(1)
            await h.engine.start()
            try await waitUntil("\(kind): first attempt failed") { h.writes.attempted.count == 1 }
            let stale = h.writes.attempted[0].authorization
            XCTAssertNil(try row(h, id)?.directory)
            let listings = holdListings(h)
            switch kind {
            case .coverageReset:
                h.source.dropEvents()
            case .coverageFromLocate:
                // Coverage moves on unannounced; the next listing (caused by
                // a write) is how the engine learns of it.
                h.source.dropEvents(announce: false)
                h.source.append(path, Data("\n{}".utf8))
            case .reconnect:
                h.source.endChanges()
            case .stopStart:
                await h.engine.stop()
                await h.engine.start()
            case .sharedFacts:
                h.source.setShared(.codex, CodexFormat.historyInput, history(id, "After"))
            case .explicitRefresh:
                await h.engine.requestResolution(id)
            case .candidateReplacement:
                h.source.write(codexPath(id, stamp: "2026-10-01T12-00-00"), agent: .codex, data: codexData(id, cwd: "/after", prompt: "After"))
            case .rejoin:
                XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
                try join(h, id, path: path)
            }
            // The revocation is published by the invalidation itself, not by
            // the (held) listing that follows it. The failed write's retry
            // comes due while that listing is still held: nothing is written.
            try await briefly { h.recorder.latest?.facts[id] == nil }
            retryNow(h)
            XCTAssertNil(try row(h, id)?.directory, "\(kind): stale facts written while the listing was held")
            XCTAssertNil(try row(h, id)?.title, "\(kind)")
            listings.open()
            try await waitUntil("\(kind): filled") { try self.row(h, id)?.directory != nil }
            try await settle()
            XCTAssertFalse(h.writes.succeeded.contains { $0.authorization == stale }, "\(kind): stale facts written")
            XCTAssertEqual(h.writes.succeeded.count, 1, "\(kind)")
            XCTAssertEqual(h.writes.attempted.filter { $0.authorization == stale }.count, 1, "\(kind)")
            if kind == .candidateReplacement { XCTAssertEqual(try row(h, id)?.directory, "/after") }
            if kind == .sharedFacts { XCTAssertEqual(try row(h, id)?.title, "After") }
            await h.engine.stop()
        }
    }

    /// A facts read that fails on transport after the listing worked: the
    /// verdict stands, and the retry still reads the facts — the row fills.
    func testATransportFailureDuringAFactsReadStillFillsTheRow() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id, prompt: "After the outage"))
        try join(h, id, path: claudePath(id))
        h.source.failNextReads(1, with: .transport("link down"))
        await h.engine.start()
        try await waitUntil("filled") { try self.row(h, id)?.title != nil }
        XCTAssertEqual(try row(h, id)?.title, "After the outage")
        XCTAssertGreaterThan(h.engine.metrics.retries, 0)
        XCTAssertEqual(h.source.counters.reads, 2)
    }

    /// Stopping revokes: the last publication carries no facts, so a write
    /// still waiting to be retried is never applied from a stopped run.
    func testStopPublishesARevocationForEveryFact() async throws {
        let h = try harness()
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        h.writes.failNext(1)
        await h.engine.start()
        try await waitUntil("first attempt failed") { h.writes.attempted.count == 1 }
        await h.engine.stop()
        try await waitUntil("revoked") { h.committer.pendingIDs.isEmpty }
        h.clock.advance(5)
        h.committer.retryDue()
        XCTAssertTrue(h.writes.succeeded.isEmpty)
        XCTAssertEqual(h.recorder.latest?.facts, [:])
        XCTAssertNil(h.engine.latestSnapshot)
    }

    /// A stream registered while snapshots are being published never sees
    /// an older one after a newer one.
    func testSnapshotStreamsDeliverInPublicationOrder() async throws {
        let mirror = EngineMirror()
        let publisher = Task.detached {
            for generation in 1...400 { mirror.publish(EngineSnapshot(generation: UInt64(generation), resolutions: [:])) }
        }
        var streams: [AsyncStream<EngineSnapshot>] = []
        for _ in 0..<40 { streams.append(mirror.stream()); await Task.yield() }
        await publisher.value
        mirror.finish()
        for stream in streams {
            var last: UInt64 = 0
            for await snapshot in stream {
                XCTAssertGreaterThanOrEqual(snapshot.generation, last)
                last = snapshot.generation
            }
            XCTAssertEqual(last, 400, "the newest is never overwritten by a replay")
        }
    }

    /// The writable CLI's loop (`FactCommitter.consume`), over a live engine:
    /// a failed write is retried by the loop and lands; nothing is written
    /// from facts the engine has since revoked.
    func testTheWritableCLILoopRetriesAndRevokes() async throws {
        let source = FakeHostSource(host: Self.remote)
        let (db, trace) = try SQLTrace.database()
        let clock = Clock()
        let engine = SessionEngine(source: source, database: db, now: { clock.now })
        engines.append(engine)
        let writes = Writes(db)
        let committer = FactCommitter(persist: { try writes.persist($0, $1) }, now: { clock.now })
        let id = uuid()
        source.write(claudePath(id), agent: .claude, data: claudeData(id, prompt: "Through the CLI"))
        try db.join(sessionID: id, via: .imported, agent: .claude,
                    locator: TranscriptLocator(host: Self.remote, path: claudePath(id)), core: SessionCore(host: Self.remote))
        writes.failNext(1)
        trace.reset()
        let stream = engine.snapshots()
        let loop = Task { await committer.consume(stream, retryEvery: .milliseconds(20), onSnapshot: { _ in }) }
        tasks.append(loop)
        await engine.start()
        try await waitUntil("first attempt failed") { writes.attempted.count == 1 }
        XCTAssertEqual(trace.sessionRowUpdates, 0)
        clock.advance(2)
        try await waitUntil("retried by the loop") { try db.sessionState(id)?.title != nil }
        XCTAssertEqual(try db.sessionState(id)?.title, "Through the CLI")
        XCTAssertEqual(trace.sessionRowUpdates, 1)
        XCTAssertEqual(writes.attempted.count, 2)

        // A second member's write fails; the engine revokes those facts (an
        // explicit refresh) before the retry comes due: the loop never
        // writes them, and writes the re-read's facts once.
        let other = uuid()
        source.write(claudePath(other), agent: .claude, data: claudeData(other, prompt: "Second"))
        writes.failNext(1)
        try db.join(sessionID: other, via: .imported, agent: .claude,
                    locator: TranscriptLocator(host: Self.remote, path: claudePath(other)), core: SessionCore(host: Self.remote))
        try await waitUntil("second member's write failed") { writes.attempted.contains { $0.summary?.id == other } }
        let stale = try XCTUnwrap(writes.attempted.last { $0.summary?.id == other }).authorization
        await engine.requestResolution(other)
        try await waitUntil("the loop saw the revocation") { committer.pendingIDs.isEmpty }
        clock.advance(10)
        try await waitUntil("filled from the re-read") { try db.sessionState(other)?.title != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(writes.succeeded.contains { $0.authorization == stale }, "revoked facts never written")
        XCTAssertEqual(writes.succeeded.filter { $0.summary?.id == other }.count, 1)
    }

    /// The hint lands and then the fill's transaction fails: the retry
    /// completes the fill, and the hint is not written twice.
    func testAFailureBetweenTheHintAndTheFillIsCompletedByTheRetry() throws {
        let (db, trace) = try SQLTrace.database()
        let id = uuid()
        let locator = TranscriptLocator(host: .local, path: "/tmp/\(id).jsonl")
        try db.join(sessionID: id, via: .imported)
        let incarnation = try XCTUnwrap(try db.sessionState(id)?.incarnation)
        let clock = Clock()
        var failFill = true
        let persister = FactPersister(database: db)
        let committer = FactCommitter(persist: { id, facts in
            if failFill {
                failFill = false
                _ = try db.updateTranscriptHint(sessionID: id, incarnation: facts.incarnation, agent: facts.agent, locator: facts.locator)
                throw CocoaError(.fileWriteUnknown)
            }
            return try persister.persist(id, facts)
        }, now: { clock.now })
        let facts = AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 1, incarnation: incarnation),
            locator: locator, agent: .claude, signature: TranscriptSignature(modifiedAt: clock.now, size: 1, identity: 1),
            coverage: 1, sharedRevision: nil,
            summary: TranscriptSummary(id: id, agent: .claude, locator: locator, modifiedAt: clock.now, cwd: "/w", firstPrompt: "Half"))
        trace.reset()
        committer.receive([id: facts])
        XCTAssertEqual(trace.sessionRowUpdates, 1, "the hint")
        XCTAssertEqual(try db.sessionState(id)?.transcriptPath, locator.path)
        XCTAssertNil(try db.sessionState(id)?.title)
        clock.advance(2)
        committer.retryDue()
        XCTAssertEqual(trace.sessionRowUpdates, 2, "the fill, and no second hint")
        XCTAssertEqual(try db.sessionState(id)?.title, "Half")
    }

    // MARK: Authorization edges

    /// Title-only enrichment while the member stays loaded: new shared facts
    /// give an otherwise complete row its title in exactly one write.
    func testTitleOnlyEnrichmentWhileLoadedWritesOnce() async throws {
        let h = try harness()
        let id = uuid()
        h.source.setShared(.codex, CodexFormat.historyInput, Data())
        h.source.write(codexPath(id), agent: .codex, data: codexData(id, cwd: "/work"))
        try join(h, id, agent: .codex, path: codexPath(id),
                 core: SessionCore(host: h.source.host, directory: "/work", directorySource: .tab,
                                   lastActiveAt: Date(timeIntervalSince1970: 5)))
        await h.engine.start()
        try await waitUntil("loaded") { self.isLoaded(h, id) }
        try await settle()
        XCTAssertNil(try row(h, id)?.title)
        h.trace.reset()
        h.source.setShared(.codex, CodexFormat.historyInput, history(id, "From history"))
        try await waitUntil("titled") { try self.row(h, id)?.title != nil }
        try await settle()
        XCTAssertEqual(try row(h, id)?.title, "From history")
        XCTAssertEqual(h.trace.sessionRowUpdates, 1)
        let firstLoaded = try XCTUnwrap(h.recorder.snapshots.firstIndex { if case .loaded? = $0.resolutions[id] { return true }; return false })
        XCTAssertTrue(h.recorder.snapshots[firstLoaded...].allSatisfy { if case .loaded? = $0.resolutions[id] { return true }; return false })
    }

    /// Both database callbacks (leave, then join) delivered only after the
    /// rejoin committed — in either order: the member follows the new
    /// membership, and the old read's facts are never written.
    func testBothObserverDeliveriesDelayedUntilAfterRejoin() async throws {
        for reversed in [false, true] {
            let h = try harness()
            let id = uuid()
            h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
            try join(h, id, path: claudePath(id))
            let stale = try XCTUnwrap(try row(h, id)?.incarnation)
            let gate = try await holdNextRead(h)
            h.engine.holdDatabaseCallbacks()
            XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
            try join(h, id, path: claudePath(id))
            let fresh = try XCTUnwrap(try row(h, id)?.incarnation)
            XCTAssertNotEqual(stale, fresh)
            h.engine.releaseDatabaseCallbacks(reversed: reversed)
            try await waitUntil("followed the rejoin") { (await h.engine.operationRevision(id) ?? 0) > 0 }
            h.trace.reset()
            gate.open()
            try await waitUntil("filled") { try self.row(h, id)?.title != nil }
            try await settle()
            XCTAssertEqual(h.writes.succeeded.map(\.incarnation), [fresh], "reversed: \(reversed)")
            XCTAssertEqual(h.trace.sessionRowUpdates, 1)
            await h.engine.stop()
        }
    }

    /// A rejoin between the engine's publication and the consumer's write:
    /// the facts name the old membership, and the database refuses them.
    func testARejoinBetweenPublishAndWriteIsRefusedInSQL() async throws {
        let h = try harness(consume: false)
        let id = uuid()
        h.source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try join(h, id, path: claudePath(id))
        await h.engine.start()
        try await waitUntil("facts published") { h.engine.latestSnapshot?.facts[id] != nil }
        let published = try XCTUnwrap(h.engine.latestSnapshot)
        XCTAssertTrue(try h.db.leave(sessionID: id, host: h.source.host))
        try join(h, id, path: claudePath(id))
        h.trace.reset()
        let outcomes = h.committer.receive(published.facts)
        guard case .written(_, .ownershipMismatch)? = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(h.trace.sessionRowUpdates, 0)
        XCTAssertNil(try row(h, id)?.title)
    }

    /// Facts read against older shared bytes than the engine has seen carry
    /// no title at all; one title-only read follows and fills it.
    func testStaleSharedRevisionStripsTitlesAndRereadsOnce() async throws {
        let fake = FakeHostSource(host: Self.remote)
        let source = StaleSharedOnce(fake)
        let (db, trace) = try SQLTrace.database()
        let engine = SessionEngine(source: source, database: db)
        engines.append(engine)
        let committer = FactCommitter(database: db)
        let stream = engine.snapshots()
        tasks.append(Task { for await snapshot in stream { committer.receive(snapshot.facts) } })
        let id = uuid()
        fake.setShared(.codex, CodexFormat.historyInput, history(id, "Shared"))
        fake.write(codexPath(id), agent: .codex, data: codexData(id, cwd: "/work"))
        try db.join(sessionID: id, via: .imported, agent: .codex,
                    locator: TranscriptLocator(host: Self.remote, path: codexPath(id)), core: SessionCore(host: Self.remote))
        trace.reset()
        await engine.start()
        try await waitUntil("titled") { try db.sessionState(id)?.title != nil }
        try await settle()
        XCTAssertEqual(try db.sessionState(id)?.title, "Shared")
        XCTAssertEqual(try db.sessionState(id)?.directory, "/work")
        XCTAssertEqual(fake.counters.reads, 2)
        XCTAssertEqual(trace.sessionRowUpdates, 2, "the titleless facts, then the title")
    }

    /// The consumer half used by writable templectl: a failed write is
    /// retried only while the latest snapshot still authorizes it; a
    /// snapshot without it revokes it; new facts are written once.
    func testTheWritableCLIsCommitterRetriesOnlyCurrentFacts() throws {
        let (db, trace) = try SQLTrace.database()
        let id = uuid()
        let locator = TranscriptLocator(host: .local, path: "/tmp/\(id).jsonl")
        try db.join(sessionID: id, via: .imported, agent: .claude, locator: locator)
        let incarnation = try XCTUnwrap(try db.sessionState(id)?.incarnation)
        let clock = Clock()
        var failures = 1
        let persister = FactPersister(database: db)
        let committer = FactCommitter(persist: { id, facts in
            if failures > 0 { failures -= 1; throw CocoaError(.fileWriteUnknown) }
            return try persister.persist(id, facts)
        }, now: { clock.now })
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        func facts(_ revision: UInt64, title: String) -> AuthorizedFacts {
            AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: revision, incarnation: incarnation),
                locator: locator, agent: .claude, signature: TranscriptSignature(modifiedAt: when, size: 1, identity: 1),
                coverage: 1, sharedRevision: nil,
                summary: TranscriptSummary(id: id, agent: .claude, locator: locator, modifiedAt: when, cwd: "/w", firstPrompt: title))
        }
        trace.reset()
        let first = committer.receive([id: facts(1, title: "Stale")])
        guard case .failed? = first.first else { return XCTFail() }
        XCTAssertEqual(committer.pendingIDs, [id])
        // Revoked: a snapshot without the id.
        committer.receive([:])
        clock.advance(10)
        XCTAssertTrue(committer.retryDue().isEmpty)
        XCTAssertEqual(trace.sessionRowUpdates, 0)
        // Newly authorized facts: written once, not again on a re-delivery.
        committer.receive([id: facts(2, title: "Fresh")])
        committer.receive([id: facts(2, title: "Fresh")])
        XCTAssertEqual(trace.sessionRowUpdates, 1)
        XCTAssertEqual(try db.sessionState(id)?.title, "Fresh")
        // A failed write retried while still current.
        let other = uuid()
        try db.join(sessionID: other, via: .imported, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/\(other).jsonl"))
        failures = 1
        let otherIncarnation = try XCTUnwrap(try db.sessionState(other)?.incarnation)
        let otherLocator = TranscriptLocator(host: .local, path: "/tmp/\(other).jsonl")
        let otherFacts = AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 1, incarnation: otherIncarnation),
            locator: otherLocator, agent: .claude, signature: TranscriptSignature(modifiedAt: Date(), size: 1, identity: 1),
            coverage: 1, sharedRevision: nil,
            summary: TranscriptSummary(id: other, agent: .claude, locator: otherLocator, modifiedAt: Date(), cwd: "/o"))
        committer.receive([id: facts(2, title: "Fresh"), other: otherFacts])
        XCTAssertEqual(committer.pendingIDs, [other])
        clock.advance(2)
        committer.retryDue()
        XCTAssertEqual(try db.sessionState(other)?.directory, "/o")
        XCTAssertTrue(committer.pendingIDs.isEmpty)
    }

    // MARK: Ownership

    /// Nothing the engine spawns keeps it alive: stopped and released with a
    /// snapshot stream still open, it deallocates and the stream ends.
    func testEngineDeallocatesAfterStopWithAnOpenSnapshotStream() async throws {
        let source = FakeHostSource(host: Self.remote)
        let db = try TempleDB.inMemory()
        let id = uuid()
        source.write(claudePath(id), agent: .claude, data: claudeData(id))
        try db.join(sessionID: id, via: .imported, agent: .claude,
                    locator: TranscriptLocator(host: Self.remote, path: claudePath(id)), core: SessionCore(host: Self.remote))
        weak var weakEngine: SessionEngine?
        let ended = Flag()
        var consumer: Task<Void, Never>?
        do {
            let engine = SessionEngine(source: source, database: db)
            weakEngine = engine
            let stream = engine.snapshots()
            consumer = Task { for await _ in stream {}; ended.set() }
            // A read held forever: a task stuck in it must not hold the engine.
            let gate = FakeGate()
            source.readGate = gate
            await engine.start()
            try await waitUntil("read in flight") { gate.arrivals >= 1 }
            await engine.stop()
        }
        try await waitUntil("deallocated") { weakEngine == nil }
        try await waitUntil("stream ended") { ended.isSet }
        consumer?.cancel()
        XCTAssertEqual(source.subscribers, 0, "observation released")
    }
}

/// A source whose first facts read reports shared bytes one revision older
/// than the engine has seen (the race C5 closes).
final class StaleSharedOnce: HostSessionSource, @unchecked Sendable {
    let inner: FakeHostSource
    private let lock = NSLock()
    private var done = false
    init(_ inner: FakeHostSource) { self.inner = inner }
    var host: HostID { inner.host }
    var capabilities: Set<HostCapability> { inner.capabilities }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> { inner.catalog(query) }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { try await inner.adopt(request) }
    func changes() -> AsyncThrowingStream<SourceChange, Error> { inner.changes() }
    func locate(_ requests: [LocateRequest]) async throws -> LocateResult { try await inner.locate(requests) }
    func directoryEvidence(_ path: String) async -> DirectoryEvidence { await inner.directoryEvidence(path) }
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        let read = try await inner.read(locator, agent: agent, expecting: id, facts: facts)
        lock.lock(); let first = facts && !done; if first { done = true }; lock.unlock()
        guard first, let revision = read.sharedRevision, revision > 0 else { return read }
        return TranscriptRead(identity: read.identity, summary: read.summary, signature: read.signature,
                              bytesRead: read.bytesRead, sharedRevision: revision - 1)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    /// True the first time only.
    func setOnce() -> Bool { lock.lock(); defer { lock.unlock() }; let first = !value; value = true; return first }
}

/// The committer must never hold its lock across a write: the write's
/// committed observers run synchronously and can call straight back in.
final class FactCommitterReentrancyTests: XCTestCase {
    func testAWriteWhoseObserversCallBackIntoTheCommitterDoesNotDeadlock() throws {
        let (db, _) = try SQLTrace.database()
        for id in ["first", "second"] { try db.join(sessionID: id, via: .imported) }
        func facts(_ id: String) throws -> AuthorizedFacts {
            let locator = TranscriptLocator(host: .local, path: "/tmp/\(id).jsonl")
            return AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 1, incarnation: try XCTUnwrap(try db.sessionState(id)?.incarnation)),
                locator: locator, agent: .claude, signature: TranscriptSignature(modifiedAt: Date(timeIntervalSince1970: 1), size: 1, identity: 1),
                coverage: 1, sharedRevision: nil,
                summary: TranscriptSummary(id: id, agent: .claude, locator: locator, modifiedAt: Date(timeIntervalSince1970: 1), cwd: "/\(id)"))
        }
        let first = try facts("first"), second = try facts("second")
        let persister = FactPersister(database: db)
        final class Box: @unchecked Sendable { var committer: FactCommitter?; var reentered = false }
        let box = Box()
        // Stands in for the app's chain: a committed row change refreshes the
        // row, which re-merges ownership, which delivers a newer snapshot.
        let observer = db.observeRowChanges { id in
            guard id == "first", !box.reentered else { return }
            box.reentered = true
            box.committer?.receive(["first": first, "second": second])
        }
        defer { db.removeRowChangeObserver(observer) }
        box.committer = FactCommitter(persist: { try persister.persist($0, $1) })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.committer?.receive(["first": first])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "deadlocked: the lock was held across the write")
        XCTAssertTrue(box.reentered)
        XCTAssertEqual(try db.sessionState("first")?.directory, "/first")
        XCTAssertEqual(try db.sessionState("second")?.directory, "/second")
    }
}
