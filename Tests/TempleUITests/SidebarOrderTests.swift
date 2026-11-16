import XCTest
@testable import TempleUI
import TempleCore

/// The sidebar lists each project's open sessions first, then the rest by
/// activity, and takes its order again when something moves rows, unless
/// the pointer is over it (docs/designs/ux-pass-2026-11.md section 3).
@MainActor
final class SidebarOrderTests: XCTestCase {
    private var scheduledRecency: [@MainActor () -> Void] = []

    private func makeModel(_ rows: [Session], database: TempleDB? = nil) -> AppModel {
        let database = database ?? (try! TempleDB.inMemory())
        Fixture.join(rows, to: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        model.scheduleSidebarRecencyRefresh = { [weak self] in self?.scheduledRecency.append($0) }
        model.receiveEngineSnapshot(SessionsSnapshot(generation: 1, resolutions: Dictionary(
            uniqueKeysWithValues: model.sessions.map { ($0.id, MemberResolution.confirmedAbsent) })))
        XCTAssertTrue(model.sidebarRanksFrozen)
        return model
    }

    private func rows() -> [Session] {
        [
            Fixture.row("a1", project: "/p/a", updated: 50),
            Fixture.row("a2", project: "/p/a", updated: 40),
            Fixture.row("a3", project: "/p/a", updated: 30),
            Fixture.row("b1", project: "/p/b", updated: 20),
            Fixture.row("b2", project: "/p/b", updated: 10),
        ]
    }

    private func ids(_ model: AppModel, _ path: String) -> [String] {
        model.displayProjects.first { $0.path == path }?.sessions.map(\.sessionID) ?? []
    }

    private func open(_ model: AppModel, _ id: String) {
        let row = model.sessions.first { $0.sessionID == id }!
        model.openSessions.openSession(row)
    }

    /// The `$tabs` sink hops to the main run loop.
    private func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testOpenSessionsComeFirstInTabOrderThenTheRestByActivity() {
        let model = makeModel(rows())
        open(model, "a3")
        open(model, "a2")
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a2", "a1"])
        XCTAssertTrue(model.inSidebarOpenGroup(SessionKey(id: "a3", host: .local)))
        XCTAssertFalse(model.inSidebarOpenGroup(SessionKey(id: "a1", host: .local)))
    }

    func testNothingMovesWhileThePointerIsOverTheSidebarAndEverythingLandsWhenItLeaves() {
        let model = makeModel(rows())
        model.sidebarPointerInside = true
        open(model, "a3")
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a1", "a2", "a3"], "held under the pointer")
        XCTAssertFalse(model.inSidebarOpenGroup(SessionKey(id: "a3", host: .local)))
        model.sidebarPointerInside = false
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a1", "a2"])
    }

    func testClosingATabMovesItsRowOutOfTheOpenGroup() {
        let model = makeModel(rows())
        open(model, "a3")
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a1", "a2"])
        let tab = model.openSessions.tabs.first { $0.sessionKey == SessionKey(id: "a3", host: .local) }!
        model.openSessions.closeTab(tab.id)
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a1", "a2", "a3"])
    }

    func testActivityReordersProjectsABeatLaterUnlessThePointerIsOverTheSidebar() {
        let model = makeModel(rows())
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        model.overlay.touch(SessionKey(id: "b2", host: .local), at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"], "not at once")
        XCTAssertEqual(scheduledRecency.count, 1, "one beat for any number of writes")
        model.sidebarPointerInside = true
        scheduledRecency.removeFirst()()
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"], "held under the pointer")
        model.sidebarPointerInside = false
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a"])
        XCTAssertEqual(ids(model, "/p/b"), ["b2", "b1"])
    }

    func testCustomOrderKeepsTheDraggedOrderAgainstActivity() {
        let model = makeModel(rows())
        model.moveProject(Fixture.key("/p/b"), before: Fixture.key("/p/a"))
        XCTAssertEqual(model.sidebarOptions.sort, .custom, "a drag is a custom order")
        model.overlay.touch(SessionKey(id: "a3", host: .local), at: Date(timeIntervalSince1970: 200))
        scheduledRecency.forEach { $0() }
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a"])
        model.setSidebarSort(.recentActivity)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
    }

    func testAStoredCustomOrderStaysTheDefaultForSomeoneWhoDraggedBefore() {
        let database = try! TempleDB.inMemory()
        let first = makeModel(rows(), database: database)
        first.moveProject(Fixture.key("/p/b"), before: Fixture.key("/p/a"))
        // A build before the menu stored the order but no sort.
        try! database.setUIState(nil, for: UIStateStore.SidebarKey.sort)
        let next = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                            engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: database,
                            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        XCTAssertEqual(next.sidebarOptions.sort, .custom)
        XCTAssertNil(UIStateStore(db: database).string(UIStateStore.SidebarKey.sort), "read, never written back")
    }

    func testNameSortAndMachineGrouping() {
        let host = HostID(rawValue: "box")
        let model = makeModel([
            Fixture.row("z", project: "/p/zeta", updated: 50),
            Fixture.row("r", project: "/p/alpha", updated: 40, host: host),
            Fixture.row("m", project: "/p/mid", updated: 30),
        ])
        model.setSidebarSort(.name)
        model.setSidebarGrouping(.project)
        XCTAssertEqual(model.displayProjects.map(\.key.name), ["alpha", "mid", "zeta"])
        model.setSidebarGrouping(.machine)
        XCTAssertEqual(model.displayProjects.map(\.key), [Fixture.key("/p/mid"), Fixture.key("/p/zeta"),
                                                           ProjectKey(host: host, path: "/p/alpha")],
                       "this Mac first, each machine in the sort's order")
    }

    func testOpenOnlyListsOpenSessionsAndOnlyProjectsWithOne() {
        let model = makeModel(rows())
        open(model, "a2")
        pump()
        model.setSidebarOpenOnly(true)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a"])
        XCTAssertEqual(ids(model, "/p/a"), ["a2"])
        model.searchText = "Title"
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"], "a search finds everything")
    }

    func testOptionsPersistOneKeyEachAndOnlyWhenChosen() {
        let database = try! TempleDB.inMemory()
        let model = makeModel(rows(), database: database)
        let store = UIStateStore(db: database)
        XCTAssertNil(store.string(UIStateStore.SidebarKey.openOnly))
        model.setSidebarOpenOnly(true)
        model.setSidebarSessionSort(.name)
        let reread = UIStateStore(db: database)
        XCTAssertEqual(reread.string(UIStateStore.SidebarKey.openOnly), "1")
        XCTAssertEqual(reread.string(UIStateStore.SidebarKey.sessionSort), "name")
        XCTAssertNil(reread.string(UIStateStore.SidebarKey.grouping))
        XCTAssertEqual(reread.sidebarOptions(customByDefault: false),
                       SidebarOptions(sessionSort: .name, openOnly: true))
        model.setSidebarOpenOnly(false)
        XCTAssertNil(UIStateStore(db: database).string(UIStateStore.SidebarKey.openOnly), "off is the default: no key")
    }

    // MARK: Session sort

    private func titled() -> [Session] {
        [
            Fixture.row("c", project: "/p/a", title: "Charlie", updated: 50),
            Fixture.row("a", project: "/p/a", title: "Alpha", updated: 40),
            Fixture.row("b", project: "/p/a", title: "Bravo", updated: 30),
        ]
    }

    func testSessionsSortByNameWithoutMovingProjects() {
        let model = makeModel(titled() + [Fixture.row("z", project: "/p/z", updated: 10)])
        model.setSidebarSessionSort(.name)
        XCTAssertEqual(ids(model, "/p/a"), ["a", "b", "c"])
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/z"], "projects keep their own sort")
    }

    func testOpenSessionsStayFirstWhateverTheSessionSort() {
        let model = makeModel(titled())
        open(model, "c")
        pump()
        model.setSidebarSessionSort(.name)
        XCTAssertEqual(ids(model, "/p/a"), ["c", "a", "b"])
    }

    func testSessionsSortByDateStartedFromTheTranscriptElseWhenTempleSawThem() throws {
        let database = try TempleDB.inMemory()
        try database.join(sessionID: "old", via: .imported, agent: .claude,
                          core: SessionCore(directory: "/p/a", directorySource: .transcript, title: "Old",
                                            lastActiveAt: Date(timeIntervalSince1970: 90),
                                            startedAt: Date(timeIntervalSince1970: 5)))
        try database.join(sessionID: "new", via: .imported, agent: .claude,
                          core: SessionCore(directory: "/p/a", directorySource: .transcript, title: "New",
                                            lastActiveAt: Date(timeIntervalSince1970: 50),
                                            startedAt: Date(timeIntervalSince1970: 40)))
        let model = makeModel([], database: database)
        XCTAssertEqual(ids(model, "/p/a"), ["old", "new"], "by activity")
        model.setSidebarSessionSort(.dateStarted)
        XCTAssertEqual(ids(model, "/p/a"), ["new", "old"], "newest start first")
    }

    func testDraggingASessionMakesACustomOrderThatSurvivesARelaunch() throws {
        let database = try TempleDB.inMemory()
        let model = makeModel(titled(), database: database)
        XCTAssertEqual(ids(model, "/p/a"), ["c", "a", "b"])
        model.moveSession(SessionKey(id: "b", host: .local), before: SessionKey(id: "c", host: .local))
        XCTAssertEqual(model.sidebarOptions.sessionSort, .custom)
        XCTAssertEqual(ids(model, "/p/a"), ["b", "c", "a"])
        // Activity no longer moves them.
        model.overlay.touch(SessionKey(id: "a", host: .local), at: Date(timeIntervalSince1970: 500))
        scheduledRecency.forEach { $0() }
        XCTAssertEqual(ids(model, "/p/a"), ["b", "c", "a"])

        let next = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                            engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: database,
                            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        next.receiveEngineSnapshot(SessionsSnapshot(generation: 1, resolutions: Dictionary(
            uniqueKeysWithValues: next.sessions.map { ($0.id, MemberResolution.confirmedAbsent) })))
        XCTAssertEqual(ids(next, "/p/a"), ["b", "c", "a"])
        // A session nobody placed comes in above the placed ones.
        next.overlay.join("d", via: .created, agent: .claude, core: SessionCore(directory: "/p/a"))
        XCTAssertEqual(ids(next, "/p/a").first, "d")
    }

    /// A search shows closed sessions even with Open Only on; dragging one
    /// of them still reorders.
    func testADragStillWorksOnClosedRowsASearchShowsUnderOpenOnly() {
        let model = makeModel(titled())
        model.setSidebarOpenOnly(true)
        model.searchText = "a"
        model.moveSession(SessionKey(id: "b", host: .local), before: SessionKey(id: "c", host: .local))
        XCTAssertEqual(model.sidebarOptions.sessionSort, .custom)
        XCTAssertEqual(model.sessionOrder[Fixture.key("/p/a")], ["b", "c", "a"])
    }

    /// A person's own rename moves the row at once under a Name sort; a
    /// name that changes otherwise (here, the overlay directly, as a fill
    /// does) waits for the pointer to leave.
    func testARenameMovesAtOnceAndOtherNameChangesWaitForThePointer() {
        let model = makeModel(titled())
        model.setSidebarSessionSort(.name)
        model.sidebarPointerInside = true
        model.renameSession(SessionKey(id: "b", host: .local), to: "Zulu")
        XCTAssertEqual(ids(model, "/p/a"), ["a", "c", "b"], "the person's rename lands now")
        model.sidebarPointerInside = false
        model.requestSidebarRefresh()
        model.overlay.rename(SessionKey(id: "b", host: .local), to: "Bravo")
        scheduledRecency.forEach { $0() }
        scheduledRecency.removeAll()
        model.requestSidebarRefresh()
        XCTAssertEqual(ids(model, "/p/a"), ["a", "b", "c"])
    }

    func testANameFilledUnderThePointerWaitsForItToLeave() {
        let model = makeModel(titled())
        model.setSidebarSessionSort(.name)
        XCTAssertEqual(ids(model, "/p/a"), ["a", "b", "c"])
        model.sidebarPointerInside = true
        model.overlay.rename(SessionKey(id: "c", host: .local), to: "Aardvark")
        scheduledRecency.forEach { $0() }
        XCTAssertEqual(ids(model, "/p/a"), ["a", "b", "c"], "held")
        model.sidebarPointerInside = false
        model.requestSidebarRefresh()
        XCTAssertEqual(ids(model, "/p/a"), ["c", "a", "b"])
    }

    func testASessionDropAcrossProjectsDoesNothing() {
        let model = makeModel(rows())
        model.moveSession(SessionKey(id: "b1", host: .local), before: SessionKey(id: "a1", host: .local))
        XCTAssertEqual(model.sidebarOptions.sessionSort, .recentActivity)
        XCTAssertEqual(ids(model, "/p/b"), ["b1", "b2"])
    }

    func testOpenRowsKeepTheirPlacesUnderThePointerWhenATabCloses() {
        let model = makeModel(rows())
        open(model, "a3")
        open(model, "a2")
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a2", "a1"])
        model.sidebarPointerInside = true
        let tab = model.openSessions.tabs.first { $0.sessionKey == SessionKey(id: "a3", host: .local) }!
        model.openSessions.closeTab(tab.id)
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a2", "a1"], "the closed row keeps its place while held")
        model.sidebarPointerInside = false
        XCTAssertEqual(ids(model, "/p/a"), ["a2", "a1", "a3"])
    }

    /// A tab learning its session (a pending Codex tab adopting its row)
    /// changes no tab array; the row still joins the open group.
    func testATabThatLearnsItsSessionJoinsTheOpenGroup() {
        let model = makeModel(rows())
        open(model, "a1")
        pump()
        let tab = model.openSessions.tabs.first { $0.sessionKey == SessionKey(id: "a1", host: .local) }!
        tab.sessionID = "a3"
        pump()
        XCTAssertEqual(ids(model, "/p/a"), ["a3", "a1", "a2"])
    }

    /// Activity that only brings a row into the recent window still lands.
    func testARowThatBecomesRecentIsListedAfterTheBeat() {
        let model = makeModel(rows())
        let b2 = SessionKey(id: "b2", host: .local)
        XCTAssertFalse(model.inSidebarRecent(model.sessions.first { $0.id == b2 }!), "1970 is not recent")
        model.overlay.touch(b2, at: Date())
        let published = expectation(description: "published")
        let watch = model.objectWillChange.sink { published.fulfill() }
        scheduledRecency.removeFirst()()
        wait(for: [published], timeout: 1)
        watch.cancel()
        XCTAssertTrue(model.inSidebarRecent(model.sessions.first { $0.id == b2 }!))
    }

    func testLeavingTheSidebarMidDragStillWaitsForTheDrop() {
        let model = makeModel(rows())
        model.sidebarPointerInside = true
        model.beginProjectDrag(Fixture.key("/p/b"))
        model.overlay.touch(SessionKey(id: "b2", host: .local), at: Date(timeIntervalSince1970: 100))
        scheduledRecency.removeFirst()()
        model.sidebarPointerInside = false
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"], "the drag holds it")
        model.endProjectDrag()
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a"])
    }

    func testCompactAge() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        func age(_ seconds: TimeInterval) -> String { RelativeTime.compact(from: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(age(30), "now")
        XCTAssertEqual(age(12 * 60), "12m")
        XCTAssertEqual(age(3 * 3600), "3h")
        XCTAssertEqual(age(2 * 86_400), "2d")
        XCTAssertEqual(age(15 * 86_400), "2w")
        XCTAssertEqual(age(65 * 86_400), "2mo")
        XCTAssertEqual(age(800 * 86_400), "2y")
        XCTAssertEqual(RelativeTime.compact(from: now.addingTimeInterval(60), now: now), "now", "a clock skewed ahead")
    }
}
