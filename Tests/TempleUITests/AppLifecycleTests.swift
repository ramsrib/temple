import AppKit
import XCTest
@testable import TempleUI
import TempleCore

/// Closing the window quits (the window IS the app), so the quit gate now stands
/// between a stray click on the red button and a working agent.
@MainActor
final class AppLifecycleTests: XCTestCase {
    private func makeModel() -> AppModel {
        AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                 indexSource: FakeIndexSource(SessionIndex(projects: [])),
                 database: try! TempleDB.inMemory(),
                 settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
    }

    func testClosingTheLastWindowQuits() {
        let delegate = TempleAppDelegate()
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testQuitWithNoAgentsDoesNotAsk() {
        let delegate = TempleAppDelegate()
        delegate.model = makeModel()
        var asked = false
        delegate.confirmQuitWhileWorking = { _ in asked = true; return true }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertFalse(asked)
    }

    func testQuitAsksWhileAnAgentIsWorkingAndCancelStopsIt() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        XCTAssertEqual(model.openSessions.workingTabs.count, 1)

        var workingCount = 0
        delegate.confirmQuitWhileWorking = { workingCount = $0; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(workingCount, 1)
        XCTAssertFalse(model.openSessions.isQuitting, "a cancelled quit must not freeze the tab set")
    }

    func testConfirmedQuitDrainsInsteadOfTerminatingImmediately() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        delegate.confirmQuitWhileWorking = { _ in true }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(model.openSessions.isQuitting)
    }

    /// An idle session is not worth interrupting for: it resumes from disk with
    /// nothing lost, so only a mid-task agent earns the prompt.
    func testIdleSessionQuitsWithoutAsking() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSessions.tabs.first?.activity = .idle

        var asked = false
        delegate.confirmQuitWhileWorking = { _ in asked = true; return true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertFalse(asked)
    }
}
