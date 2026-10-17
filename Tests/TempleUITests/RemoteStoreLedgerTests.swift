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

    /// Not this session undoes a link in one write: the claim goes, the
    /// run is restored by its handle again, the candidate is declined (and
    /// can never be claimed for it again). A hand-over that lands later
    /// finds no id and retires nothing.
    func testUnlinkingUndoesTheClaimAndALateHandOverRetiresNothing() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-unlink-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = HostID(rawValue: "box")
        let store = try RemoteStateStore(directory: directory)
        var run = RemoteRun(handle: "p1", host: box, agent: .codex, mode: .new, directoryIntent: "~",
                            sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-p1"), startedAt: Date())
        run.creation = .proven
        try store.insert(run)
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .confirmed, rolloutPath: "/r/c7.jsonl"), .claimed)
        try store.markJoined("p1", at: Date())
        let ledger: RemoteRunLedger = RemoteStoreLedger(store: store)
        try await ledger.markTabClosed("p1")
        XCTAssertTrue(try store.pendingRuns(host: box).isEmpty, "handed over")

        XCTAssertFalse(try store.unlinkClaim("p1", sessionID: "other", rolloutPath: "/r/c7.jsonl"), "only that id's claim")
        XCTAssertEqual(try store.run("p1")?.sessionID, "c7")
        XCTAssertTrue(try store.unlinkClaim("p1", sessionID: "c7", rolloutPath: "/r/c7.jsonl"))
        let undone = try XCTUnwrap(store.run("p1"))
        XCTAssertNil(undone.sessionID)
        XCTAssertNil(undone.claim)
        XCTAssertNil(undone.joinedAt)
        XCTAssertNil(undone.tabClosedAt)
        XCTAssertEqual(try store.pendingRuns(host: box).map(\.handle), ["p1"], "restored by its handle again")
        XCTAssertEqual(try store.declined("p1"), [RemotePath("/r/c7.jsonl")])
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .confirmed, rolloutPath: "/r/c7.jsonl"), .declined)

        try await ledger.markTabClosed("p1")
        XCTAssertNil(try store.run("p1")?.tabClosedAt, "a late hand-over finds no id: the run stays restorable")
        XCTAssertNotNil(try store.run("p1")?.askedAt, "undone: asked about from now on")
    }

    /// Asked and an automatic claim's provenance are kept with the run
    /// (r6): an automatic claim records what Not this session needs, is
    /// refused once the run was asked about, and goes with the claim.
    func testAutomaticClaimProvenanceAndAskedAreKeptWithTheRun() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("temple-asked-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = HostID(rawValue: "box")
        let store = try RemoteStateStore(directory: directory)
        for handle in ["p1", "p2"] {
            var run = RemoteRun(handle: handle, host: box, agent: .codex, mode: .new, directoryIntent: "~",
                                sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.creation = .proven
            try store.insert(run)
        }
        let link = RemoteRun.AutoLink(rolloutPath: "/r/c7.jsonl", sessionID: "c7", firstPrompt: "hi", promptKnown: true,
                                      startedAt: Date(timeIntervalSince1970: 1_800_000_000), directory: "/home/u/p")
        XCTAssertEqual(try store.claim("p1", sessionID: "c7", how: .confirmed, rolloutPath: link.rolloutPath, automatic: link), .claimed)
        XCTAssertEqual(try store.run("p1")?.autoLink, link)
        try store.recordAutoLinkRow("p1", sessionID: "c7", incarnation: "inc-1")
        XCTAssertEqual(try store.run("p1")?.autoLink?.incarnation, "inc-1")
        try store.releaseClaim("p1", sessionID: "c7")
        XCTAssertNil(try store.run("p1")?.autoLink, "goes with the claim")

        try store.markAsked("p2", at: Date())
        XCTAssertNotNil(try store.run("p2")?.askedAt)
        XCTAssertEqual(try store.claim("p2", sessionID: "c8", how: .confirmed, rolloutPath: "/r/c8.jsonl",
                                       automatic: RemoteRun.AutoLink(rolloutPath: "/r/c8.jsonl", sessionID: "c8", firstPrompt: nil,
                                                                     promptKnown: false, startedAt: Date(), directory: "/home/u/p")),
                       .asked, "never automatic once asked")
        XCTAssertEqual(try store.claim("p2", sessionID: "c8", how: .confirmed, rolloutPath: "/r/c8.jsonl"), .claimed,
                       "the user's own yes still claims")
    }
}
