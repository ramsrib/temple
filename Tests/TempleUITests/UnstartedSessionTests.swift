import XCTest
import TempleCore
@testable import TempleUI

/// ⌘T joins a Claude session the moment its id is minted. Closed before
/// anything was sent, the CLI never writes a transcript, and the row used to
/// stay as a permanent "New Claude session". It may go only on a fresh,
/// completed absence; anything less keeps it.
@MainActor
final class UnstartedSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-unstarted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// `storeRoot` is the Claude store; pass a regular file to make every
    /// listing fail.
    private func model(_ db: TempleDB, storeRoot: URL) -> AppModel {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: storeRoot)], debounceInterval: 0.01,
                                        monitorChanges: false)
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                           indexSource: WatcherIndexSource(engines: [SessionEngine(source: source, database: db)]),
                           database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        return app
    }

    private func settle(_ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(3)
        while try !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Give a refused discard every chance to (wrongly) happen.
    private func quiesce() async { try? await Task.sleep(for: .milliseconds(300)) }

    func testAnAbandonedNewTabLeavesNoRowButAUsedOneStays() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let abandoned = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let used = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let abandonedID = try XCTUnwrap(abandoned.sessionID), usedID = try XCTUnwrap(used.sessionID)
        (abandoned.surface as? FakeTerminalSurface)?.simulateTitle("Claude Code")
        app.overlay.flushPendingTitles()
        (used.surface as? FakeTerminalSurface)?.simulateSubmitInput()

        app.openSessions.closeTab(abandoned.id)
        app.openSessions.closeTab(used.id)
        try await settle { try db.sessionState(abandonedID) == nil }
        XCTAssertNil(try db.sessionState(abandonedID), "a title alone does not keep it")
        XCTAssertFalse(app.overlay.isTempleSession(abandonedID))
        XCTAssertNotNil(try db.sessionState(usedID), "something was sent: it stays")
        app.openSessions.reopenLastClosedTab()
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, usedID)
        app.openSessions.closeTab(try XCTUnwrap(app.openSessions.activeTab).id)
        app.openSessions.reopenLastClosedTab()
        app.openSessions.reopenLastClosedTab()
        XCTAssertNotEqual(app.openSessions.activeTab?.sessionID, abandonedID, "nothing to reopen for a discarded row")
    }

    /// A listing that fails proves nothing, whatever the snapshot said.
    func testAFailedScanKeepsTheRow() async throws {
        let notADirectory = root.appendingPathComponent("claude")
        try Data().write(to: notADirectory)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: notADirectory)
        let tab = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let id = try XCTUnwrap(tab.sessionID)
        app.receiveEngineSnapshot(EngineSnapshot(generation: .max, resolutions: [id: .awaitingCreation], summaries: [:]))
        app.openSessions.closeTab(tab.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id))
    }

    /// The published verdict is old: the transcript appeared after it, with
    /// no event to say so. The fresh walk finds it.
    func testAStaleAbsenceKeepsTheRowWhoseTranscriptExistsNow() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let tab = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let id = try XCTUnwrap(tab.sessionID)
        // Let the engine publish its verdict from the empty listing first.
        await quiesce()
        let project = store.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/p\",\"message\":{\"content\":\"Hi\"}}\n"
            .write(to: project.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        app.openSessions.closeTab(tab.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(id))
    }

    func testARowTheUserTouchedOrThatHasATranscriptPathIsKept() async throws {
        let store = root.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let db = try TempleDB.inMemory()
        let app = model(db, storeRoot: store)
        let pinned = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let pinnedID = try XCTUnwrap(pinned.sessionID)
        app.overlay.togglePin(pinnedID)
        app.openSessions.closeTab(pinned.id)
        await quiesce()
        XCTAssertNotNil(try db.sessionState(pinnedID))
        // Unused, but kept: it still reopens.
        app.openSessions.reopenLastClosedTab()
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, pinnedID)

        try db.join(sessionID: "hinted", via: .created, agent: .claude,
                    transcriptPath: URL(fileURLWithPath: "/gone/hinted.jsonl"))
        XCTAssertFalse(try db.discardUnstartedCreation(sessionID: "hinted"))
        XCTAssertNotNil(try db.sessionState("hinted"))
    }
}
