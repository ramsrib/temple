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

    func testCloseTabGracefullyRemovesTab() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a", project: "/p/a"))
        let tabID = model.tabs.first!.id

        model.closeTab(tabID)   // graceful surface exits synchronously → auto-close

        XCTAssertTrue(model.tabs.isEmpty)
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

    func testMoveSessionChipAroundSettingsReordersSessionsOnly() {
        let model = Fixture.openModel(factory: FakeTerminalSurfaceFactory())
        model.openSession(Fixture.session("a1", project: "/p/a"))
        model.openSession(Fixture.session("a2", project: "/p/a"))
        model.openSettings()
        // Put Settings in the middle: [a1, Settings, a2].
        model.moveTab(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        // Now drag a1 (index 0) past Settings to the end (index 3).
        model.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.visibleTabs.compactMap(\.sessionID), ["a2", "a1"])
        XCTAssertEqual(model.visibleTabs.map(\.kind), [.session, .settings, .session])
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
}

@MainActor
final class ImmediateReconciler: TempleUI.CodexAdopting {
    let id: String
    init(id: String) { self.id = id }
    func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        adopt(id)
    }
}
