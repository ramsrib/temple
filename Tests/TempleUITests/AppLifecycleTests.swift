import AppKit
import XCTest
@testable import TempleUI
import TempleCore

/// Closing the window quits (the window IS the app), so the quit gate now stands
/// between a stray click on the red button and a working agent.
@MainActor
final class AppLifecycleTests: XCTestCase {
    func testWindowlessLaunchRequestsThePrimaryWindowOnlyOnce() {
        let delegate = TempleAppDelegate()
        var requests = 0
        delegate.openInitialWindow = { requests += 1 }

        delegate.presentInitialWindowIfNeeded(windows: [])
        delegate.presentInitialWindowIfNeeded(windows: [])

        XCTAssertEqual(requests, 1)
        XCTAssertNil(delegate.openInitialWindow)
        XCTAssertNil(delegate.model, "the failure screen needs no AppModel")
    }

    func testHiddenPrimaryWindowDoesNotCreateADuplicateOnLaunch() {
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }
        XCTAssertFalse(window.isVisible)
        let delegate = TempleAppDelegate()
        var requests = 0
        delegate.openInitialWindow = { requests += 1 }

        delegate.presentInitialWindowIfNeeded(windows: [window])
        delegate.presentInitialWindowIfNeeded(windows: [])

        XCTAssertEqual(requests, 0)
        XCTAssertNil(delegate.openInitialWindow)
    }

    func testAuxiliaryPanelDoesNotPreventThePrimaryWindowOpening() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let delegate = TempleAppDelegate()
        var requests = 0
        delegate.openInitialWindow = { requests += 1 }

        delegate.presentInitialWindowIfNeeded(windows: [panel])

        XCTAssertEqual(requests, 1)
    }

    private func makeModel() -> AppModel {
        AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                 indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])),
                 database: try! TempleDB.inMemory(),
                 settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
    }

    func testImmediateDelegateQuitFlushesPendingTouches() throws {
        let db = try TempleDB.inMemory()
        let at = Date(timeIntervalSince1970: 100)
        var cancelled = false
        let overlay = SessionOverlayStore(db: db, now: { at }, scheduleTouch: { _, _ in
            return { cancelled = true }
        })
        overlay.join("a", via: .created)
        overlay.touch("a")
        overlay.recordGeneratedTitle("Pending", for: "a")
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])), database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay)
        let delegate = TempleAppDelegate()
        delegate.model = model
        XCTAssertNil(try db.sessionState("a")?.lastActiveAt)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(try db.sessionState("a")?.lastActiveAt, at)
        XCTAssertEqual(try db.sessionState("a")?.title, "Pending")
        XCTAssertTrue(cancelled)
        XCTAssertTrue(model.openSessions.isQuitting)
    }

    func testDrainingDelegateQuitRejectsLateAdoptionActivityAndFinallyFlushesTouches() async throws {
        let db = try TempleDB.inMemory()
        let at = Date(timeIntervalSince1970: 4_000_000_000)
        let overlay = SessionOverlayStore(db: db, now: { at }, scheduleTouch: { _, _ in {} })
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])), database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay)
        let tab = model.openSessions.newSession(agent: .codex, projectPath: NSTemporaryDirectory())
        let surface = try XCTUnwrap(tab.surface as? FakeTerminalSurface)
        overlay.join("known", via: .created)
        overlay.touch("known")
        XCTAssertNil(try db.sessionState("known")?.lastActiveAt)
        surface.onGracefulExit = { [weak model] in
            XCTAssertTrue(model?.openSessions.isQuitting == true)
            XCTAssertEqual(try? db.sessionState("known")?.lastActiveAt, at, "initial flush precedes drain")
            model?.openSessions.adopt(sessionID: "late-codex", for: tab.id)
            // Simulate a store write already queued at the initial flush barrier.
            overlay.touch("known", at: at.addingTimeInterval(1))
        }
        let delegate = TempleAppDelegate()
        delegate.model = model
        delegate.confirmQuitWhileWorking = { _ in true }
        let completed = expectation(description: "termination replies after final flush")
        var returned = false
        delegate.replyToTermination = { reply in
            XCTAssertTrue(reply)
            XCTAssertTrue(returned)
            XCTAssertEqual(try? db.sessionState("known")?.lastActiveAt, at.addingTimeInterval(1))
            XCTAssertNil(try? db.sessionState("late-codex")?.lastActiveAt)
            XCTAssertNil(overlay.lastActiveAt["late-codex"])
            completed.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        returned = true
        XCTAssertEqual(try db.sessionState("known")?.lastActiveAt, at)
        XCTAssertNotNil(try db.sessionState("late-codex"))
        XCTAssertEqual(try db.sessionState("late-codex")?.directory, NSTemporaryDirectory())
        await fulfillment(of: [completed], timeout: 5)
        surface.onGracefulExit = nil
    }

    func testClosingTheLastWindowQuits() {
        let delegate = TempleAppDelegate()
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        // Closing one of these for real is the point of the tests below, and the
        // AppKit default would then over-release it under the test's own ref.
        window.isReleasedWhenClosed = false
        return window
    }

    /// The prompt has to be answered while the window is still on screen. It used
    /// to run the other way round: AppKit closed the window, the quit then asked,
    /// and Cancel had no window to return to — SwiftUI tore the windowless scene
    /// down and exited anyway, so Cancel lost the work it offered to save.
    func testCancellingTheCloseKeepsTheWindow() {
        let interceptor = WindowCloseInterceptor(forwardingTo: nil, approveClose: { _ in false })
        XCTAssertFalse(interceptor.windowShouldClose(makeWindow()))
    }

    func testApprovingTheCloseLetsTheWindowGo() {
        let interceptor = WindowCloseInterceptor(forwardingTo: nil, approveClose: { _ in true })
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
        let interceptor = WindowCloseInterceptor(forwardingTo: recorder, approveClose: { _ in true })

        XCTAssertTrue(interceptor.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        (interceptor as NSWindowDelegate).windowDidResize?(
            Notification(name: NSWindow.didResizeNotification))
        XCTAssertTrue(recorder.didResize, "forwarded to the delegate we displaced")
    }

    /// A minimized or ⌘H-hidden Temple must still ask. The first fix gated the
    /// prompt on a window being *visible*, which is false in both of those
    /// states — so quitting from the Dock killed a working agent in silence.
    func testHiddenWindowStillAsksBeforeQuitting() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))

        // Hidden or minimized: the window still exists, so it is still tracked.
        delegate.hasCancellableWindow = { true }
        var asked = false
        delegate.confirmQuitWhileWorking = { _ in asked = true; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertTrue(asked, "off-screen is not gone — the warning still applies")
    }

    /// The other side of it: a window that has genuinely gone (something bypassed
    /// the interceptor with a direct `close()`) must not be offered a Cancel that
    /// cannot put it back. That was the v0.1.13 lie.
    func testNoPromptOnceTheWindowIsActuallyGone() {
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

    /// The close button is the thing under test, not the closure behind it: press
    /// it for real and assert the window survives. Every earlier test here passed
    /// against an interceptor that was never installed on a window at all.
    func testPressingCloseWithWorkRunningLeavesTheWindowOpen() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        delegate.confirmQuitWhileWorking = { _ in false }

        let window = makeWindow()
        window.delegate = WindowCloseInterceptor(forwardingTo: window.delegate) { closing in
            delegate.approveCloseForQuit(closing)
        }
        window.makeKeyAndOrderFront(nil)
        window.performClose(nil)

        XCTAssertTrue(window.isVisible, "Cancel must leave the window exactly where it was")
    }

    func testPressingCloseAfterApprovalLetsTheWindowGo() {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        delegate.confirmQuitWhileWorking = { _ in true }

        let window = makeWindow()
        window.delegate = WindowCloseInterceptor(forwardingTo: window.delegate) { closing in
            delegate.approveCloseForQuit(closing)
        }
        window.makeKeyAndOrderFront(nil)
        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
    }

    /// An approved close that does not go on to terminate (a second window) must
    /// not bank its "yes" for a later, unrelated quit.
    func testApprovalDoesNotSurviveIntoAnUnrelatedQuit() async {
        let delegate = TempleAppDelegate()
        let model = makeModel()
        delegate.model = model
        delegate.hasCancellableWindow = { true }
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))

        var prompts = 0
        delegate.confirmQuitWhileWorking = { _ in prompts += 1; return true }
        XCTAssertTrue(delegate.approveCloseForQuit(makeWindow()))
        XCTAssertEqual(prompts, 1)

        // The close never became a termination; let the run loop turn over.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(prompts, 2, "the later quit asks on its own account")
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
        delegate.hasCancellableWindow = { true }
        delegate.hasCancellableWindow = { true }
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
        delegate.hasCancellableWindow = { true }
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
        delegate.hasCancellableWindow = { true }
        model.openSessions.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSessions.tabs.first?.activity = .idle

        var asked = false
        delegate.confirmQuitWhileWorking = { _ in asked = true; return true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertFalse(asked)
    }
}
