import XCTest
@testable import TempleUI
import TempleCore
import TempleTerminalAPI

@MainActor
final class OpenSessionsModelTests: XCTestCase {

    func testOpenSessionSpawnsSurfaceAndActivates() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let s = Fixture.session("a", project: "/p/a")

        model.openSession(s)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectPath, "/p/a")
        XCTAssertNotNil(model.tabs.first?.surface)          // spawned on open
        XCTAssertEqual(factory.created.count, 1)
    }

    func testReuseOrFocusNeverDuplicates() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let s = Fixture.session("a", project: "/p/a")

        model.openSession(s)
        model.openSession(s)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(factory.created.count, 1)            // no second surface
    }

    func testPerProjectScopingSwapsWithActiveTab() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))

        // Active project is now /p/b → only its tab visible.
        XCTAssertEqual(model.activeProjectPath, "/p/b")
        XCTAssertEqual(model.visibleTabs.map(\.sessionID), ["b1"])

        // Focusing an /p/a session swaps the bar back.
        model.openSession(Fixture.session("a1", project: "/p/a"))
        XCTAssertEqual(model.activeProjectPath, "/p/a")
        XCTAssertEqual(Set(model.visibleTabs.compactMap(\.sessionID)), ["a1", "a2"])
    }

    func testAgentRetitleIsHandedUpWithItsSessionID() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        var recorded: [String: String] = [:]
        model.titleHandler = { recorded[$0] = $1 }

        let surface = try! XCTUnwrap(model.tabs.first?.surface)
        model.surface(surface, didUpdateTitle: "Fixing the shift+enter encoding")

        XCTAssertEqual(model.tabs.first?.title, "Fixing the shift+enter encoding")
        XCTAssertEqual(recorded, ["a": "Fixing the shift+enter encoding"],
                       "the sidebar/palette can only track a live title if it is handed up")
    }

    func testSwitchingProjectReturnsToItsLastActiveSession() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))

        // Open in tab order, not recency — the switcher must not reshuffle.
        XCTAssertEqual(model.openProjects, ["/p/a", "/p/b"])

        // Last touched in /p/a was a1 (a2 was opened, then a1 refocused).
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.activateProject("/p/b")
        XCTAssertEqual(model.activeTab?.sessionID, "b1")

        model.activateProject("/p/a")
        XCTAssertEqual(model.activeProjectPath, "/p/a")
        XCTAssertEqual(model.activeTab?.sessionID, "a1", "should return to the last session used there")
    }

    func testProjectCyclingWrapsAndIgnoresASingleProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))

        model.selectNextProject()
        XCTAssertEqual(model.activeProjectPath, "/p/a", "one project: cycling is a no-op")

        model.openSession(Fixture.session("b1", project: "/p/b"))
        model.selectNextProject()
        XCTAssertEqual(model.activeProjectPath, "/p/a", "wraps past the end")
        model.selectPreviousProject()
        XCTAssertEqual(model.activeProjectPath, "/p/b", "wraps past the start")
    }

    func testCloseReturnsToPreviouslyActiveTabNotFirst() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        // From b, open Settings; closing it must land back on b, not a.
        model.openSettings()
        model.closeTab(model.settingsTab!.id)
        XCTAssertEqual(model.activeTab?.sessionID, "b")

        // From b, revisit a, then open c; closing c walks back to a.
        model.activate(model.openTab(forSessionID: "a")!)
        model.openSession(Fixture.session("c", project: "/p/a"))
        model.closeTab(model.openTab(forSessionID: "c")!.id)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testCloseWalksHistoryAcrossProjects() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        model.closeTab(model.openTab(forSessionID: "b")!.id)
        // The previous tab lives in another project — return there anyway.
        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectPath, "/p/a")
    }

    func testCloseTabGracefullyRemovesTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id

        model.closeTab(tabID)   // graceful surface exits synchronously → auto-close

        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testReopenLastClosedTabResumesActivatesAndSpawnsNewSurface() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSession(Fixture.session("a", project: "/p/a", title: "Work"))
        let originalTabID = model.tabs[0].id

        model.closeTab(originalTabID)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)

        model.reopenLastClosedTab()

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNotEqual(model.tabs[0].id, originalTabID)
        XCTAssertEqual(model.tabs[0].sessionID, "a")
        XCTAssertEqual(model.tabs[0].title, "Work")
        XCTAssertTrue(model.tabs[0].isResume)
        XCTAssertEqual(model.activeTabID, model.tabs[0].id)
        XCTAssertEqual(factory.created.count, 2)
    }

    func testReopenDuringGracefulCloseKeepsRecordForRetry() {
        // ⌘⇧T can race the close: the record is pushed at closeTab, but a
        // running tab stays in `tabs` until its process exits. Reopening in
        // that window must not spend the record (it once did, silently).
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory, timeout: 60)
        model.openSession(Fixture.session("a", project: "/p/a"))
        factory.created[0].behavior = .hung
        let tabID = model.tabs[0].id

        model.closeTab(tabID)
        XCTAssertEqual(model.tabs.count, 1)   // still draining

        model.reopenLastClosedTab()           // races the close: must no-op
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs[0].id, tabID)

        factory.created[0].simulateExit()     // the close finally lands
        XCTAssertTrue(model.tabs.isEmpty)

        model.reopenLastClosedTab()           // the record survived the race
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs[0].sessionID, "a")
        XCTAssertTrue(model.tabs[0].isResume)
    }

    func testReopenLastClosedTabUsesLIFOOrder() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        let aID = model.openTab(forSessionID: "a")!.id
        let bID = model.openTab(forSessionID: "b")!.id

        model.closeTab(aID)
        model.closeTab(bID)
        model.reopenLastClosedTab()
        XCTAssertEqual(model.activeTab?.sessionID, "b")

        model.reopenLastClosedTab()
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testReopenSkipsSessionOpenedAgainAndUsesNextClosedEntry() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        let a = Fixture.session("a", project: "/p/a")
        let b = Fixture.session("b", project: "/p/a")
        model.openSession(a)
        model.openSession(b)
        model.closeTab(model.openTab(forSessionID: "a")!.id)
        model.closeTab(model.openTab(forSessionID: "b")!.id)

        model.openSession(b)
        model.reopenLastClosedTab()

        XCTAssertEqual(Set(model.tabs.compactMap(\.sessionID)), ["a", "b"])
        XCTAssertEqual(model.tabs.filter { $0.sessionID == "b" }.count, 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a")
    }

    func testClosingSettingsDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.openSettings()

        model.closeTab(model.settingsTab!.id)
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 0)
    }

    func testClosingProvisionalTabDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        let provisional = model.newSession(agent: .codex, projectPath: "/p/a")
        XCTAssertNil(provisional.sessionID)

        model.closeTab(provisional.id)
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)
    }

    func testSelfExitDoesNotRecordReopenEntry() {
        let factory = FakeTerminalSurfaceFactory()
        let model = Fixture.openModel(factory: factory)
        model.earlyExitGraceSeconds = 0
        model.openSession(Fixture.session("a", project: "/p/a"))

        factory.created[0].simulateExit()
        model.reopenLastClosedTab()

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 1)
    }

    func testReopenLastClosedTabSwitchesBackToItsProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/b"))
        model.closeTab(model.openTab(forSessionID: "a")!.id)
        XCTAssertEqual(model.activeProjectPath, "/p/b")

        model.reopenLastClosedTab()

        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertEqual(model.activeProjectPath, "/p/a")
    }

    func testConfirmedPendingCloseRecordsReopenEntry() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))

        model.requestClose(tabID: model.tabs[0].id)
        XCTAssertNotNil(model.pendingCloseTabID)
        model.confirmPendingClose()
        model.reopenLastClosedTab()

        XCTAssertEqual(model.activeTab?.sessionID, "a")
        XCTAssertTrue(model.activeTab?.isResume == true)
    }

    func testProcessSelfExitAutoClosesTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.earlyExitGraceSeconds = 0  // fake exits instantly; simulate a long-lived agent
        model.openSession(Fixture.session("a", project: "/p/a"))
        let fake = model.tabs.first?.surface as? FakeTerminalSurface

        fake?.simulateExit()    // agent quit / crash (ADR-010 reverse)

        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testEarlyExitKeepsTabWithExitedState() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let fake = model.tabs.first?.surface as? FakeTerminalSurface

        fake?.simulateExit(status: 127)  // launch failure right after spawn

        // The tab stays so the error output is readable; the chip shows exited.
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.tabs.first?.activity, .exited(status: 127))

        // Explicitly closing the dead tab removes it.
        model.closeTab(model.tabs.first!.id)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testRequestCloseBusyTabPromptsBeforeRemoving() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id
        XCTAssertEqual(model.tabs.first?.activity, .running)   // agent working

        model.requestClose(tabID: tabID)
        // Gated: nothing closes yet, a confirmation is pending.
        XCTAssertEqual(model.pendingCloseTabID, tabID)
        XCTAssertEqual(model.tabs.count, 1)

        model.confirmPendingClose()
        XCTAssertNil(model.pendingCloseTabID)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testCancelPendingCloseKeepsBusyTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id
        model.requestClose(tabID: tabID)
        XCTAssertEqual(model.pendingCloseTabID, tabID)

        model.cancelPendingClose()
        XCTAssertNil(model.pendingCloseTabID)
        XCTAssertEqual(model.tabs.count, 1)                    // still open
    }

    func testRequestCloseIdleTabClosesImmediately() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.tabs.first!.activity = .idle                     // not working

        model.requestClose(tabID: model.tabs.first!.id)

        XCTAssertNil(model.pendingCloseTabID)                  // no prompt
        XCTAssertTrue(model.tabs.isEmpty)                      // closed right away
    }

    func testRestoreComesBackInLastActiveProject() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))   // last active: /p/b

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()
        XCTAssertEqual(relaunched.activeProjectPath, "/p/b")
        XCTAssertEqual(relaunched.tabs.count, 3)

        // Switching back by focusing an existing tab also updates the record.
        model.activate(model.tabs.first { $0.sessionID == "a1" }!)
        let again = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                      appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        again.restore()
        XCTAssertEqual(again.activeProjectPath, "/p/a")
    }

    /// ⌘Q drains every agent, so every surface reports .exited on the way out. If
    /// those exits are treated as agents finishing, quitting closes every tab and
    /// saves an empty set — and the next launch comes back to nothing.
    func testQuitDoesNotErasTheSessionsItMustRestore() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        // Sessions you quit on are long-lived, i.e. well past the early-exit grace
        // that keeps a failed launch visible — so their exits auto-close the tab.
        model.earlyExitGraceSeconds = 0
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))
        XCTAssertEqual(persistence.load().count, 2)

        // Quit: freeze the set, then every draining agent reports its exit.
        model.prepareForQuit()
        for tab in model.tabs {
            guard let surface = tab.surface else { continue }
            model.surface(surface, didChangeState: .exited(status: 0))
        }

        XCTAssertEqual(model.tabs.count, 2, "a drained agent is not a finished agent")
        XCTAssertEqual(Set(persistence.load().map(\.sessionID)), ["a1", "b1"])

        let relaunched = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                                           appearanceProvider: { .default },
                                           runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                           persistence: persistence)
        relaunched.restore()
        XCTAssertEqual(Set(relaunched.tabs.compactMap(\.sessionID)), ["a1", "b1"])
    }

    func testClosingInertRestoredChipRemovesWithoutSpawning() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        persistence.save([PersistedTab(sessionID: "a", agent: .claude, projectPath: "/p/a", title: "t")])
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.restore()
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertNil(model.tabs.first?.surface)     // inert
        XCTAssertNil(model.activeTabID)             // launcher shows

        model.closeTab(model.tabs.first!.id)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(factory.created.count, 0)    // never spawned
    }

    func testNewClaudeSessionKnowsIdImmediately() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        let tab = model.newSession(agent: .claude, projectPath: "/p/a")
        XCTAssertNotNil(tab.sessionID)
        XCTAssertFalse(tab.isProvisional)
        XCTAssertTrue(tab.command?.argv.contains("--session-id") ?? false)
    }

    func testNewCodexSessionIsProvisionalThenAdopted() {
        let reconciler = ImmediateReconciler(id: "codex-123")
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory(), reconciler: reconciler)
        let tab = model.newSession(agent: .codex, projectPath: "/p/a")
        // ImmediateReconciler adopts synchronously.
        XCTAssertEqual(tab.sessionID, "codex-123")
        XCTAssertFalse(tab.isProvisional)
    }

    func testDefaultAgentNewSessionUsesConfiguredAgent() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory(), defaultAgent: .codex)
        model.openSession(Fixture.session("a", project: "/p/a"))  // set active project
        let tab = model.newSessionDefaultAgent()
        XCTAssertEqual(tab?.agent, .codex)
    }

    func testSettingsTabIsSingletonAndProjectAgnostic() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSettings()
        model.openSettings()
        XCTAssertEqual(model.tabs.filter { $0.kind == .settings }.count, 1)
        // Settings appears in the bar regardless of active project.
        XCTAssertTrue(model.visibleTabs.contains { $0.kind == .settings })
    }

    func testSelectTabByIndexWithinProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.selectTab(index: 1)
        XCTAssertEqual(model.activeTab?.sessionID, "a1")
        model.selectTab(index: 2)
        XCTAssertEqual(model.activeTab?.sessionID, "a2")
    }

    func testMoveTabReordersWithinProject() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
        model.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a2", "a1"])
    }

    func testSettingsTabDefaultsToTrailingInVisibleRow() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Default offset keeps Settings at the end (matches original behavior).
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .session, .settings])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testMoveSettingsTabToMiddleReorders() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Row is [a1, a2, Settings]; drag Settings (index 2) to the middle (index 1).
        model.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .settings, .session])
        // Session order is untouched.
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testMoveTabToFrontAndToEnd() {
        // The chip menu's restacking controls: front = toOffset 0, end =
        // toOffset row-count, from any middle position — Settings included.
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        model.openSession(Fixture.session("b", project: "/p/a"))
        model.openSession(Fixture.session("c", project: "/p/a"))
        model.openSettings()   // [a, b, c, Settings]

        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 0)   // b to front
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["b", "a", "c"])

        let count = model.visibleTabs.count
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: count)   // a to end
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["b", "c", "a"])
        // a passed Settings on its way to the end; Settings stepped aside.
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .session, .settings, .session])
    }

    func testSessionCrossesSettingsInOneStep() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Put Settings in the middle: [a1, Settings, a2].
        model.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        // The drag gesture swaps one slot at a time: a1 crossing Settings is
        // the adjacent exchange move(0 → 2). Settings must step aside — the
        // old pinned-offset behavior reconstructed the identical row and the
        // drag could never pass the Settings chip.
        model.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session, .session])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])

        // The next step exchanges a1 with a2; Settings keeps its new slot.
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session, .session])
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a2", "a1"])
    }

    func testSettingsOffsetIsGlobalAndClampsAcrossProjects() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSession(Fixture.session("b1", project: "/p/b"))
        model.openSettings()
        // Active project is /p/b (1 session). Row is [b1, Settings]; move Settings to front.
        model.moveTab(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.settings, .session])

        // Switch back to /p/a (2 sessions): offset 0 is preserved (global, clamped).
        model.openSession(Fixture.session("a1", project: "/p/a"))
        XCTAssertEqual(model.activeProjectPath, "/p/a")
        XCTAssertEqual(model.visibleTabs.first?.kind, .settings)
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a1", "a2"])
    }

    func testRestoreBuildsInertChips() {
        let defaults = Fixture.uniqueDefaults()
        let persistence = UserDefaultsTabPersistence(defaults: defaults)
        persistence.save([
            PersistedTab(sessionID: "a", agent: .claude, projectPath: "/p/a", title: "A"),
            PersistedTab(sessionID: "b", agent: .codex, projectPath: "/p/a", title: "B"),
        ])
        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(surfaceFactory: factory, appearanceProvider: { .default },
                                      runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
                                      persistence: persistence)
        model.restore()
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(model.tabs.allSatisfy { $0.surface == nil })
        XCTAssertEqual(factory.created.count, 0)   // no process storm
    }

    func testDBPersistenceReopensAndRestoresFullInertTabMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-ui-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")
        let writer = DBTabPersistence(db: try TempleDB(path: path))
        writer.save([
            PersistedTab(sessionID: "claude-id", agent: .claude,
                         projectPath: "/p/a", title: "Claude title"),
            PersistedTab(sessionID: "codex-id", agent: .codex,
                         projectPath: "/p/a", title: "Codex title"),
        ])

        let factory = FakeTerminalSurfaceFactory()
        let model = OpenSessionsModel(
            surfaceFactory: factory,
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(),
            registry: InMemoryProcessRegistry(),
            persistence: DBTabPersistence(db: try TempleDB(path: path))
        )
        model.restore()

        XCTAssertEqual(model.tabs.compactMap(\.sessionID), ["claude-id", "codex-id"])
        XCTAssertEqual(model.tabs.map(\.agent), [.claude, .codex])
        XCTAssertEqual(model.tabs.map(\.title), ["Claude title", "Codex title"])
        XCTAssertTrue(model.tabs.allSatisfy { $0.surface == nil })
        XCTAssertEqual(factory.created.count, 0)
    }

    /// The launch-failure header shows the argv the tab launched with, so its "is the
    /// command to blame?" verdict must be frozen when the tab dies. Re-deriving it from
    /// today's settings lets an unrelated edit rewrite history: break your arguments an
    /// hour later and a healthy old failure suddenly gets blamed for it.
    func testLaunchBlameIsFrozenWhenTheTabDies() {
        var toolchainHealthy = true
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            binaryPath: { _ in "/bin/claude" },
            canLaunch: { _ in toolchainHealthy })

        let tab = model.newSession(agent: .claude, projectPath: "/p/a")
        let surface = tab.surface as? FakeTerminalSurface
        surface?.simulateExit(status: 1)                 // dies while the toolchain is fine

        XCTAssertFalse(tab.commandWasSuspect, "a verified command was blamed")

        // The user later breaks their settings. The dead tab's verdict must not move.
        toolchainHealthy = false
        XCTAssertFalse(tab.commandWasSuspect, "an old failure was re-judged by new settings")
    }

    func testATabThatDiesWithABrokenToolchainDoesBlameTheCommand() {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            binaryPath: { _ in "/bin/claude" },
            canLaunch: { _ in false })

        let tab = model.newSession(agent: .claude, projectPath: "/p/a")
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertTrue(tab.commandWasSuspect)
    }

    private func modelForResumeTests(sessionKnown: @escaping (String) -> Bool?) -> OpenSessionsModel {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            binaryPath: { _ in "/bin/claude" },
            canLaunch: { _ in true })
        model.sessionKnown = sessionKnown
        return model
    }

    func testAnEarlyExitingResumeWithAMissingTargetGetsAnnotated() {
        // Index loaded, and no transcript on disk carries this id (the id
        // rotated out from under the tab via in-session /resume or /clear).
        let model = modelForResumeTests(sessionKnown: { _ in false })

        model.openSession(Fixture.session("gone", project: "/p/a"))  // resume of an indexed session
        let tab = model.activeTab!
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertTrue(tab.resumeTargetMissing)
        XCTAssertFalse(tab.commandWasSuspect, "a healthy command must not be blamed too")
    }

    func testAnUnloadedIndexNeverClaimsAMissingResumeTarget() {
        let model = modelForResumeTests(sessionKnown: { _ in nil })  // index loading: unknown, not missing

        model.openSession(Fixture.session("gone", project: "/p/a"))
        let tab = model.activeTab!
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertFalse(tab.resumeTargetMissing)
    }

    func testANewSessionEarlyExitIsNeverBlamedOnIdRotation() {
        // A NEW tab's freshly minted id is legitimately absent from the index;
        // its early exit (auth, config, anything) is not a resume failure.
        let model = modelForResumeTests(sessionKnown: { _ in false })

        let tab = model.newSession(agent: .claude, projectPath: "/p/a")
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 1)

        XCTAssertFalse(tab.resumeTargetMissing)
    }

    func testExtraArgsAreInsertedAfterBinaryForNewAndResume() {
        let model = OpenSessionsModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(),
            persistence: UserDefaultsTabPersistence(defaults: Fixture.uniqueDefaults()),
            binaryPath: { $0 == .codex ? "/bin/codex" : "/bin/claude" },
            extraArgs: { $0 == .codex ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--dangerously-skip-permissions"] })

        let tab = model.newSession(agent: .claude, projectPath: "/p/a")
        XCTAssertEqual(tab.command?.argv.prefix(2).map { $0 },
                       ["/bin/claude", "--dangerously-skip-permissions"])

        model.openSession(Fixture.session("r1", agent: .codex, project: "/p/b"))
        let resumed = model.tabs.first { $0.sessionID == "r1" }
        // Flags precede the subcommand: codex <flags> resume <id>.
        XCTAssertEqual(resumed?.command?.argv,
                       ["/bin/codex", "--dangerously-bypass-approvals-and-sandbox", "resume", "r1"])
    }
}

@MainActor
final class ImmediateReconciler: TempleUI.CodexAdopting {
    let id: String
    init(id: String) { self.id = id }
    func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        adopt(id)
    }
}
