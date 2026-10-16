import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

final class RemoteStateStoreTests: XCTestCase {
    private let host = HostID(rawValue: "box")

    private func run(_ handle: String, session: String? = "s1", at seconds: TimeInterval) -> RemoteRun {
        RemoteRun(handle: handle, host: host, agent: .claude, mode: .new, directoryIntent: "~/p",
                  sessionID: session, recordPath: "m-\(handle)", startedAt: Date(timeIntervalSince1970: seconds))
    }

    func testItsOwnMigratorAndFile() throws {
        XCTAssertEqual(RemoteStateStore.migrationIdentifiers, ["r1-runs", "r2-conversation", "r3-config", "r4-codex-identity", "r5-input"])
        let tree = TempTree("remote-store")
        _ = try RemoteStateStore(directory: tree.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path + "/remote-state.sqlite"))
        // Opening again migrates nothing and keeps what is there.
        let again = try RemoteStateStore(directory: tree.url)
        try again.insert(run("h1", at: 1))
        XCTAssertEqual(try RemoteStateStore(directory: tree.url).run("h1")?.sessionName, "temple-h1")
    }

    func testEveryFieldRoundTrips() throws {
        let store = try RemoteStateStore()
        var original = run("h1", at: 100)
        original.directory = "/home/u/p"
        original.okAt = 1_700_000_000
        original.panePID = 42
        original.paneStart = "999"
        original.socketPath = "/tmp/tmux-1000/temple"
        original.serverPID = 7
        original.serverStart = "3"
        original.creation = .proven
        original.endedAt = Date(timeIntervalSince1970: 200)
        original.endEvidence = .killed
        original.leftRunningAt = Date(timeIntervalSince1970: 150)
        original.leftRunningReason = .quitDeadline
        original.leftRunningNoticedAt = Date(timeIntervalSince1970: 160)
        original.dismissedAt = Date(timeIntervalSince1970: 170)
        original.failure = "why"
        original.conversation = .confirmed
        original.claudeConfig = .set("rel dir\nx")
        original.attachment = 3
        try store.insert(original)
        XCTAssertEqual(try store.run("h1"), original)
    }

    /// Implementation note 1: a session keeps several run records; the
    /// latest that is not Ended is what Open attaches to.
    func testSeveralRunsPerSessionWithOldRecordsRetained() throws {
        let store = try RemoteStateStore()
        try store.insert(run("h1", at: 1))
        XCTAssertEqual(try store.liveRun(host: host, sessionID: "s1")?.handle, "h1")
        // Ended, then resumed in a new run.
        try store.update("h1") { $0.endedAt = Date(); $0.endEvidence = .killed }
        XCTAssertNil(try store.liveRun(host: host, sessionID: "s1"))
        try store.insert(run("h2", at: 2))
        XCTAssertEqual(try store.liveRun(host: host, sessionID: "s1")?.handle, "h2")
        // Unknown, then Resume anyway: the old run is kept, not Ended.
        try store.insert(run("h3", at: 3))
        XCTAssertEqual(try store.runs(host: host, sessionID: "s1").map(\.handle), ["h1", "h2", "h3"])
        XCTAssertEqual(try store.liveRun(host: host, sessionID: "s1")?.handle, "h3")
        XCTAssertFalse(try XCTUnwrap(store.run("h2")).isEnded)
    }

    func testAttachmentAndLeftRunning() throws {
        let store = try RemoteStateStore()
        try store.insert(run("h1", at: 1))
        XCTAssertEqual(try store.nextAttachment("h1"), 2)
        XCTAssertEqual(try store.nextAttachment("h1"), 3)
        XCTAssertNil(try store.nextAttachment("nope"))
        try store.update("h1") {
            $0.leftRunningAt = Date(); $0.leftRunningReason = .hostDidNotAnswer
        }
        XCTAssertEqual(try store.leftRunning(host: host).map(\.handle), ["h1"])
        try store.update("h1") { $0.endedAt = Date() }
        XCTAssertEqual(try store.leftRunning(host: host), [], "an ended run is no longer left running")
    }

    func testRemoteProjectState() throws {
        let store = try RemoteStateStore()
        try store.setProjectArchived(true, host: host, path: "/a")
        try store.setProjectArchived(true, host: HostID(rawValue: "other"), path: "/a")
        try store.setProjectArchived(false, host: host, path: "/a")
        try store.setProjectOrder([(host, "/b", 0), (host, "/a", 1)])
        XCTAssertEqual(try store.projectStates(), [
            RemoteStateStore.ProjectState(host: host, path: "/a", archived: false, position: 1),
            RemoteStateStore.ProjectState(host: host, path: "/b", archived: false, position: 0),
            RemoteStateStore.ProjectState(host: HostID(rawValue: "other"), path: "/a", archived: true, position: nil),
        ])
    }
}
