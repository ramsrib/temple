import XCTest
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// Per-host snapshots merged into one, keyed by session (ADR-041): each
/// engine's ids are its own host's sessions, so the same id from two hosts
/// is two entries and neither host's snapshot can stand for the other's.
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

    private func facts(_ host: HostID, locatedOn locatorHost: HostID? = nil) -> AuthorizedFacts {
        AuthorizedFacts(authorization: .init(runEpoch: 1, opRevision: 1, incarnation: host.rawValue),
                        locator: TranscriptLocator(host: locatorHost ?? host, path: "/x"), agent: .claude,
                        signature: TranscriptSignature(modifiedAt: Date(timeIntervalSince1970: 1), size: 1, identity: 1),
                        coverage: 1, sharedRevision: nil, summary: nil)
    }

    func testTheMergeKeysEachEnginesIDsByItsHost() {
        let perHost: [HostID: EngineSnapshot] = [
            a: EngineSnapshot(generation: 5, resolutions: ["copied": loaded(a, "copied"), "a-only": loaded(a, "a-only")],
                              facts: ["copied": facts(a), "stray": facts(a, locatedOn: b)],
                              memberships: ["copied": MembershipRef(id: "copied", host: a, incarnation: "ia"),
                                            "wrong": MembershipRef(id: "wrong", host: b, incarnation: "x")]),
            b: EngineSnapshot(generation: 2, resolutions: ["copied": loaded(b, "copied")], facts: ["copied": facts(b)])
        ]
        let merged = EngineSnapshot.merged(perHost: perHost, generation: 9)
        XCTAssertEqual(merged.generation, 9)
        XCTAssertEqual(merged.resolutions, [SessionKey(id: "copied", host: a): loaded(a, "copied"),
                                            SessionKey(id: "a-only", host: a): loaded(a, "a-only"),
                                            SessionKey(id: "copied", host: b): loaded(b, "copied")])
        XCTAssertEqual(Set(merged.facts.keys), [SessionKey(id: "copied", host: a), SessionKey(id: "copied", host: b)],
                       "facts whose transcript is on another host are not that engine's to give")
        XCTAssertEqual(Array(merged.memberships.keys), [SessionKey(id: "copied", host: a)],
                       "a membership naming another host is not that engine's")
    }

    /// The same id on two hosts: each host's snapshot lands as its own
    /// session, and a later snapshot from one never moves the other.
    func testTheSameIDOnTwoHostsIsTwoSessionsInTheMerge() async throws {
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let set = EngineSet(engines: [engineA, engineB])
        set.start { _ in }
        let onA = SessionKey(id: "id", host: a), onB = SessionKey(id: "id", host: b)
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")], facts: ["id": facts(a)]))
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": .confirmedAbsent], facts: ["id": facts(b)]))
        try await waitFor { set.latest?.resolutions.count == 2 }
        XCTAssertEqual(set.latest?.resolutions[onA], loaded(a, "id"))
        XCTAssertEqual(set.latest?.resolutions[onB], .confirmedAbsent)
        XCTAssertEqual(set.latest?.facts[onA]?.locator.host, a)
        XCTAssertEqual(set.latest?.facts[onB]?.locator.host, b)
        engineA.publish(EngineSnapshot(generation: 2, resolutions: ["id": .unreadable]))
        try await waitFor { set.latest?.resolutions[onA] == .unreadable }
        XCTAssertEqual(set.latest?.resolutions[onB], .confirmedAbsent, "host B's session is untouched")
        XCTAssertNil(set.latest?.facts[onA], "A's revoked facts are gone")
        XCTAssertNotNil(set.latest?.facts[onB])
        set.remove(host: b)
        XCTAssertNil(set.latest?.resolutions[onB], "a removed host's sessions leave the merge")
        XCTAssertEqual(set.latest?.resolutions[onA], .unreadable)
        set.stop()
    }

    /// The app's own wiring: the same id on two hosts is two rows, each
    /// presented with its own host's verdict, and a leave on one host
    /// leaves the other row as it was.
    func testAppModelPresentsEachHostsSessionWithItsOwnVerdict() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "id", via: .imported, core: SessionCore(host: a))
        try db.join(sessionID: "id", via: .imported, core: SessionCore(host: b))
        let engineA = FakeEngine(host: a), engineB = FakeEngine(host: b)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [engineA, engineB], database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        app.start()
        engineA.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(a, "id")]))
        engineB.publish(EngineSnapshot(generation: 1, resolutions: ["id": loaded(b, "id")]))
        func row(_ host: HostID) -> Session? { app.sessions.first { $0.id == SessionKey(id: "id", host: host) } }
        try await waitFor { row(self.a)?.resolution == self.loaded(self.a, "id") && row(self.b)?.resolution == self.loaded(self.b, "id") }
        XCTAssertEqual(app.sessions.count, 2)
        XCTAssertTrue(try db.leave(sessionID: "id", host: a))
        try await waitFor { row(self.a) == nil }
        XCTAssertEqual(row(b)?.resolution, loaded(b, "id"))
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
