import XCTest
@testable import TempleUI
@testable import TempleCore
import CoreServices

@MainActor
final class CoreWiringTests: XCTestCase {
    private var engines: [SessionEngine] = []

    override func tearDown() async throws {
        for engine in engines { await engine.stop() }
        engines.removeAll()
        try await super.tearDown()
    }

    private func tracked(_ engine: SessionEngine) -> SessionEngine { engines.append(engine); return engine }

    func testTheEngineDeliversAFilesystemUpdateIntoAppModel() async throws { try await exerciseWiring(injectEvents: false) }
    func testTheEngineDeliversAnInjectedUpdateIntoAppModel() async throws { try await exerciseWiring(injectEvents: true) }

    private func exerciseWiring(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-watcher-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Isolate the startup cache: never read or overwrite the developer's
        // real ~/Library/Application Support cache from a test.
        let database = try TempleDB.inMemory()
        let watcher = tracked(SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.05), database: database))
        try database.join(sessionID: "wired-session", via: .created, agent: .claude,
                          core: SessionCore(directory: "/tmp/project"))
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [watcher],
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
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")

        if injectEvents {
            model.openSession(id: "wired-session")
            XCTAssertEqual(model.openSessions.activeTab?.sessionID, "wired-session", "Row opens before the transcript exists")
        }
        let file = projectDirectory.appendingPathComponent("wired-session.jsonl")
        let json = #"{"sessionId":"wired-session","type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        try json.write(to: file, atomically: true, encoding: .utf8)
        if injectEvents { watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated)) }

        let updateDeadline = Date().addingTimeInterval(5)
        while !model.sessions.contains(where: { $0.id == "wired-session" }),
              Date() < updateDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.sessions.contains(where: { $0.id == "wired-session" }))
        if injectEvents { XCTAssertEqual(model.openSessions.activeTab?.sessionID, "wired-session") }
        // The engine's facts reach the row through the overlay's persister.
        let filled = Date().addingTimeInterval(5)
        while (try? database.sessionState("wired-session")?.title) == nil, Date() < filled {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try database.sessionState("wired-session")?.title, "hello")
        XCTAssertEqual(try database.sessionState("wired-session")?.transcriptPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       file.resolvingSymlinksInPath().path)
    }

    func testCodexAdopterAdoptsFixtureRolloutThroughTheHostSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hosts = HostRegistry(entries: [.init(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.05),
                                                 launcher: LocalHostLauncher(folderEvidence: { _ in .unknown }))])
        let reconciler = CodexAdopter(registry: hosts, window: 3)
        let adopted = expectation(description: "adopted Codex session id")
        let launch = Date()
        let sessionID = UUID().uuidString.lowercased()
        reconciler.reconcile(host: .local, projectPath: "/tmp/project", startedAt: launch) { id, locator in
            XCTAssertEqual(id, sessionID)
            XCTAssertEqual(locator?.localURL?.lastPathComponent, "rollout-2026-07-10T00-00-00-\(sessionID).jsonl")
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

    func testEngineSetReplaysTheLatestMergeAndStopClearsIt() async throws {
        let engine = FakeEngine(snapshot: EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent]))
        let set = EngineSet(engines: [engine])
        set.owner = { _ in .local }
        var received = 0
        set.start { _ in received += 1 }
        try await waitFor { received == 1 }
        var replayed = 0
        set.start { _ in replayed += 1 }
        XCTAssertEqual(replayed, 1, "a later registration synchronously replays the latest merge")
        set.stop()
        XCTAssertNil(set.latest)
        var afterStop = 0
        set.start { _ in afterStop += 1 }
        XCTAssertEqual(afterStop, 0, "a stopped merge is not replayed")
        try await waitFor { afterStop == 1 }
    }

    func testAppModelUsesSnapshotResolutionAndDoesNotQueueDirectorylessRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try TempleDB.inMemory()
        try database.join(sessionID: "pruned", via: .created, agent: .claude)
        let watcher = tracked(SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02), database: database))
        try database.join(sessionID: "awaiting", via: .created, agent: .claude)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [watcher],
            database: database, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database))
        model.start()
        try await waitFor { !model.isLoading }
        XCTAssertEqual(model.openSessions.sessionKnown("pruned"), false)
        XCTAssertNil(model.openSessions.sessionKnown("awaiting"))
        model.openSession(id: "awaiting")
        XCTAssertTrue(model.openSessions.tabs.isEmpty)
        let file = dir.appendingPathComponent("awaiting.jsonl")
        try "{".write(to: file, atomically: true, encoding: .utf8)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await waitFor { watcher.resolution(for: "awaiting") == .incomplete }
        XCTAssertNil(model.openSessions.sessionKnown("awaiting"))
        try #"{"sessionId":"awaiting","type":"user","cwd":"/tmp/project","message":{"content":"late log"}}"#.write(to: file, atomically: true, encoding: .utf8)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await waitFor { model.openSessions.sessionKnown("awaiting") == true }
        XCTAssertTrue(model.openSessions.tabs.isEmpty, "A final failed open must not create a much later tab")

        model.openSession(id: "pruned")
        XCTAssertTrue(model.openSessions.tabs.isEmpty)

    }

    func testLoadedMemberClicksPinsAndRenamesDoNotCommitJoins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("member.jsonl")
        try #"{"sessionId":"member","type":"user","cwd":"/tmp/project","message":{"content":"member"}}"#.write(to: file, atomically: true, encoding: .utf8)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "member", via: .opened, agent: .claude, locator: TranscriptLocator(localURL: file))
        let watcher = tracked(SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02), database: db))
        let overlay = SessionOverlayStore(db: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [watcher],
            database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay)
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
