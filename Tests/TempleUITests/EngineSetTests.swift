import XCTest
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// Per-host snapshots merged by current row ownership (C11): an id comes
/// only from the engine of the host whose row holds it now, and the merge is
/// recomputed on ownership changes as well as on snapshots.
@MainActor
final class EngineSetTests: XCTestCase {
    private let a = HostID(rawValue: "host-a")
    private let b = HostID(rawValue: "host-b")

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    private func loaded(_ host: HostID, _ id: String) -> MemberResolution {
        .loaded(TranscriptLocator(host: host, path: "/\(host.rawValue)/\(id).jsonl"))
    }

    func testTheMergeKeepsEachIDFromItsOwnersEngineOnly() {
        let perHost: [HostID: EngineSnapshot] = [
            a: EngineSnapshot(generation: 5, resolutions: ["moved": loaded(a, "moved"), "a-only": loaded(a, "a-only")]),
            b: EngineSnapshot(generation: 2, resolutions: ["moved": loaded(b, "moved")])
        ]
        let owners: [String: HostID] = ["moved": b, "a-only": a]
        let merged = EngineSnapshot.merged(perHost: perHost, owner: { owners[$0] }, generation: 9)
        XCTAssertEqual(merged.generation, 9)
        XCTAssertEqual(merged.resolutions, ["moved": loaded(b, "moved"), "a-only": loaded(a, "a-only")])
        XCTAssertTrue(EngineSnapshot.merged(perHost: perHost, owner: { _ in nil }, generation: 1).resolutions.isEmpty)
    }

    /// The new host's snapshot arrives before the row moves: it is held back
    /// until the ownership change, which then brings it in — and the old
    /// host's stale verdict never wins.
    func testASnapshotThatArrivesBeforeTheOwnershipChangeIsNotLost() async throws {
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let set = EngineSet(engines: [engineA, engineB])
        var owner: HostID? = a
        set.owner = { _ in owner }
        var updates: [EngineSnapshot] = []
        set.start { updates.append($0) }
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")]))
        try await waitFor { set.latest?.resolutions["id"] == self.loaded(self.a, "id") }
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(b, "id")]))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(set.latest?.resolutions["id"], loaded(a, "id"), "still A's row")
        owner = b
        set.ownershipChanged()
        XCTAssertEqual(set.latest?.resolutions["id"], loaded(b, "id"))
        // A late snapshot from A after the move cannot take it back.
        engineA.publish(EngineSnapshot(generation: 2, resolutions: ["id": loaded(a, "id")]))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(set.latest?.resolutions["id"], loaded(b, "id"))
        set.stop()
    }

    /// The ownership change first, then the new host's snapshot.
    func testAnOwnershipChangeBeforeTheNewHostsSnapshotDropsTheOldVerdict() async throws {
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let set = EngineSet(engines: [engineA, engineB])
        var owner: HostID? = a
        set.owner = { _ in owner }
        set.start { _ in }
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")]))
        try await waitFor { set.latest?.resolutions["id"] != nil }
        owner = b
        set.ownershipChanged()
        XCTAssertNil(set.latest?.resolutions["id"], "A's verdict is not B's row's")
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(b, "id")]))
        try await waitFor { set.latest?.resolutions["id"] == self.loaded(self.b, "id") }
        set.stop()
    }

    /// Facts follow ownership exactly like resolutions.
    func testFactsAreMergedByOwnershipToo() async throws {
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let set = EngineSet(engines: [engineA, engineB])
        var owner: HostID? = a
        set.owner = { _ in owner }
        set.start { _ in }
        func facts(_ host: HostID) -> AuthorizedFacts {
            AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 1, incarnation: host.rawValue),
                            locator: TranscriptLocator(host: host, path: "/x"), agent: .claude,
                            signature: TranscriptSignature(modifiedAt: Date(timeIntervalSince1970: 1), size: 1, identity: 1),
                            coverage: 1, sharedRevision: nil, summary: nil)
        }
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")], facts: ["id": facts(a)]))
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(b, "id")], facts: ["id": facts(b)]))
        try await waitFor { set.latest?.facts["id"]?.locator.host == self.a }
        owner = b
        set.ownershipChanged()
        XCTAssertEqual(set.latest?.facts["id"]?.locator.host, b)
        set.stop()
    }

    /// The app's own wiring: a row that moves host in the database moves the
    /// merge with it (AppModel calls `ownershipChanged` on row changes).
    func testAppModelRemergesWhenARowChangesOwner() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "id", via: .imported, core: SessionCore(host: a))
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [engineA, engineB], database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        app.start()
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")]))
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(b, "id")]))
        try await waitFor { app.sessions.first?.resolution == self.loaded(self.a, "id") }
        XCTAssertTrue(try db.leave(sessionID: "id", host: a))
        try db.join(sessionID: "id", via: .imported, core: SessionCore(host: b))
        try await waitFor { app.sessions.first?.resolution == self.loaded(self.b, "id") }
    }

    /// One pass, one publication: two members whose reads are both in flight
    /// produce no snapshot until both are done.
    func testAPassPublishesOnceForAllItsMembers() async throws {
        let source = FakeHostSource(host: a)
        let (db, _) = try SQLTrace.database()
        for id in ["one", "two"] {
            let path = "/h/.claude/projects/-w/\(id).jsonl"
            source.write(path, agent: .claude, data: Data(#"{"type":"user","sessionId":"\#(id)","cwd":"/w","message":{"content":"hi"}}"#.utf8))
            try db.join(sessionID: id, via: .imported, agent: .claude, locator: TranscriptLocator(host: a, path: path),
                        core: SessionCore(host: a, directory: "/w", title: "T", lastActiveAt: Date()))
        }
        let engine = SessionEngine(source: source, database: db)
        var seen: [EngineSnapshot] = []
        let stream = engine.snapshots()
        let task = Task { for await snapshot in stream { seen.append(snapshot) } }
        defer { task.cancel() }
        let gate = FakeGate()
        source.readGate = gate
        await engine.start()
        try await waitFor { gate.arrivals == 2 }
        try await Task.sleep(for: .milliseconds(50))
        let before = seen.count
        XCTAssertTrue(seen.allSatisfy { !$0.resolutions.values.contains { if case .loaded = $0 { return true }; return false } })
        gate.open()
        try await waitFor { seen.last?.resolutions.values.allSatisfy { if case .loaded = $0 { return true }; return false } == true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(seen.count, before + 1, "both verdicts in one publication")
        await engine.stop()
    }
}
