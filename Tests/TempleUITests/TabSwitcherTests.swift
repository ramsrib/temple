import XCTest
@testable import TempleUI
import TempleCore

private struct NoNoise: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

/// ⌃⇥ — the tab switcher walks open tabs most-recently-visited first, the
/// same gesture as the ⌘P project switcher one level down.
@MainActor
final class TabSwitcherTests: XCTestCase {
    private func makeModel(_ index: SessionIndex) -> AppModel {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(index),
            noiseFilter: NoNoise(),
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay
        )
        model.index = index
        return model
    }

    /// Three sessions across two projects, opened in order — so the visit
    /// trail is 1, 2, 3 and the MRU list reads 3, 2, 1.
    private func modelWithThreeTabs() -> AppModel {
        let sessions = [
            Fixture.session("1", project: "/p/api", title: "t"),
            Fixture.session("2", project: "/p/api", title: "t"),
            Fixture.session("3", project: "/p/web", title: "t"),
        ]
        let index = SessionIndex(projects: [
            Project(path: "/p/api", sessions: Array(sessions[0...1])),
            Project(path: "/p/web", sessions: [sessions[2]]),
        ])
        let model = makeModel(index)
        for session in sessions { model.openSessions.openSession(session) }
        return model
    }

    private func tabID(_ model: AppModel, _ sessionID: String) -> SessionTab.ID {
        model.openSessions.tabs.first { $0.sessionID == sessionID }!.id
    }

    func testTabsByRecencyFollowsTheVisitTrailNotRowOrder() {
        let model = modelWithThreeTabs()
        XCTAssertEqual(model.switchableTabs.compactMap(\.sessionID), ["3", "2", "1"])

        // Revisiting an old tab moves it to the front, everything else shifts.
        model.openSessions.activate(tabID: tabID(model, "1"))
        XCTAssertEqual(model.switchableTabs.compactMap(\.sessionID), ["1", "3", "2"])
    }

    /// One tap highlights the PREVIOUS tab; releasing lands on it — and a
    /// second tap bounces straight back. That bounce is the whole gesture.
    func testTabSwitcherBouncesBetweenTheTwoMostRecentTabs() {
        let model = modelWithThreeTabs()

        model.advanceTabSwitcher(by: 1)
        XCTAssertEqual(model.tabSwitcherSelection, tabID(model, "2"))
        model.commitTabSwitcher()
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "2")
        XCTAssertFalse(model.tabSwitcherPresented)

        model.advanceTabSwitcher(by: 1)
        model.commitTabSwitcher()
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "3")
    }

    /// The trail spans projects: landing on a tab that lives elsewhere also
    /// switches the strip to its project.
    func testCommitSwitchesProjectWhenThePreviousTabLivesElsewhere() {
        let model = modelWithThreeTabs()
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/web")

        model.advanceTabSwitcher(by: 1)   // previous tab is "2" in /p/api
        model.commitTabSwitcher()
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "2")
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/api")
    }

    func testTabSwitcherWalksWrapsAndCancels() {
        let model = modelWithThreeTabs()
        let active = model.openSessions.activeTabID

        model.advanceTabSwitcher(by: 1)
        model.advanceTabSwitcher(by: 1)
        XCTAssertEqual(model.tabSwitcherSelection, tabID(model, "1"))
        model.advanceTabSwitcher(by: 1)
        XCTAssertEqual(model.tabSwitcherSelection, tabID(model, "3"),
                       "wraps back to where you started")
        model.advanceTabSwitcher(by: -1)
        XCTAssertEqual(model.tabSwitcherSelection, tabID(model, "1"),
                       "⌃⇧⇥ walks the other way")

        // Esc leaves you exactly where you were.
        model.cancelTabSwitcher()
        XCTAssertFalse(model.tabSwitcherPresented)
        XCTAssertEqual(model.openSessions.activeTabID, active)
    }

    /// A highlighted tab can close while the switcher is up (its agent exits).
    /// The selection is held as an ID, so the commit must go nowhere rather
    /// than land on whatever slid into the vacated slot.
    func testTabSwitcherSurvivesTheHighlightedTabClosingWhileItIsUp() {
        let model = modelWithThreeTabs()
        let active = model.openSessions.activeTabID

        model.advanceTabSwitcher(by: 1)
        let highlighted = model.tabSwitcherSelection!
        model.openSessions.closeTab(highlighted)

        model.commitTabSwitcher()
        XCTAssertFalse(model.tabSwitcherPresented)
        XCTAssertEqual(model.openSessions.activeTabID, active,
                       "must not land on a tab that is no longer open")
    }

    /// Opening the switcher without ⌃ held (e.g. from a future menu item) must
    /// not be committed by the next unrelated modifier press.
    func testMouseOpenedTabSwitcherIsNotCommittedByAModifierRelease() {
        let model = modelWithThreeTabs()
        let active = model.openSessions.activeTabID

        model.advanceTabSwitcher(by: 1, heldControl: false)
        model.controlReleasedForTabSwitcher()

        XCTAssertTrue(model.tabSwitcherPresented, "waits for Return or Esc")
        XCTAssertEqual(model.openSessions.activeTabID, active)
    }

    func testTabSwitcherNeedsTwoTabs() {
        let session = Fixture.session("only", project: "/p", title: "t")
        let model = makeModel(SessionIndex(projects: [Project(path: "/p", sessions: [session])]))
        model.openSessions.openSession(session)

        model.advanceTabSwitcher(by: 1)
        XCTAssertFalse(model.tabSwitcherPresented, "nothing to switch to")
    }

    /// Return (or a click) while ⌃ is still physically held must not move
    /// focus yet: the source terminal saw the modifier press, and moving
    /// focus first would send its release to the destination instead —
    /// Ghostty then holds a stale pressed modifier. The landing parks until
    /// the release.
    func testCommitWhileControlHeldParksTheLandingUntilRelease() {
        let model = modelWithThreeTabs()
        model.heldModifiers = { .control }

        model.advanceTabSwitcher(by: 1)
        model.commitTabSwitcher()                     // Return, ⌃ still down
        XCTAssertFalse(model.tabSwitcherPresented, "the HUD dismisses right away")
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "3",
                       "no focus move while ⌃ is held")

        model.heldModifiers = { [] }
        model.flagsChangedForDeferredLanding([])      // ⌃ came up
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "2")

        // The release only pays once — later flag changes land nothing.
        model.openSessions.activate(tabID: tabID(model, "1"))
        model.flagsChangedForDeferredLanding([])
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "1")
    }

    /// Walking again while a landing is still parked supersedes it — the two
    /// must not both activate.
    func testAFreshWalkSupersedesAParkedLanding() {
        let model = modelWithThreeTabs()
        model.heldModifiers = { .control }

        model.advanceTabSwitcher(by: 1)
        model.commitTabSwitcher()                     // parks a landing on "2"
        model.advanceTabSwitcher(by: 1)               // new walk, still holding ⌃
        model.cancelTabSwitcher()

        model.flagsChangedForDeferredLanding([])
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "3",
                       "the superseded landing must not fire")
    }

    /// Deactivating mid-hold means the release never reaches the monitor,
    /// but the user did choose a destination — deactivation lands it.
    func testDeactivationLandsAParkedCommit() {
        let model = modelWithThreeTabs()
        model.heldModifiers = { .control }

        model.advanceTabSwitcher(by: 1)
        model.commitTabSwitcher()
        model.performDeferredLandingNow()
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "2")
    }

    /// The same parking protects the ⌘P project switcher.
    func testProjectSwitcherCommitWhileCommandHeldParksTheLanding() {
        let model = modelWithThreeTabs()
        model.heldModifiers = { .command }

        model.advanceProjectSwitcher(by: 1)
        model.commitProjectSwitcher()
        XCTAssertFalse(model.projectSwitcherPresented)
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/web",
                       "no project switch while ⌘ is held")

        model.flagsChangedForDeferredLanding([])
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/api")
    }

    func testTabSwitcherIsMutuallyExclusiveWithTheOtherPanels() {
        let model = modelWithThreeTabs()

        model.commandPalettePresented = true
        model.projectSwitcherPresented = true
        model.advanceTabSwitcher(by: 1)
        XCTAssertTrue(model.tabSwitcherPresented)
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertFalse(model.projectSwitcherPresented)

        // ...and every other presenter dismisses the tab switcher in turn.
        model.toggleCommandPalette()
        XCTAssertFalse(model.tabSwitcherPresented)

        model.advanceTabSwitcher(by: 1)
        model.advanceProjectSwitcher(by: 1)
        XCTAssertFalse(model.tabSwitcherPresented)
        XCTAssertTrue(model.projectSwitcherPresented)
    }
}
