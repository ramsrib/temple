import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
@testable import TempleRemoteHost

/// The ledger a hand-over holds writes `remote-state.sqlite` directly, by
/// run (round 4): nothing of the host's launcher or registry entry is used.
@MainActor
final class RemoteStoreLedgerTests: XCTestCase {
    func testTheLedgerMarksTheRunsTabClosedInTheStore() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-ledger-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteStateStore(directory: directory)
        var run = RemoteRun(handle: "p1", host: HostID(rawValue: "box"), agent: .codex, mode: .new, directoryIntent: "~",
                            sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-p1"), startedAt: Date())
        run.creation = .proven
        try store.insert(run)
        _ = try store.claim("p1", sessionID: "c1", how: .verified)
        XCTAssertEqual(try store.pendingRuns(host: HostID(rawValue: "box")).map(\.handle), ["p1"])
        let ledger: RemoteRunLedger = RemoteStoreLedger(store: store)
        try await ledger.markTabClosed("p1")
        XCTAssertNotNil(try store.run("p1")?.tabClosedAt)
        XCTAssertEqual(try store.pendingRuns(host: HostID(rawValue: "box")), [], "no longer restored from its run")
    }

    /// Temple's own yes is an ordinary claim (`.automatic`), refused in the
    /// claim's own transaction for a run with any declined candidate: a
    /// decline is the durable "asked", across relaunches.
    func testAnAutomaticClaimIsRefusedForARunWithADecline() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-automatic-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RemoteStateStore(directory: directory)
        for handle in ["p1", "p2"] {
            var run = RemoteRun(handle: handle, host: HostID(rawValue: "box"), agent: .codex, mode: .new, directoryIntent: "~",
                                sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.creation = .proven
            try store.insert(run)
        }
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .automatic, rolloutPath: "/r/c7.jsonl"), .claimed)
        XCTAssertEqual(try store.run("p1")?.claim, .automatic)
        try store.decline("p2", rolloutPath: "/r/c6.jsonl")
        XCTAssertEqual(try store.claim("p2", sessionID: "c8", how: .automatic, rolloutPath: "/r/c8.jsonl"), .declined)
        XCTAssertNil(try store.run("p2")?.sessionID)
        XCTAssertEqual(try store.claim("p2", sessionID: "c8", how: .confirmed, rolloutPath: "/r/c8.jsonl"), .claimed,
                       "the user's own yes still claims")
    }

    /// Discard of a linked session dismisses the stopped run alone, and
    /// nothing while another run of the session is live or newer.
    func testDismissingAStoppedRunSparesANewerOne() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-dismiss-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = HostID(rawValue: "box")
        let store = try RemoteStateStore(directory: directory)
        func insert(_ handle: String, at seconds: TimeInterval, ended: Bool) throws {
            var run = RemoteRun(handle: handle, host: box, agent: .codex, mode: .resume, directoryIntent: "~", sessionID: "c7",
                                recordPath: RecordDirectory.locator(marker: "r-\(handle)"),
                                startedAt: Date(timeIntervalSince1970: seconds))
            if ended { run.endedAt = Date(timeIntervalSince1970: seconds + 1) }
            try store.insert(run)
        }
        try insert("old", at: 100, ended: true)
        try insert("p1", at: 200, ended: true)
        try insert("h9", at: 300, ended: false)
        XCTAssertFalse(try store.dismissStoppedRun("p1", sessionID: "c7", at: Date()), "a newer live run keeps it")
        XCTAssertNil(try store.run("p1")?.dismissedAt)
        try store.dismissRun("h9", at: Date())
        XCTAssertTrue(try store.dismissStoppedRun("p1", sessionID: "c7", at: Date()))
        XCTAssertNotNil(try store.run("p1")?.dismissedAt)
        XCTAssertNil(try store.run("old")?.dismissedAt, "only the stopped run")
    }
}
