import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

/// Find-in-terminal (⌘F): the tab-side model and its wiring to the surface.
@MainActor
final class TerminalFindTests: XCTestCase {

    private func makeFind() -> (TerminalFindModel, FakeTerminalSurface) {
        let surface = FakeTerminalSurface()
        let find = TerminalFindModel()
        find.surface = surface
        return (find, surface)
    }

    func testOpenPresentsAndAsksForFocusOnce() {
        let (find, _) = makeFind()
        XCTAssertFalse(find.isPresented)

        find.open()

        XCTAssertTrue(find.isPresented)
        XCTAssertTrue(find.consumeFocusRequest())
        // A bar rebuilt by a tab switch must not take the keyboard again.
        XCTAssertFalse(find.consumeFocusRequest())
    }

    func testOpenAgainRefocusesWithoutClosing() {
        let (find, _) = makeFind()
        find.open()
        _ = find.consumeFocusRequest()
        let token = find.focusToken

        find.open()

        XCTAssertTrue(find.isPresented)
        XCTAssertNotEqual(find.focusToken, token)
        XCTAssertTrue(find.consumeFocusRequest())
    }

    func testLongNeedleSearchesImmediately() {
        let (find, surface) = makeFind()
        find.open()

        find.needle = "abc"

        XCTAssertEqual(surface.searches, ["abc"])
    }

    func testShortNeedleWaitsForTypingToPause() async throws {
        let (find, surface) = makeFind()
        find.open()

        find.needle = "a"
        find.needle = "ab"
        XCTAssertEqual(surface.searches, [], "one- and two-character needles are debounced")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(surface.searches, ["ab"], "only the latest short needle is searched")
    }

    func testTypingPastTheDebounceCancelsThePendingShortSearch() async throws {
        let (find, surface) = makeFind()
        find.open()

        find.needle = "ab"
        find.needle = "abc"
        XCTAssertEqual(surface.searches, ["abc"])

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(surface.searches, ["abc"], "the debounced \"ab\" must not land after \"abc\"")
    }

    func testClearingTheNeedleClearsHighlightsAndCounts() {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "abc"
        find.surfaceDidUpdate(total: 4)
        find.surfaceDidUpdate(selected: 1)

        find.needle = ""

        XCTAssertEqual(surface.searches, ["abc", ""])
        XCTAssertNil(find.total)
        XCTAssertNil(find.selected)
    }

    func testCountsComeFromTheSurface() {
        let (find, _) = makeFind()
        find.open()
        find.needle = "abc"

        find.surfaceDidUpdate(total: 12)
        find.surfaceDidUpdate(selected: 2)

        XCTAssertEqual(find.total, 12)
        XCTAssertEqual(find.selected, 2)
    }

    func testNextAndPreviousDriveTheSurface() {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "abc"

        find.next()
        find.previous()

        XCTAssertEqual(surface.navigations, [.next, .previous])
    }

    func testCloseEndsTheSearchAndReturnsTheKeyboardToTheTerminal() {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "abc"
        find.surfaceDidUpdate(total: 3)

        find.close()

        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(find.needle, "")
        XCTAssertNil(find.total)
        XCTAssertEqual(surface.endSearchCount, 1)
        XCTAssertEqual(surface.focusCount, 1)
        // Resetting the needle is not a search for "".
        XCTAssertEqual(surface.searches, ["abc"])
    }

    func testSurfaceEndingTheSearchHidesTheBarWithoutEchoing() {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "abc"

        // Esc in a focused terminal: libghostty ended the search itself.
        find.surfaceDidEnd()

        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(find.needle, "")
        XCTAssertEqual(surface.endSearchCount, 0, "already ended on the terminal's side")
        XCTAssertEqual(surface.focusCount, 0, "the terminal already has the keyboard")
    }

    func testSurfaceStartingASearchPresentsWithItsNeedle() {
        let (find, surface) = makeFind()

        // ⌘E inside the terminal: search_selection already ran the search.
        find.surfaceDidStart(needle: "selected text")

        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(find.needle, "selected text")
        XCTAssertEqual(surface.searches, [], "a needle from the surface is not searched twice")
        XCTAssertTrue(find.consumeFocusRequest())
    }

    func testSurfaceStartingWithoutANeedleJustOpens() {
        let (find, surface) = makeFind()
        find.surfaceDidStart(needle: nil)

        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(find.needle, "")
        XCTAssertEqual(surface.searches, [])
    }

    func testChangingTheNeedleDropsTheOldCountsAtOnce() {
        let (find, _) = makeFind()
        find.open()
        find.needle = "abc"
        find.surfaceDidUpdate(total: 12)
        find.surfaceDidUpdate(selected: 2)

        find.needle = "abcd"

        XCTAssertNil(find.total, "the count belonged to \"abc\"; the terminal has not answered for \"abcd\" yet")
        XCTAssertNil(find.selected)
    }

    func testCloseCancelsAPendingShortSearch() async throws {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "ab"

        find.close()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(surface.searches, [], "a debounced needle must not be searched after the bar closed")
        XCTAssertEqual(surface.endSearchCount, 1)
    }

    func testSurfaceStartingASearchCancelsAPendingShortSearch() async throws {
        let (find, surface) = makeFind()
        find.open()
        find.needle = "ab"

        // ⌘E in the terminal, while "ab" is still waiting out its debounce.
        find.surfaceDidStart(needle: "selected text")
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(find.needle, "selected text")
        XCTAssertEqual(surface.searches, [], "the stale \"ab\" must not replace the terminal's own needle")
    }

    // MARK: Wiring through OpenSessionsModel

    func testSurfaceSearchEventsReachTheTabsFindModel() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tab = model.activeTab!
        let surface = factory.created[0]

        surface.simulateSearchStarted(needle: "foo")
        surface.simulateSearchTotal(7)
        surface.simulateSearchSelected(3)

        XCTAssertTrue(tab.find.isPresented)
        XCTAssertEqual(tab.find.needle, "foo")
        XCTAssertEqual(tab.find.total, 7)
        XCTAssertEqual(tab.find.selected, 3)

        surface.simulateSearchEnded()
        XCTAssertFalse(tab.find.isPresented)
    }

    func testTabsFindModelDrivesItsOwnSurface() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        let tabA = model.tabs.first { $0.sessionID == "a" }!

        tabA.find.open()
        tabA.find.needle = "needle"

        XCTAssertEqual(factory.created[0].searches, ["needle"])
        XCTAssertEqual(factory.created[1].searches, [], "each tab searches only its own terminal")
    }
}
