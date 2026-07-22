import XCTest
@testable import TempleUI
import TempleCore

/// The generated-title coalescer (sidebar-lag fix): live retitles batch into
/// one publish + DB write per window, without regressing to a stale
/// intermediate or losing the final title at quit.
@MainActor
final class OverlayTitleCoalescingTests: XCTestCase {

    private func store() -> SessionOverlayStore {
        SessionOverlayStore(db: try! TempleDB.inMemory())
    }

    func testCustomNameSetOverwriteClearAndReload() throws {
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)

        overlay.rename("s", to: "First name")
        XCTAssertEqual(overlay.customName(for: "s"), "First name")

        overlay.rename("s", to: "Replacement name")
        XCTAssertEqual(overlay.customName(for: "s"), "Replacement name")
        XCTAssertEqual(SessionOverlayStore(db: db).customName(for: "s"), "Replacement name")

        overlay.rename("s", to: "")
        XCTAssertNil(overlay.customName(for: "s"))
        XCTAssertNil(SessionOverlayStore(db: db).customName(for: "s"))
    }

    func testTitleReturningToPublishedValueDropsStaleIntermediate() async {
        let overlay = store()
        overlay.titleFlushDelay = 0.05
        overlay.recordGeneratedTitle("Ready", for: "s")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Ready")

        // Both land inside one flush window; the flush must not regress to
        // the intermediate.
        overlay.recordGeneratedTitle("Thinking", for: "s")
        overlay.recordGeneratedTitle("Ready", for: "s")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Ready")
    }

    func testLatestTitleInAWindowWins() async {
        let overlay = store()
        overlay.titleFlushDelay = 0.05
        overlay.recordGeneratedTitle("One", for: "s")
        overlay.recordGeneratedTitle("Two", for: "s")
        overlay.recordGeneratedTitle("Three", for: "s")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Three")
    }

    func testFlushPendingTitlesPublishesImmediately() {
        let overlay = store()
        overlay.titleFlushDelay = 60  // far beyond the test's lifetime
        overlay.recordGeneratedTitle("Final", for: "s")
        overlay.flushPendingTitles()  // the quit path
        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Final")
    }

    func testTitlesRecordedAfterAFlushStillSchedule() async {
        let overlay = store()
        overlay.titleFlushDelay = 0.05
        overlay.recordGeneratedTitle("One", for: "s")
        overlay.flushPendingTitles()
        overlay.recordGeneratedTitle("Two", for: "s")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(overlay.generatedTitle(for: "s"), "Two")
    }
}
