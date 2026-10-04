import XCTest
@testable import TempleCore
import TempleTestSupport

final class HostSessionSourceTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testNewCoverageInvalidatesOtherMembersInEitherDeliveryOrder() async throws {
        for batchFirst in [false, true] {
            let source = ResolvingFakeSource(host: .local)
            let engine = SessionEngine(source: source, members: ["a", "b"])
            let stream = engine.start()
            defer { engine.stop(); withExtendedLifetime(stream) {} }
            try await wait { engine.resolution(for: "b") == .confirmedAbsent }
            source.gateNext()
            engine.requestResolution("a")
            try await wait { source.hasPending }
            if !batchFirst {
                source.send(.coverageReset(coverage: 2))
                try await wait { engine.publishedSnapshot?.generation == 2 }
            }
            source.gateNext()
            source.resumePending(ResolutionBatch(generation: 2, results: ["a": .absent]))
            try await wait { source.hasPending && engine.publishedSnapshot?.generation == 2 }
            XCTAssertEqual(engine.resolution(for: "b"), .resolving)
            if batchFirst { source.send(.coverageReset(coverage: 2)) }
            source.resumePending(ResolutionBatch(generation: 2, results: ["a": .absent, "b": .unreadable]))
            try await wait { engine.resolution(for: "b") == .unreadable }
            XCTAssertEqual(engine.publishedSnapshot?.generation, 2)
        }
    }

    func testQueuedResolveCannotRegisterALeftMember() async throws {
        let source = ResolvingFakeSource(host: .local)
        let engine = SessionEngine(source: source, members: ["a", "b"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.resolution(for: "b") == .confirmedAbsent }
        source.gateNext()
        engine.requestResolution("a")
        try await wait { source.hasPending }
        engine.requestResolution("b")
        engine.forgetMember("b")
        try await wait { engine.resolution(for: "b") == nil }
        source.resumePending(ResolutionBatch(generation: 1, results: ["a": .absent]))
        engine.requestResolution("a")
        try await wait { source.callCount >= 3 }
        XCTAssertEqual(source.callCount, 3)
        XCTAssertEqual(source.registeredIDs, ["a"])
    }

    func testInFlightRegistrationIsReleasedAfterLeave() async throws {
        let source = ResolvingFakeSource(host: .local)
        let engine = SessionEngine(source: source, members: ["a", "b"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.resolution(for: "b") == .confirmedAbsent }
        source.gateNext()
        engine.requestResolution("a")
        try await wait { source.hasPending }
        engine.forgetMember("a")
        try await wait { engine.resolution(for: "a") == nil }
        // This fake registers again at completion, after leave's first release.
        source.resumePending(ResolutionBatch(generation: 1, results: ["a": .absent]))
        engine.requestResolution("b")
        try await wait { source.callCount >= 3 }
        XCTAssertEqual(source.registeredIDs, ["b"])
    }

    func testTransportFailureNeverProvesAbsence() async throws {
        let source = ResolvingFakeSource(host: .local)
        source.fail = true
        let engine = SessionEngine(source: source, members: ["member"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.publishedSnapshot != nil }
        XCTAssertEqual(engine.resolution(for: "member"), .incomplete)
        XCTAssertNil(engine.publishedSnapshot?.summaries["member"])
        source.fail = false
        engine.requestResolution("member")
        try await wait { engine.resolution(for: "member") == .confirmedAbsent }
    }

    func testEngineResolvesOnlyItsHostsRows() async throws {
        let db = try TempleDB.inMemory()
        let remote = HostID(rawValue: "fake")
        try db.join(sessionID: "local", via: .imported, core: SessionCore(host: .local))
        try db.join(sessionID: "remote", via: .imported, core: SessionCore(host: remote))
        let source = ResolvingFakeSource(host: remote)
        let engine = SessionEngine(source: source, database: db)
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.resolution(for: "remote") != nil }
        XCTAssertNil(engine.resolution(for: "local"))
        XCTAssertEqual(source.requestedIDs, ["remote"])
        try db.join(sessionID: "next-local", via: .created, core: SessionCore(host: .local))
        try db.join(sessionID: "next-remote", via: .imported, core: SessionCore(host: remote))
        try await wait { engine.resolution(for: "next-remote") != nil }
        XCTAssertEqual(source.requestedIDs, ["remote", "next-remote"])
        _ = try db.leave(sessionID: "next-remote", host: remote)
        try await wait { engine.resolution(for: "next-remote") == nil }
        XCTAssertEqual(source.releasedIDs, ["next-remote"])
    }

    func testAStaleGenerationBatchIsDropped() async throws {
        let source = ResolvingFakeSource(host: .local)
        let engine = SessionEngine(source: source, members: ["member"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.publishedSnapshot?.generation == 1 }
        source.gateNext()
        engine.requestResolution("member")
        try await wait { source.hasPending }
        source.send(.coverageReset(coverage: 2))
        try await wait { engine.publishedSnapshot?.generation == 2 }
        // A reply from the old coverage cannot replace the member's verdict.
        source.resumePending(ResolutionBatch(generation: 1, results: ["member": .mismatch]))
        try await wait { engine.resolution(for: "member") == .confirmedAbsent }
        XCTAssertEqual(engine.publishedSnapshot?.generation, 2)
    }
}

extension HostSessionSourceTests {
    /// Shared session titles can complete only a Codex member still missing
    /// one; re-resolving every member on every Codex prompt bought nothing.
    func testSharedTitleChangesReResolveOnlyUntitledCodexMembers() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "codex-untitled", via: .imported, agent: .codex)
        try db.join(sessionID: "codex-titled", via: .imported, agent: .codex, core: SessionCore(title: "Named"))
        try db.join(sessionID: "claude-untitled", via: .imported, agent: .claude)
        let source = ResolvingFakeSource(host: .local)
        let engine = SessionEngine(source: source, database: db)
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.resolution(for: "codex-titled") == .confirmedAbsent }
        let calls = source.callCount
        source.send(.sharedFacts(.codex, revision: 1))
        try await wait { source.callCount > calls }
        XCTAssertEqual(source.lastBatch, ["codex-untitled"])
    }

    /// The primitive change stream reaches the current engine too: a raw
    /// observation of a member's file resolves that member again, and only it.
    func testRawTranscriptEventsResolveOnlyTheMembersTheyName() async throws {
        let source = ResolvingFakeSource(host: .local)
        let engine = SessionEngine(source: source, members: ["member", "other"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.resolution(for: "other") == .confirmedAbsent }
        let calls = source.callCount
        source.send(.transcripts(ids: ["member", "stranger"],
                                 locators: [TranscriptLocator(host: .local, path: "/x/member.jsonl"), TranscriptLocator(host: .local, path: "/x/stranger.jsonl")]))
        try await wait { source.callCount > calls }
        XCTAssertEqual(source.lastBatch, ["member"])
    }

    /// A source that has not adopted the primitives says so, typed — never a crash.
    func testUnadoptedPrimitivesThrowATypedUnsupportedError() async throws {
        let source = ResolvingFakeSource(host: .local)
        do {
            _ = try await source.locate([LocateRequest(id: "x")])
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? HostSourceError, .unsupported("locate"))
        }
        do {
            _ = try await source.read(TranscriptLocator(host: .local, path: "/x"), agent: .claude, expecting: "x", facts: false)
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? HostSourceError, .unsupported("read"))
        }
        let evidence: DirectoryEvidence = await source.directoryEvidence("/anywhere")
        XCTAssertEqual(evidence, .unknown)
    }

    /// The traced database the cutover's no-stale-write tests count on.
    func testATracedDatabaseCountsSessionRowWrites() throws {
        let (db, trace) = try SQLTrace.database()
        try db.join(sessionID: "s", via: .imported)
        trace.reset()
        XCTAssertEqual(try db.fillCoreFields(sessionID: "s", host: .local, title: "T"), .changed([.title]))
        XCTAssertEqual(trace.sessionRowUpdates, 1)
        XCTAssertEqual(try db.fillCoreFields(sessionID: "s", host: .local, title: "Other"), .unchanged)
        XCTAssertEqual(trace.sessionRowUpdates, 1, "a NULL-only no-op writes nothing")
    }
}

/// No local paths, stores or parser dependency: usable by engine and UI seam tests.
final class ResolvingFakeSource: HostSessionSource, @unchecked Sendable {
    let host: HostID
    let capabilities: Set<HostCapability> = [.liveChanges, .catalog]
    private let lock = NSLock()
    var fail = false
    private var generation: UInt64 = 1
    private var ids: Set<String> = []
    private var released: Set<String> = []
    private var registered: Set<String> = []
    private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private var batches: [[String]] = []
    var lastBatch: [String] { lock.lock(); defer { lock.unlock() }; return batches.last ?? [] }
    var registeredIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return registered }
    private var gated = false
    private var pending: CheckedContinuation<ResolutionBatch, Error>?
    private var continuation: AsyncThrowingStream<SourceChange, Error>.Continuation?
    init(host: HostID) { self.host = host }
    var requestedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
    var releasedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return released }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    func gateNext() { lock.lock(); gated = true; lock.unlock() }
    func resumePending(_ batch: ResolutionBatch) {
        lock.lock(); let waiting = pending; pending = nil
        generation = max(generation, batch.generation); registered.formUnion(batch.results.keys)
        lock.unlock(); waiting?.resume(returning: batch)
    }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch {
        try await withCheckedThrowingContinuation { waiting in
            lock.lock(); calls += 1; ids.formUnion(requests.map(\.id)); registered.formUnion(requests.map(\.id))
            batches.append(requests.map(\.id).sorted())
            if gated { gated = false; pending = waiting; lock.unlock(); return }
            let batch = ResolutionBatch(generation: generation,
                results: Dictionary(uniqueKeysWithValues: requests.map { ($0.id, ResolutionResult.absent) }))
            let failed = fail; lock.unlock()
            if failed { waiting.resume(throwing: CocoaError(.fileReadUnknown)) }
            else { waiting.resume(returning: batch) }
        }
    }
    func release(_ ids: [String]) { lock.lock(); released.formUnion(ids); registered.subtract(ids); lock.unlock() }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> { AsyncThrowingStream { $0.finish() } }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .none }
    func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { lock.lock(); continuation = $0; lock.unlock() }
    }
    func send(_ change: SourceChange) {
        lock.lock(); if case .coverageReset(coverage: let value) = change { generation = value }
        let target = continuation; lock.unlock(); target?.yield(change)
    }
}
