import XCTest
import TempleCore
@testable import TempleUI

/// ⌘K lists every member, including rows that never learned a folder. Return
/// on one used to dismiss the palette and do nothing.
@MainActor
final class PaletteDirectorylessTests: XCTestCase {
    func testADirectorylessRowOpensHistoryNarrowedToItAndAPlacedRowOpensATab() throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "dirless", via: .imported, agent: .claude, core: SessionCore(title: "Lost folder"))
        try db.join(sessionID: "placed", via: .imported, agent: .claude,
                    core: SessionCore(directory: "/p", title: "Lost and found"))
        let factory = FakeTerminalSurfaceFactory()
        let model = AppModel(surfaceFactory: factory,
                             indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                             database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                             hostRegistry: Fixture.hostsWithoutFolderEvidence())
        let results = model.paletteResults("Lost")
        let dirless = try XCTUnwrap(results.first { $0.id == "dirless" })
        let placed = try XCTUnwrap(results.first { $0.id == "placed" })
        XCTAssertFalse(model.canOpenFromPalette(dirless))
        XCTAssertTrue(model.canOpenFromPalette(placed))

        model.commandPalettePresented = true
        model.openPaletteResult(dirless)
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.history.query, "dirless")
        XCTAssertTrue(factory.created.isEmpty)

        model.commandPalettePresented = true
        model.openPaletteResult(placed)
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "placed")
        XCTAssertEqual(factory.created.count, 1)
    }
}
