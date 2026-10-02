import XCTest
@testable import TempleUI
@testable import TempleCore
import CoreServices

@MainActor
final class CoreWiringTests: XCTestCase {
    func testWatcherIndexSourceDeliversFilesystemUpdateIntoAppModel() async throws { try await exerciseWiring(injectEvents: false) }
    func testWatcherIndexSourceDeliversInjectedUpdateIntoAppModel() async throws { try await exerciseWiring(injectEvents: true) }

    private func exerciseWiring(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-watcher-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Isolate the startup cache: never read or overwrite the developer's
        // real ~/Library/Application Support cache from a test.
        let cacheURL = root.appendingPathComponent("index-cache.json")
        let database = try TempleDB.inMemory()
        let watcher = SessionWatcher(
            stores: [ClaudeSessionStore(root: root)], database: database,
            debounceInterval: 0.05
        )
        try database.join(sessionID: "wired-session", via: .created, agent: .claude)
        let source = WatcherIndexSource(watcher: watcher, cacheURL: cacheURL)
        defer { source.stop() }
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: source,
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database),
            cacheURL: cacheURL
        )
        model.start()

        let initialDeadline = Date().addingTimeInterval(2)
        while model.isLoading, Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isLoading)
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")

        if injectEvents { model.openSession(id: "wired-session") }
        let file = projectDirectory.appendingPathComponent("wired-session.jsonl")
        let json = #"{"type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        try json.write(to: file, atomically: true, encoding: .utf8)
        if injectEvents { watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated)) }

        let updateDeadline = Date().addingTimeInterval(5)
        while !model.index.allSessions.contains(where: { $0.id == "wired-session" }),
              Date() < updateDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.index.allSessions.contains(where: { $0.id == "wired-session" }))
        if injectEvents { XCTAssertEqual(model.openSessions.activeTab?.sessionID, "wired-session") }
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
        let source = WatcherIndexSource(
            watcher: watcher,
            cacheURL: root.appendingPathComponent("index-cache.json")
        )
        defer { source.stop() }
        let reconciler = WatcherCodexReconciler(indexSource: source, window: 3)
        let adopted = expectation(description: "adopted Codex session id")
        let launch = Date()
        let sessionID = UUID().uuidString.lowercased()
        reconciler.reconcile(projectPath: "/tmp/project", startedAt: launch) { id in
            XCTAssertEqual(id, sessionID)
            XCTAssertNotNil(reconciler.transcriptPath(for: id))
            XCTAssertNil(reconciler.transcriptPath(for: id), "Adoption paths are consumed, not retained per tab")
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
            to: rolloutDirectory.appendingPathComponent("rollout-2026-07-10T00-00-00-\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        await fulfillment(of: [adopted], timeout: 5)
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(predicate())
    }

    func testPrimaryRegistrationReplaysEarlySnapshotAndStopClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02)
        let source = WatcherIndexSource(watcher: watcher, cacheURL: root.appendingPathComponent("cache.json"))
        defer { source.stop() }
        let early = expectation(description: "early observer received publication")
        let token = source.observe { _ in early.fulfill() }
        await fulfillment(of: [early], timeout: 2)
        source.removeObserver(token)
        var resolutionReplays = 0
        source.onResolutionUpdate = { _ in resolutionReplays += 1 }
        XCTAssertEqual(resolutionReplays, 1, "A late UI subscriber also receives completed resolution")
        var received = 0
        source.start { _ in received += 1 }
        XCTAssertEqual(received, 1, "Primary registration synchronously replays the live generation")
        source.stop()
        source.start { _ in received += 1 }
        XCTAssertEqual(received, 1, "Stopped generation cannot be replayed")
        try await waitFor { received == 2 }
    }

    func testAppModelUsesMemberResolutionAndDropsFinalPendingOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try TempleDB.inMemory()
        try database.join(sessionID: "pruned", via: .created, agent: .claude)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: database, debounceInterval: 0.02)
        try database.join(sessionID: "awaiting", via: .created, agent: .claude)
        let cache = root.appendingPathComponent("cache.json")
        let source = WatcherIndexSource(watcher: watcher, cacheURL: cache)
        defer { source.stop() }
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: source,
            database: database, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database), cacheURL: cache)
        model.start()
        try await waitFor { !model.isLoading }
        XCTAssertEqual(model.openSessions.sessionKnown("pruned"), false)
        XCTAssertNil(model.openSessions.sessionKnown("awaiting"))
        model.openSession(id: "awaiting")
        XCTAssertTrue(model.pendingSessionOpens.contains("awaiting"))
        let file = dir.appendingPathComponent("awaiting.jsonl")
        try "{".write(to: file, atomically: true, encoding: .utf8)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await waitFor { watcher.resolution(for: "awaiting") == .unreadable && model.pendingSessionOpens.isEmpty }
        XCTAssertNil(model.openSessions.sessionKnown("awaiting"))
        try #"{"type":"user","cwd":"/tmp/project","message":{"content":"late log"}}"#.write(to: file, atomically: true, encoding: .utf8)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await waitFor { model.openSessions.sessionKnown("awaiting") == true }
        XCTAssertTrue(model.openSessions.tabs.isEmpty, "A final failed open must not create a much later tab")

        model.openSession(id: "pruned")
        try await waitFor { model.pendingSessionOpens.isEmpty }
        XCTAssertTrue(model.openSessions.tabs.isEmpty)

    }

    func testLoadedMemberClicksPinsAndRenamesDoNotCommitJoins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("member.jsonl")
        try #"{"type":"user","cwd":"/tmp/project","message":{"content":"member"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "member", via: .opened, agent: .claude, transcriptPath: file)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let cache = root.appendingPathComponent("cache.json")
        let source = WatcherIndexSource(watcher: watcher, cacheURL: cache)
        defer { source.stop() }
        let overlay = SessionOverlayStore(db: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), indexSource: source,
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay, cacheURL: cache)
        model.start()
        try await waitFor { model.openSessions.sessionKnown("member") == true }
        let loadedResolution = watcher.resolution(for: "member")
        let unexpected = expectation(description: "Loaded actions must not trigger engine joins")
        unexpected.isInverted = true
        let observer = db.observeJoins { _, _ in unexpected.fulfill() }
        defer { db.removeJoinObserver(observer) }
        model.openSession(id: "member")
        overlay.togglePin("member")
        overlay.rename("member", to: "renamed")
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(try db.sessionState("member")?.customName, "renamed")
        XCTAssertEqual(watcher.resolution(for: "member"), loadedResolution)
    }

}
