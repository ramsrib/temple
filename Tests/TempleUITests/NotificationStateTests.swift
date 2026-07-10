import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class NotificationStateTests: XCTestCase {

    func testBellOnBackgroundTabRaisesAttention() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired: (title: String, body: String)?
        model.attentionHandler = { _, title, body in fired = (title, body) }

        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))  // b is now active
        let aSurface = model.openTab(forSessionID: "a")?.surface as? FakeTerminalSurface

        aSurface?.simulateBell()

        XCTAssertEqual(model.openTab(forSessionID: "a")?.activity, .needsAttention)
        XCTAssertNotNil(fired)
    }

    func testNotificationOnBackgroundTabForwardsMessage() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired: (title: String, body: String)?
        model.attentionHandler = { _, title, body in fired = (title, body) }

        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        let aSurface = model.openTab(forSessionID: "a")?.surface as? FakeTerminalSurface

        aSurface?.simulateNotification(title: "Done", body: "Task complete")

        XCTAssertEqual(fired?.title, "Done")
        XCTAssertEqual(fired?.body, "Task complete")
        XCTAssertEqual(model.openTab(forSessionID: "a")?.activity, .needsAttention)
    }

    func testBellOnActiveTabIsNotAttention() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        var fired = false
        model.attentionHandler = { _, _, _ in fired = true }

        model.openSession(Fixture.session("a", project: "/p/a"))  // a is active
        let aSurface = model.activeTab?.surface as? FakeTerminalSurface

        aSurface?.simulateBell()

        XCTAssertFalse(fired)
        XCTAssertEqual(model.activeTab?.activity, .running)  // stays running
    }

    func testActivatingClearsAttention() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        let aTab = model.openTab(forSessionID: "a")!
        (aTab.surface as? FakeTerminalSurface)?.simulateBell()
        XCTAssertEqual(aTab.activity, .needsAttention)

        model.activate(aTab)
        XCTAssertEqual(aTab.activity, .running)
    }

    func testTitleUpdateFromDelegate() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a", title: "Old"))
        let s = model.activeTab?.surface as? FakeTerminalSurface
        s?.simulateTitle("New Title")
        XCTAssertEqual(model.activeTab?.title, "New Title")
    }
}
