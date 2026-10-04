import XCTest
@testable import TempleCore
import TempleTestSupport

/// Which members the engine works on, and when — against a scripted host.
final class HostSessionSourceTests: XCTestCase {
    private let remote = HostID(rawValue: "fake")
    private var engines: [SessionEngine] = []

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        engines.removeAll()
        try await super.tearDown()
    }

    private func wait(_ message: String = "condition", _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await !condition() {
            guard Date() < deadline else { XCTFail("timed out: \(message)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func engine(_ source: FakeHostSource, _ db: TempleDB) -> SessionEngine {
        let engine = SessionEngine(source: source, database: db)
        engines.append(engine)
        return engine
    }

    private func path(_ id: String) -> String { "/home/me/.agent-a/projects/-w/\(id).jsonl" }
    private func data(_ id: String) -> Data { Data(#"{"type":"user","sessionId":"\#(id)","cwd":"/w","message":{"content":"hi"}}"#.utf8) }

    func testEngineResolvesOnlyItsHostsRows() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "local", via: .imported, core: SessionCore(host: .local))
        try db.join(sessionID: "remote", via: .imported, core: SessionCore(host: remote))
        let source = FakeHostSource(host: remote)
        let engine = engine(source, db)
        await engine.start()
        try await wait { engine.resolution(for: "remote") != nil && source.counters.locates >= 1 }
        XCTAssertNil(engine.resolution(for: "local"))
        XCTAssertEqual(source.counters.locatedIDs.first, ["remote"])
        try db.join(sessionID: "next-local", via: .created, core: SessionCore(host: .local))
        try db.join(sessionID: "next-remote", via: .imported, core: SessionCore(host: remote))
        try await wait { engine.resolution(for: "next-remote") != nil }
        XCTAssertFalse(source.counters.locatedIDs.joined().contains("next-local"))
        XCTAssertNil(engine.resolution(for: "next-local"))
        _ = try db.leave(sessionID: "next-remote", host: remote)
        try await wait { engine.resolution(for: "next-remote") == nil }
    }

    /// New coverage, learned from a listing or from the event (either first):
    /// every other member is located again, and only once.
    func testNewCoverageRelocatesOtherMembersInEitherDeliveryOrder() async throws {
        for eventFirst in [false, true] {
            let db = try TempleDB.inMemory()
            let source = FakeHostSource(host: remote)
            for id in ["a", "b"] {
                source.write(path(id), agent: .claude, data: data(id))
                try db.join(sessionID: id, via: .imported, agent: .claude,
                            locator: TranscriptLocator(host: remote, path: path(id)),
                            core: SessionCore(host: remote, directory: "/w", title: "T", lastActiveAt: Date()))
            }
            let engine = engine(source, db)
            await engine.start()
            try await wait { engine.resolution(for: "b")?.isLoadedForTest == true }
            let gate = FakeGate()
            source.locateGate = gate
            await engine.requestResolution("a")
            try await wait { gate.arrivals == 1 }
            source.dropEvents()
            if eventFirst { try await wait { await engine.currentCoverage == 2 } }
            source.locateGate = nil
            gate.open()
            try await wait("both relocated") { source.counters.locatedIDs.dropFirst().joined().contains("b") }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(source.counters.locatedIDs.dropFirst().joined().filter { $0 == "b" }.count, 1, "eventFirst: \(eventFirst)")
            let coverage = await engine.currentCoverage
            XCTAssertEqual(coverage, 2)
            await engine.stop()
        }
    }

    func testTransportFailureNeverProvesAbsence() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "member", via: .imported, agent: .claude, core: SessionCore(host: remote))
        let source = FakeHostSource(host: remote)
        source.breakTransport()
        let engine = engine(source, db)
        await engine.start()
        try await wait { engine.resolution(for: "member") == .incomplete }
        XCTAssertTrue(engine.latestSnapshot?.facts.isEmpty ?? false)
        source.breakTransport(false)
        await engine.requestResolution("member")
        try await wait { engine.resolution(for: "member") == .confirmedAbsent }
    }

    /// Shared session titles can complete only a Codex (or agent-less)
    /// member still missing one, and only one with a transcript to read them
    /// against; nobody else is located again for them.
    func testSharedTitleChangesRelocateOnlyUntitledCodexMembersWithATranscript() async throws {
        let db = try TempleDB.inMemory()
        let source = FakeHostSource(host: remote)
        func rollout(_ id: String) -> String { "/home/me/.agent-b/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(id).jsonl" }
        let untitled = "00000000-0000-0000-0000-00000000000a", titled = "00000000-0000-0000-0000-00000000000b"
        let absent = "00000000-0000-0000-0000-00000000000c"
        for id in [untitled, titled] {
            source.write(rollout(id), agent: .codex, data: Data(#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/w"}}"#.utf8))
        }
        let core = SessionCore(host: remote, directory: "/w", lastActiveAt: Date())
        try db.join(sessionID: untitled, via: .imported, agent: .codex, locator: TranscriptLocator(host: remote, path: rollout(untitled)), core: core)
        try db.join(sessionID: titled, via: .imported, agent: .codex, locator: TranscriptLocator(host: remote, path: rollout(titled)),
                    core: SessionCore(host: remote, directory: "/w", title: "Named", lastActiveAt: Date()))
        try db.join(sessionID: absent, via: .imported, agent: .codex, core: core)
        try db.join(sessionID: "claude-untitled", via: .imported, agent: .claude, core: SessionCore(host: remote))
        let engine = engine(source, db)
        await engine.start()
        try await wait { engine.resolution(for: absent) == .confirmedAbsent && engine.resolution(for: untitled)?.isLoadedForTest == true }
        try await Task.sleep(for: .milliseconds(50))
        let calls = source.counters.locates
        source.setShared(.codex, CodexFormat.historyInput, Data())
        try await wait { source.counters.locates > calls }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(source.counters.locatedIDs.dropFirst(calls).flatMap { $0 }, [untitled])
    }

    /// A raw observation of a member's file locates that member again, and only it.
    func testRawTranscriptEventsLocateOnlyTheMembersTheyName() async throws {
        let db = try TempleDB.inMemory()
        for id in ["member", "other"] { try db.join(sessionID: id, via: .imported, agent: .claude, core: SessionCore(host: remote)) }
        let source = FakeHostSource(host: remote)
        let engine = engine(source, db)
        await engine.start()
        try await wait { engine.resolution(for: "other") == .confirmedAbsent }
        let calls = source.counters.locates
        source.write(path("member"), agent: .claude, data: data("member"))
        source.write(path("stranger"), agent: .claude, data: data("stranger"))
        try await wait { source.counters.locates > calls }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(source.counters.locatedIDs.dropFirst(calls).joined()), ["member"])
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

extension MemberResolution {
    var isLoadedForTest: Bool { if case .loaded = self { true } else { false } }
}
