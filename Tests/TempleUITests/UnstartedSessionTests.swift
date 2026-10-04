import XCTest
import TempleCore
@testable import TempleUI

/// ⌘T joins a Claude session the moment its id is minted. Closed before
/// anything was sent, the CLI never writes a transcript, and the row used to
/// stay as a permanent "New Claude session".
@MainActor
final class UnstartedSessionTests: XCTestCase {
    private func model(_ db: TempleDB) -> AppModel {
        AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                 indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                 database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                 hostRegistry: Fixture.hostsWithoutFolderEvidence())
    }

    func testAnAbandonedNewTabLeavesNoRowButAUsedOneStays() throws {
        let db = try TempleDB.inMemory()
        let app = model(db)
        let abandoned = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let used = app.openSessions.newSession(agent: .claude, projectPath: "/p")
        let abandonedID = try XCTUnwrap(abandoned.sessionID), usedID = try XCTUnwrap(used.sessionID)
        XCTAssertNotNil(try db.sessionState(abandonedID))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: [abandonedID: .awaitingCreation, usedID: .awaitingCreation], summaries: [:]))
        (abandoned.surface as? FakeTerminalSurface)?.simulateTitle("Claude Code")
        app.overlay.flushPendingTitles()
        (used.surface as? FakeTerminalSurface)?.simulateSubmitInput()

        app.openSessions.closeTab(abandoned.id)
        app.openSessions.closeTab(used.id)
        XCTAssertNil(try db.sessionState(abandonedID), "a title alone does not keep it")
        XCTAssertFalse(app.overlay.isTempleSession(abandonedID))
        XCTAssertNotNil(try db.sessionState(usedID), "something was sent: it stays")
        app.openSessions.reopenLastClosedTab()
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, usedID, "nothing to reopen for the unused tab")
    }

    func testARowIsKeptWhenATranscriptMayExistOrTheUserTouchedIt() throws {
        for keep in ["unresolved", "pinned"] {
            let db = try TempleDB.inMemory()
            let app = model(db)
            let tab = app.openSessions.newSession(agent: .claude, projectPath: "/p")
            let id = try XCTUnwrap(tab.sessionID)
            if keep == "pinned" {
                app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: [id: .awaitingCreation], summaries: [:]))
                app.overlay.togglePin(id)
            } else {
                app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: [id: .resolving], summaries: [:]))
            }
            app.openSessions.closeTab(tab.id)
            XCTAssertNotNil(try db.sessionState(id), keep)
        }
    }
}
