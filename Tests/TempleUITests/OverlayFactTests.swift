import XCTest
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// The overlay is the app's consumer of the engine's facts: it persists them
/// on the main actor, retries a failed write, and drops a retry the moment
/// the latest snapshot no longer carries the same facts. Writes are counted
/// on the SQL the persister actually ran.
@MainActor
final class OverlayFactTests: XCTestCase {
    private struct Flaky: Error {}

    private func summary(_ id: String, prompt: String) -> TranscriptSummary {
        TranscriptSummary(id: id, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/\(id).jsonl"),
                          modifiedAt: Date(timeIntervalSince1970: 50), cwd: "/work", firstPrompt: prompt)
    }

    func testAFailedFillIsRetriedOnlyWhileTheSameFactsAreCurrent() throws {
        let (db, trace) = try SQLTrace.database()
        try db.join(sessionID: "s", via: .imported, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s.jsonl"))
        var failures = 1
        let persister = FactPersister(database: db)
        var timers: [(TimeInterval, @MainActor () -> Void)] = []
        let overlay = SessionOverlayStore(db: db, persistFacts: { id, facts in
            if failures > 0 { failures -= 1; throw Flaky() }
            return try persister.persist(id, facts)
        }, scheduleFactRetry: { delay, action in timers.append((delay, action)); return {} })
        let stale = try XCTUnwrap(AuthorizedFacts.current(summary("s", prompt: "Stale"), in: db, opRevision: 1))
        trace.reset()
        overlay.applyFacts(["s": stale])
        XCTAssertEqual(overlay.pendingFactIDs, ["s"])
        XCTAssertEqual(timers.count, 1)
        // The engine revokes them (an invalidation): the retry finds nothing.
        overlay.applyFacts([:])
        XCTAssertTrue(overlay.pendingFactIDs.isEmpty)
        timers.removeFirst().1()
        XCTAssertEqual(trace.sessionRowUpdates, 0, "revoked facts are never written late")
        XCTAssertNil(try db.sessionState("s")?.title)
        // Facts authorized afresh: written once, and not again when re-delivered.
        let fresh = try XCTUnwrap(AuthorizedFacts.current(summary("s", prompt: "Fresh"), in: db, opRevision: 2))
        overlay.applyFacts(["s": fresh])
        overlay.applyFacts(["s": fresh])
        XCTAssertEqual(trace.sessionRowUpdates, 1)
        XCTAssertEqual(overlay.rows["s"]?.title, "Fresh")
    }

    func testARetryStillCurrentIsWrittenAndAMismatchAsksTheEngineAgain() throws {
        let (db, trace) = try SQLTrace.database()
        try db.join(sessionID: "s", via: .imported, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s.jsonl"))
        var failures = 1
        let persister = FactPersister(database: db)
        var timers: [@MainActor () -> Void] = []
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let overlay = SessionOverlayStore(db: db, now: { clock }, persistFacts: { id, facts in
            if failures > 0 { failures -= 1; throw Flaky() }
            return try persister.persist(id, facts)
        }, scheduleFactRetry: { _, action in timers.append(action); return {} })
        let facts = try XCTUnwrap(AuthorizedFacts.current(summary("s", prompt: "Kept"), in: db))
        trace.reset()
        overlay.applyFacts(["s": facts])
        XCTAssertEqual(trace.sessionRowUpdates, 0)
        // The backoff runs on the overlay's clock.
        clock = clock.addingTimeInterval(2)
        timers.removeFirst()()
        XCTAssertEqual(trace.sessionRowUpdates, 1)
        XCTAssertEqual(overlay.rows["s"]?.title, "Kept")

        // Facts for a membership that has since left and rejoined: refused
        // in SQL, and the owning engine is asked to re-read the row.
        let stale = try XCTUnwrap(AuthorizedFacts.current(summary("s", prompt: "Old membership"), in: db, opRevision: 9))
        XCTAssertTrue(try db.leave(sessionID: "s", host: .local))
        try db.join(sessionID: "s", via: .imported, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s.jsonl"))
        var asked: [(String, HostID)] = []
        overlay.onOwnershipMismatch = { asked.append(($0, $1)) }
        trace.reset()
        overlay.applyFacts(["s": stale])
        XCTAssertEqual(trace.sessionRowUpdates, 0)
        XCTAssertEqual(asked.map(\.0), ["s"])
        XCTAssertEqual(asked.map(\.1), [.local])
        XCTAssertNil(try db.sessionState("s")?.title)
    }
}

/// The whole app chain, on the main thread: a fact write's committed row
/// change reaches AppModel's ownership re-merge, which must wait until the
/// facts are applied (it can deliver a new snapshot, which applies facts
/// again). Before, this froze the main thread on the committer's lock.
@MainActor
final class AppModelFactReentrancyTests: XCTestCase {
    func testAnOwnershipChangeDuringAFactWriteIsMergedAfterwardsWithoutFreezing() async throws {
        let b = HostID(rawValue: "host-b")
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "s", via: .imported, agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s.jsonl"))
        let persister = FactPersister(database: db)
        var joinedOther = false
        let overlay = SessionOverlayStore(db: db, persistFacts: { id, facts in
            if id == "s", !joinedOther {
                // A row joins on another host in the middle of the write.
                joinedOther = true
                try db.join(sessionID: "other", via: .imported, core: SessionCore(host: b))
            }
            return try persister.persist(id, facts)
        })
        let local = FakeEngine(host: .local), remote = FakeEngine(host: b)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [local, remote], database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay,
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        let remoteVerdict = MemberResolution.loaded(TranscriptLocator(host: b, path: "/b/other.jsonl"))
        remote.publish(EngineSnapshot(generation: 1, resolutions: ["other": remoteVerdict]))
        let summary = TranscriptSummary(id: "s", agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/s.jsonl"),
                                        modifiedAt: Date(timeIntervalSince1970: 9), cwd: "/work", firstPrompt: "Filled")
        local.publish(.authorized(generation: 1, resolutions: ["s": .loaded(TranscriptLocator(host: .local, path: "/tmp/s.jsonl"))],
                                  summaries: ["s": summary], in: db))
        let deadline = Date().addingTimeInterval(3)
        while app.sessions.first(where: { $0.id == "other" })?.resolution != remoteVerdict, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(joinedOther)
        XCTAssertEqual(try db.sessionState("s")?.title, "Filled")
        XCTAssertEqual(app.sessions.first { $0.id == "other" }?.resolution, remoteVerdict,
                       "the ownership change was merged once the facts were applied")
    }
}
