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

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.titled, .closable], backing: .buffered, defer: true)
    }

    /// The prompt has to be answered while the window is still on screen. It used
    /// to run the other way round: AppKit closed the window, the quit then asked,
    /// and Cancel had no window to return to — SwiftUI tore the windowless scene
    /// down and exited anyway, so Cancel lost the work it offered to save.
    func testCancellingTheCloseKeepsTheWindow() {
        let interceptor = WindowCloseInterceptor(forwardingTo: nil, approveClose: { false })
        XCTAssertFalse(interceptor.windowShouldClose(makeWindow()))
    }

    func testApprovingTheCloseLetsTheWindowGo() {
        let interceptor = WindowCloseInterceptor(forwardingTo: nil, approveClose: { true })
        XCTAssertTrue(interceptor.windowShouldClose(makeWindow()))
    }

    /// One gesture, one question. Closing the window asks, and the termination
    /// that the approved close then starts must not ask the same thing again —
    /// the shipped version put the prompt up twice for a single click.
    func testCloseAsksOnceAndTheQuitItStartsDoesNotAskAgain() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        delegate.hasCancellableWindow = { true }
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))

        var prompts = 0
        delegate.confirmQuitWhileWorking = { _ in prompts += 1; return true }

        XCTAssertTrue(delegate.approveCloseForQuit(), "Quit lets the window close")
        XCTAssertEqual(prompts, 1)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(prompts, 1, "the close already asked")
    }

    /// Cancelling leaves nothing changed: no quit, and the next close asks again
    /// rather than reusing the earlier answer.
    func testCancelledCloseDoesNotBankAnApproval() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        delegate.hasCancellableWindow = { true }
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))

        var prompts = 0
        delegate.confirmQuitWhileWorking = { _ in prompts += 1; return false }
        XCTAssertFalse(delegate.approveCloseForQuit(), "window stays")
        XCTAssertFalse(model.openSessions.isQuitting)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(prompts, 2, "a later quit asks on its own account")
    }

    /// Whatever SwiftUI installed on the window keeps working — the interceptor
    /// answers one question and forwards the rest.
    func testInterceptorForwardsEverythingElseToSwiftUIsDelegate() {
        final class Recorder: NSObject, NSWindowDelegate {
            var didResize = false
            func windowDidResize(_ notification: Notification) { didResize = true }
        }
        let recorder = Recorder()
        let interceptor = WindowCloseInterceptor(forwardingTo: recorder, approveClose: { true })

        XCTAssertTrue(interceptor.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        (interceptor as NSWindowDelegate).windowDidResize?(
            Notification(name: NSWindow.didResizeNotification))
        XCTAssertTrue(recorder.didResize, "forwarded to the delegate we displaced")
    }

    /// If the window is somehow already gone, Cancel would be a lie: there is
    /// nothing to return to. Drain and quit rather than offer the choice.
    func testNoPromptWhenThereIsNoWindowToReturnTo() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        delegate.hasCancellableWindow = { false }
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))

        var asked = false
        delegate.confirmQuitWhileWorking = { _ in asked = true; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertFalse(asked)
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

        delegate.hasCancellableWindow = { true }
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
        delegate.hasCancellableWindow = { true }
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
