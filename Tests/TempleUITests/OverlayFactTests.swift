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
