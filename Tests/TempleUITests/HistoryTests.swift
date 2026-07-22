import XCTest
@testable import TempleUI
import TempleCore

private struct HistoryNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { session.id == "noise" }
}

private struct HistoryNoNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

@MainActor
final class HistoryTests: XCTestCase {
    private func makeModel(_ index: SessionIndex,
                           noise: NoiseFilter = HistoryNoNoiseFilter()) -> (AppModel, SessionOverlayStore) {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(index),
            noiseFilter: noise,
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay
        )
        model.index = index
        return (model, overlay)
    }

    func testHistoryResultsSortAcrossProjectsByRecencyAndID() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [
                Fixture.session("old", project: "/p/a", updated: 10),
                Fixture.session("z-tie", project: "/p/a", updated: 30),
            ]),
            Project(path: "/p/b", sessions: [
                Fixture.session("a-tie", project: "/p/b", updated: 30),
                Fixture.session("middle", project: "/p/b", updated: 20),
            ]),
        ])
        let (model, _) = makeModel(index)

        XCTAssertEqual(model.historyResults("").map(\.id),
                       ["a-tie", "z-tie", "middle", "old"])
    }

    func testHistoryQueryRanksUsingOverlayDisplayTitles() {
        let renamed = Fixture.session("renamed", project: "/p/a", title: "Original title", updated: 10)
        let unrelated = Fixture.session("other", project: "/p/b", title: "Something else", updated: 20)
        let (model, overlay) = makeModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [renamed]),
            Project(path: "/p/b", sessions: [unrelated]),
        ]))
        overlay.rename("renamed", to: "Needle session")

        XCTAssertEqual(model.historyResults("needle").map(\.id), ["renamed"])
    }

    func testHistoryResultsRespectNoiseFilter() {
        let index = SessionIndex(projects: [
            Project(path: "/p", sessions: [
                Fixture.session("noise", project: "/p", updated: 20),
                Fixture.session("kept", project: "/p", updated: 10),
            ]),
        ])
        let (model, _) = makeModel(index, noise: HistoryNoiseFilter())

        XCTAssertEqual(model.historyResults("").map(\.id), ["kept"])
        XCTAssertTrue(model.historyResults("noise").isEmpty)
    }

    func testHistoryGroupingTitlesAndPreservesInputOrderWithinDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 7, 22, 18)
        let sessions = [
            Fixture.session("today-newer", project: "/p", updated: date(2026, 7, 22, 16).timeIntervalSince1970),
            Fixture.session("today-older", project: "/p", updated: date(2026, 7, 22, 9).timeIntervalSince1970),
            Fixture.session("yesterday", project: "/p", updated: date(2026, 7, 21).timeIntervalSince1970),
            Fixture.session("this-year", project: "/p", updated: date(2026, 7, 10).timeIntervalSince1970),
            Fixture.session("older-year", project: "/p", updated: date(2025, 12, 31).timeIntervalSince1970),
        ]

        let groups = HistoryGrouping.groups(sessions, calendar: calendar, now: now)

        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map(\.title),
                       ["Today", "Yesterday", "Friday, Jul 10", "Dec 31, 2025"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["today-newer", "today-older"])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.id), sessions.map(\.id))
    }

    func testHistoryAndPaletteTogglesAreMutuallyExclusiveBothDirections() {
        let (model, _) = makeModel(SessionIndex(projects: []))
        model.commandPalettePresented = true
        model.shortcutsPresented = true
        model.projectSwitcherPresented = true

        model.toggleHistory()

        XCTAssertTrue(model.historyPresented)
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertFalse(model.shortcutsPresented)
        XCTAssertFalse(model.projectSwitcherPresented)

        model.shortcutsPresented = true
        model.projectSwitcherPresented = true
        model.toggleCommandPalette()

        XCTAssertTrue(model.commandPalettePresented)
        XCTAssertFalse(model.historyPresented)
        XCTAssertFalse(model.shortcutsPresented)
        XCTAssertFalse(model.projectSwitcherPresented)

        // The shortcuts card is exclusive too — the native menu item and the
        // launcher row go through the same toggle as the key monitor.
        model.toggleShortcuts()
        XCTAssertTrue(model.shortcutsPresented)
        XCTAssertFalse(model.commandPalettePresented)
    }
}
