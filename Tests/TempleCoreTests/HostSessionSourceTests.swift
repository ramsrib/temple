import XCTest
@testable import TempleCore

final class HostSessionSourceTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testTransportFailureNeverProvesAbsence() async throws {
        let source = FakeHostSource(host: .local)
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
        let source = FakeHostSource(host: remote)
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
        _ = try db.leave(sessionID: "next-remote")
        try await wait { engine.resolution(for: "next-remote") == nil }
        XCTAssertEqual(source.releasedIDs, ["next-remote"])
    }

    func testAStaleGenerationBatchIsDropped() async throws {
        let source = FakeHostSource(host: .local)
        let engine = SessionEngine(source: source, members: ["member"])
        let stream = engine.start()
        defer { engine.stop(); withExtendedLifetime(stream) {} }
        try await wait { engine.publishedSnapshot?.generation == 1 }
        source.gateNext()
        engine.requestResolution("member")
        try await wait { source.hasPending }
        source.send(.coverageReset(2))
        // A reply from the old coverage cannot replace the member's verdict.
        source.resumePending(ResolutionBatch(generation: 1, results: ["member": .mismatch]))
        try await wait { engine.publishedSnapshot?.generation == 2 }
        XCTAssertEqual(engine.resolution(for: "member"), .confirmedAbsent)
    }
}

/// No local paths, stores or parser dependency: usable by engine and UI seam tests.
final class FakeHostSource: HostSessionSource, @unchecked Sendable {
    let host: HostID
    let capabilities: Set<HostCapability> = [.liveChanges, .catalog]
    private let lock = NSLock()
    var fail = false
    private var generation: UInt64 = 1
    private var ids: Set<String> = []
    private var released: Set<String> = []
    private var gated = false
    private var pending: CheckedContinuation<ResolutionBatch, Error>?
    private var continuation: AsyncThrowingStream<SourceChange, Error>.Continuation?
    init(host: HostID) { self.host = host }
    var requestedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
    var releasedIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return released }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    func gateNext() { lock.lock(); gated = true; lock.unlock() }
    func resumePending(_ batch: ResolutionBatch) {
        lock.lock(); let waiting = pending; pending = nil; lock.unlock(); waiting?.resume(returning: batch)
    }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch {
        try await withCheckedThrowingContinuation { waiting in
            lock.lock(); ids.formUnion(requests.map(\.id))
            if gated { gated = false; pending = waiting; lock.unlock(); return }
            let batch = ResolutionBatch(generation: generation,
                results: Dictionary(uniqueKeysWithValues: requests.map { ($0.id, ResolutionResult.absent) }))
            let failed = fail; lock.unlock()
            if failed { waiting.resume(throwing: CocoaError(.fileReadUnknown)) }
            else { waiting.resume(returning: batch) }
        }
    }
    func release(_ ids: [String]) { lock.lock(); released.formUnion(ids); lock.unlock() }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> { AsyncThrowingStream { $0.finish() } }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .none }
    func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { lock.lock(); continuation = $0; lock.unlock() }
    }
    func send(_ change: SourceChange) {
        lock.lock(); if case .coverageReset(let value) = change { generation = value }
        let target = continuation; lock.unlock(); target?.yield(change)
    }
}
