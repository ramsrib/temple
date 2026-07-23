import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class UsageMeterTests: XCTestCase {
    private func claude(fiveHour: Double? = nil, weekly: Double? = nil,
                        scoped: [ScopedUsage] = [], credits: Double? = nil) -> ClaudeUsage {
        ClaudeUsage(plan: "team",
                    fiveHour: fiveHour.map(UsageWindow.init),
                    weekly: weekly.map(UsageWindow.init),
                    scoped: scoped, creditsPct: credits)
    }

    func testHeadlineIsTheMostConstrainedWindow() async {
        let model = UsageMeterModel()
        let claudeReading = claude(fiveHour: 48, weekly: 38,
                                   scoped: [ScopedUsage(label: "Fable", pct: 54)])
        model.claudeFetch = { claudeReading }
        model.codexFetch = {
            CodexUsage(plan: "pro", capturedAt: nil,
                       fiveHour: UsageWindow(pct: 31), weekly: UsageWindow(pct: 17))
        }
        await model.refreshNow()

        XCTAssertEqual(model.claudeHeadlinePct, 54)   // the scoped cap is the wall
        XCTAssertEqual(model.codexHeadlinePct, 31)
        XCTAssertTrue(model.breakdown.contains("Fable 54%"))
        XCTAssertTrue(model.breakdown.contains("Claude (team)"))
    }

    func testNoReadersMeansNoMeter() async {
        let model = UsageMeterModel()
        model.claudeFetch = { nil }
        model.codexFetch = { nil }
        await model.refreshNow()

        XCTAssertNil(model.claudeHeadlinePct)
        XCTAssertNil(model.codexHeadlinePct)
        XCTAssertNil(model.updatedAt)
    }

    func testTransientFailureKeepsTheLastGoodReading() async {
        let model = UsageMeterModel()
        let claudeReading = claude(fiveHour: 48)
        model.claudeFetch = { claudeReading }
        model.codexFetch = { nil }
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)

        model.claudeFetch = { nil }   // endpoint hiccup on the next poll
        await model.refreshNow()
        XCTAssertEqual(model.claudeHeadlinePct, 48)
    }

    func testOneProviderAloneStillShows() async {
        let model = UsageMeterModel()
        model.claudeFetch = { nil }
        model.codexFetch = {
            CodexUsage(plan: "pro", capturedAt: nil, fiveHour: nil,
                       weekly: UsageWindow(pct: 17))
        }
        await model.refreshNow()

        XCTAssertNil(model.claudeHeadlinePct)
        XCTAssertEqual(model.codexHeadlinePct, 17)
        XCTAssertTrue(model.breakdown.contains("Codex (pro): weekly 17%"))
    }
}
