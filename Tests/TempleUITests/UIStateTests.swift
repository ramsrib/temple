import XCTest
import SwiftUI
@testable import TempleUI
import TempleCore

/// The sidebar's collapsed state is the one piece of window chrome a relaunch
/// used to throw away: `open_tabs` put the user back on the exact tab they left,
/// so the restore was invisible except for the sidebar reappearing. It read as
/// the app toggling itself open.
@MainActor
final class UIStateTests: XCTestCase {
    private func makeModel(db: TempleDB) -> AppModel {
        AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                 indexSource: FakeIndexSource(SessionIndex(projects: [])),
                 database: db,
                 settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                 overlay: SessionOverlayStore(db: db))
    }

    func testCollapsedSidebarSurvivesRelaunch() throws {
        let db = try TempleDB.inMemory()
        let first = makeModel(db: db)
        XCTAssertEqual(first.sidebarVisibility, .all)   // shipped default

        first.sidebarVisibility = .detailOnly

        // Same store, fresh model — what the next launch sees.
        XCTAssertEqual(makeModel(db: db).sidebarVisibility, .detailOnly)
    }

    /// Deliberately starts from a PERSISTED collapsed state. Written the naive
    /// way — collapse, reopen, reload — this test passes against the old
    /// in-memory-only property too, because `.detailOnly → .all` lands on the
    /// same `.all` the shipped default would have produced.
    func testReopeningTheSidebarReplacesTheStoredCollapse() throws {
        let db = try TempleDB.inMemory()
        try db.setUIState("detailOnly", for: UIStateStore.Key.sidebarVisibility)

        let model = makeModel(db: db)
        XCTAssertEqual(model.sidebarVisibility, .detailOnly)
        model.sidebarVisibility = .all

        XCTAssertEqual(try db.uiState(UIStateStore.Key.sidebarVisibility), "all")
        XCTAssertEqual(makeModel(db: db).sidebarVisibility, .all)
    }

    /// Restoring in `init` must not write itself back — a property observer that
    /// fired there would persist the shipped default over an unset key, turning
    /// "defer to the default" into a stored decision.
    func testRestoreDoesNotSeedTheKey() throws {
        let db = try TempleDB.inMemory()
        _ = makeModel(db: db)
        XCTAssertNil(try db.uiState(UIStateStore.Key.sidebarVisibility))
    }

    /// Every shown visibility persists as shown. The mapping cannot be finer:
    /// `==` on this type compares `kind` alone, so `.automatic` and
    /// `.doubleColumn` are equal to each other and "SwiftUI has not been told"
    /// is indistinguishable from "both columns, deliberately". Both render a
    /// shown sidebar, so both round-trip to `.all` rather than being dropped.
    func testEveryShownVisibilityPersistsAsShown() throws {
        for shown in [NavigationSplitViewVisibility.all, .doubleColumn, .automatic] {
            let db = try TempleDB.inMemory()
            let store = UIStateStore(db: db)
            store.setSidebarVisibility(.detailOnly)
            store.setSidebarVisibility(shown)

            XCTAssertEqual(try db.uiState(UIStateStore.Key.sidebarVisibility), "all")
            XCTAssertEqual(store.sidebarVisibility, .all)
        }
    }

    /// The toggle both ⌘B sites use. Written as `== .all ? .detailOnly : .all`
    /// it assigns `.all` to an already-visible `.doubleColumn` sidebar — one
    /// press that visibly does nothing.
    func testEveryShownVisibilityCountsAsShown() {
        for shown in [NavigationSplitViewVisibility.all, .doubleColumn, .automatic] {
            XCTAssertFalse(shown.isSidebarHidden)
        }
        XCTAssertTrue(NavigationSplitViewVisibility.detailOnly.isSidebarHidden)
    }

    /// ⌘B, through the method both call sites now share. Reverting either site
    /// to its own inline `== .all` ternary used to leave every test green.
    func testToggleSidebarClosesFromEveryShownVisibility() throws {
        for shown in [NavigationSplitViewVisibility.all, .doubleColumn, .automatic] {
            let model = makeModel(db: try TempleDB.inMemory())
            model.sidebarVisibility = shown
            model.toggleSidebar()
            XCTAssertEqual(model.sidebarVisibility, .detailOnly)
            model.toggleSidebar()
            XCTAssertEqual(model.sidebarVisibility, .all)
        }
    }

    func testTogglePersistsEachPress() throws {
        let db = try TempleDB.inMemory()
        let model = makeModel(db: db)
        model.toggleSidebar()
        XCTAssertEqual(try db.uiState(UIStateStore.Key.sidebarVisibility), "detailOnly")
        model.toggleSidebar()
        XCTAssertEqual(try db.uiState(UIStateStore.Key.sidebarVisibility), "all")
    }

    func testUnrecognisedStoredValueFallsBackToTheDefault() throws {
        let db = try TempleDB.inMemory()
        try db.setUIState("sideways", for: UIStateStore.Key.sidebarVisibility)
        XCTAssertNil(UIStateStore(db: db).sidebarVisibility)
        XCTAssertEqual(makeModel(db: db).sidebarVisibility, .all)
    }
}
