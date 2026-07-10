import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class CoreWiringTests: XCTestCase {
    func testWatcherIndexSourceDeliversFilesystemUpdateIntoAppModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-watcher-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = SessionWatcher(
            stores: [ClaudeSessionStore(root: root)],
            debounceInterval: 0.05
        )
        let source = WatcherIndexSource(watcher: watcher)
        defer { source.stop() }
        let database = try TempleDB.inMemory()
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: source,
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database)
        )
        model.start()

        let initialDeadline = Date().addingTimeInterval(2)
        while model.isLoading, Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isLoading)

        let file = projectDirectory.appendingPathComponent("wired-session.jsonl")
        let json = #"{"type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        try json.write(to: file, atomically: true, encoding: .utf8)

        let updateDeadline = Date().addingTimeInterval(5)
        while !model.index.allSessions.contains(where: { $0.id == "wired-session" }),
              Date() < updateDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.index.allSessions.contains(where: { $0.id == "wired-session" }))
    }

    func testWatcherCodexReconcilerAdoptsFixtureRollout() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = SessionWatcher(
            stores: [CodexSessionStore(root: root)],
            debounceInterval: 0.05
        )
        let source = WatcherIndexSource(watcher: watcher)
        defer { source.stop() }
        let reconciler = WatcherCodexReconciler(indexSource: source, window: 3)
        let adopted = expectation(description: "adopted Codex session id")
        let launch = Date()
        let sessionID = UUID().uuidString.lowercased()
        reconciler.reconcile(projectPath: "/tmp/project", startedAt: launch) { id in
            XCTAssertEqual(id, sessionID)
            adopted.fulfill()
        }

        try await Task.sleep(for: .milliseconds(100))
        let rolloutDirectory = root
            .appendingPathComponent("sessions/2026/07/10", isDirectory: true)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: launch)
        let line = """
            {"timestamp":"\(timestamp)","type":"session_meta","payload":{"session_id":"\(sessionID)","cwd":"/tmp/project","originator":"codex-tui"}}
            """
        try line.write(
            to: rolloutDirectory.appendingPathComponent("rollout-fixture-\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        await fulfillment(of: [adopted], timeout: 5)
    }
}
