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
            // Two folders: neighbours in one folder are contended (below).
            var run = RemoteRun(handle: handle, host: HostID(rawValue: "box"), agent: .codex, mode: .new,
                                directoryIntent: "~/\(handle)", sessionID: nil,
                                recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.creation = .proven
            run.directory = "/home/u/\(handle)"
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

    /// The claim's own transaction refuses Temple's yes while another new
    /// Codex session Temple started in the same folder on the host is still
    /// unidentified and running; once that one is identified or ended, or
    /// for another folder, it claims.
    func testAnAutomaticClaimIsRefusedWhileANeighbourIsUnidentified() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-neighbour-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = HostID(rawValue: "box")
        let store = try RemoteStateStore(directory: directory)
        func insert(_ handle: String, folder: String) throws {
            var run = RemoteRun(handle: handle, host: box, agent: .codex, mode: .new, directoryIntent: "~/p",
                                sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.creation = .proven
            run.directory = folder
            try store.insert(run)
        }
        try insert("p1", folder: "/home/u/p")
        try insert("p2", folder: "/home/u/p")
        try insert("p3", folder: "/home/u/other")
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .automatic, rolloutPath: "/r/c7.jsonl"), .contended)
        XCTAssertEqual(try store.claim("p3", sessionID: "c9", how: .automatic, rolloutPath: "/r/c9.jsonl"), .claimed,
                       "another folder is no neighbour")
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .confirmed, rolloutPath: "/r/c7.jsonl"), .claimed,
                       "the user's own yes still claims")
        XCTAssertEqual(try store.claim("p2", sessionID: "c8", how: .automatic, rolloutPath: "/r/c8.jsonl"), .claimed,
                       "its neighbour identified: no longer contended")
    }

    /// Folders compare only once resolved: a neighbour whose pane has not
    /// reported its folder (`~/p`, detached or not) counts as the same
    /// folder; resolved ones compare by bytes, so a precomposed and a
    /// decomposed spelling are two folders.
    func testANeighbourWithAnUnresolvedFolderBlocksAnAutomaticClaim() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-unresolved-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = HostID(rawValue: "box")
        let store = try RemoteStateStore(directory: directory)
        func insert(_ handle: String, intent: String, folder: String?, tabClosed: Bool = false) throws {
            var run = RemoteRun(handle: handle, host: box, agent: .codex, mode: .new, directoryIntent: intent,
                                sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.creation = .proven
            run.directory = folder
            run.tabClosedAt = tabClosed ? Date() : nil
            try store.insert(run)
        }
        // A detached neighbour (its tab closed, still running) whose pane
        // never reported: `~/p` is not compared with `/home/u/p`, it blocks.
        try insert("p1", intent: "~/p", folder: "/home/u/p")
        try insert("p2", intent: "~/p", folder: nil, tabClosed: true)
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .automatic, rolloutPath: "/r/c7.jsonl"), .contended)
        try store.dismissRun("p2", at: Date())
        // Resolved folders compare by bytes.
        try insert("p3", intent: "~/caf\u{E9}", folder: "/home/u/caf\u{E9}")
        try insert("p4", intent: "~/cafe\u{301}", folder: "/home/u/cafe\u{301}")
        XCTAssertEqual(try store.claim("p3", sessionID: "c8", how: .automatic, rolloutPath: "/r/c8.jsonl"), .claimed,
                       "two spellings the host keeps apart are two folders")
        try insert("p5", intent: "/home/u/p", folder: "/home/u/p")
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .automatic, rolloutPath: "/r/c7.jsonl"), .contended,
                       "the same resolved folder")
    }
}
