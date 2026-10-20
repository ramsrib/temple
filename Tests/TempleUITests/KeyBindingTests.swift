import AppKit
import XCTest
@testable import TempleUI
import TempleCore

/// The window's key monitor (`KeyCatcher.Coordinator.handle`) given the
/// events AppKit delivers for each chord (ADR-037). `charactersIgnoringModifiers`
/// keeps ⇧ but drops ⌥ and ⌃, so each event carries what a US layout reports.
@MainActor
final class KeyBindingTests: XCTestCase {
    private let catcher = KeyCatcher.Coordinator()
    private var model: AppModel!

    override func setUp() async throws {
        let database = try TempleDB.inMemory()
        let settings = SettingsStore(defaults: Fixture.uniqueDefaults())
        // Codex is the default here so the other agent is Claude, whose new
        // session needs no rollout reconciler.
        settings.defaultAgent = .codex
        model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                         engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                         database: database,
                         settings: settings,
                         overlay: SessionOverlayStore(db: database))
    }

    private func key(_ ignoring: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: ignoring, charactersIgnoringModifiers: ignoring,
                         isARepeat: false, keyCode: keyCode)!
    }

    private func openTabs(_ ids: [String], in project: String) {
        for id in ids { model.openSessions.openSession(Fixture.session(id, project: project)) }
    }

    func testOptionCommandTStartsTheOtherAgentInTheActiveProject() {
        openTabs(["a1"], in: "/p/a")
        XCTAssertTrue(catcher.handle(key("t", [.command, .option], keyCode: 17), model))
        XCTAssertEqual(model.openSessions.activeTab?.agent, .claude, "the agent that isn't the default")
        XCTAssertEqual(model.openSessions.activeTab?.projectPath, "/p/a")
        XCTAssertFalse(model.newSessionPickerPresented)
    }

    func testOptionCommandTWithNoProjectAsksWhere() {
        XCTAssertTrue(catcher.handle(key("t", [.command, .option], keyCode: 17), model))
        XCTAssertTrue(model.newSessionPickerPresented)
        XCTAssertEqual(model.newSessionPickerAgent, .claude)
        XCTAssertTrue(model.openSessions.tabs.isEmpty)
    }

    func testOptionIsTheOtherAgentForThePickerAndShiftNoLonger() {
        XCTAssertFalse(catcher.handle(key("N", [.command, .shift], keyCode: 45), model), "⌘⇧N is not Temple's")
        XCTAssertFalse(model.newSessionPickerPresented)
        XCTAssertTrue(catcher.handle(key("n", [.command, .option], keyCode: 45), model))
        XCTAssertEqual(model.newSessionPickerAgent, .claude)
        XCTAssertTrue(catcher.handle(key("n", .command, keyCode: 45), model), "⌘N retargets to the default")
        XCTAssertEqual(model.newSessionPickerAgent, .codex)
    }

    func testControlCommandChordsAreNotTemples() {
        openTabs(["a1"], in: "/p/a")
        // ⌃⌘F is the system's Enter Full Screen, not the find bar.
        XCTAssertFalse(catcher.handle(key("f", [.command, .control], keyCode: 3), model))
        XCTAssertFalse(catcher.handle(key("w", [.command, .control], keyCode: 13), model))
        XCTAssertFalse(catcher.handle(key("w", [.command, .option], keyCode: 13), model))
        XCTAssertEqual(model.openSessions.tabs.count, 1)
        // ⌃⇥ is the switcher; with ⌥ or ⌘ also held it is not.
        XCTAssertFalse(catcher.handle(key("\t", [.control, .option], keyCode: 48), model))
        XCTAssertFalse(catcher.handle(key("\t", [.control, .command], keyCode: 48), model))
        XCTAssertFalse(model.tabSwitcherPresented)
    }

    func testShiftCommandBracketsStepTabsAndWrap() {
        openTabs(["a1", "a2", "a3"], in: "/p/a")
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a3")
        XCTAssertTrue(catcher.handle(key("}", [.command, .shift], keyCode: 30), model))
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a1", "wraps past the end")
        XCTAssertTrue(catcher.handle(key("{", [.command, .shift], keyCode: 33), model))
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a3", "wraps past the start")
        XCTAssertTrue(catcher.handle(key("{", [.command, .shift], keyCode: 33), model))
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a2")
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/a", "tabs, not projects")
    }

    func testTabSteppingFollowsTheStripFromTheLauncherToo() {
        openTabs(["a1", "a2"], in: "/p/a")
        model.openSessions.openSettings()
        let strip = model.openSessions.visibleTabs.map(\.id)
        model.openSessions.showHome()
        model.openSessions.selectNextTab()
        XCTAssertEqual(model.openSessions.activeTabID, strip.first, "from the launcher, next is the first chip")
        model.openSessions.showHome()
        model.openSessions.selectPreviousTab()
        XCTAssertEqual(model.openSessions.activeTabID, strip.last, "and previous the last")
        for expected in strip {
            model.openSessions.selectNextTab()
            XCTAssertEqual(model.openSessions.activeTabID, expected, "every chip, Settings included, in strip order")
        }
    }

    func testOptionCommandBracketsCycleProjects() {
        openTabs(["a1"], in: "/p/a")
        openTabs(["b1"], in: "/p/b")
        XCTAssertTrue(catcher.handle(key("]", [.command, .option], keyCode: 30), model))
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/a")
        XCTAssertTrue(catcher.handle(key("[", [.command, .option], keyCode: 33), model))
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/b")
    }

    /// The bracket chords follow the layout's characters, not the US key
    /// position: on a German layout keyCode 30 is "+", which isn't Temple's.
    func testBracketChordsAreMatchedByCharacterNotKeyPosition() {
        openTabs(["a1"], in: "/p/a")
        openTabs(["b1"], in: "/p/b")
        XCTAssertFalse(catcher.handle(key("+", [.command, .option], keyCode: 30), model))
        XCTAssertFalse(catcher.handle(key("*", [.command, .shift], keyCode: 30), model))
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/b")
    }

    func testShiftCommandPIsThePaletteToo() {
        XCTAssertTrue(catcher.handle(key("P", [.command, .shift], keyCode: 35), model))
        XCTAssertTrue(model.commandPalettePresented)
        XCTAssertFalse(model.projectSwitcherPresented)
    }

    func testCommandNineIsTheLastTab() {
        openTabs(["a1", "a2", "a3"], in: "/p/a")
        XCTAssertTrue(catcher.handle(key("1", .command, keyCode: 18), model))
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a1")
        XCTAssertTrue(catcher.handle(key("9", .command, keyCode: 25), model))
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "a3", "the last, though there are three")
    }

    func testCapsLockIsThePlainKey() {
        openTabs(["a1"], in: "/p/a")
        XCTAssertTrue(catcher.handle(key("T", [.command, .capsLock], keyCode: 17), model))
        XCTAssertEqual(model.openSessions.tabs.count, 2, "⌘T, not Reopen Closed Tab")
        XCTAssertEqual(model.openSessions.activeTab?.agent, .codex)
    }
}
