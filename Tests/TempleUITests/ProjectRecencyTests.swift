import XCTest
@testable import TempleUI
import TempleCore

/// ⌘P walks projects most recently used first. That order lived in memory
/// only, so a relaunch kept the project you quit in and put the rest back in
/// tab order: "my recent project ordering is not right".
@MainActor
final class ProjectRecencyTests: XCTestCase {
    private let a = ProjectKey(host: .local, path: "/work/a")
    private let b = ProjectKey(host: .local, path: "/work/b")
    private let c = ProjectKey(host: .local, path: "/work/c")

    private func launch(_ db: TempleDB) -> AppModel {
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                           engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
                           database: db, settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        app.start()
        return app
    }

    /// Opens one session in each of a, b, c (in that order), then goes back
    /// to a: recency is a, c, b, while tab order — what a relaunch fell back
    /// to — is a, b, c.
    private func useThreeProjects(_ app: AppModel) throws {
        for (id, key) in [("sa", a), ("sb", b), ("sc", c)] {
            app.openSessions.openSession(Fixture.row(id, project: key.path))
        }
        app.openSessions.activateProject(a)
        XCTAssertEqual(app.switchableProjectKeys, [a, c, b])
    }

    func testRecencySurvivesRelaunch() throws {
        let db = try TempleDB.inMemory()
        let first = launch(db)
        try useThreeProjects(first)
        first.openSessions.prepareForQuit()

        let relaunched = launch(db)
        XCTAssertEqual(relaunched.openSessions.activeProjectKey, a)
        XCTAssertEqual(relaunched.switchableProjectKeys, [a, c, b], "not tab order behind the active project")
    }

    /// The order is current at every switch, not only at a clean quit: a
    /// crash after the switch loses nothing.
    func testRecencyIsSavedAtTheSwitchNotAtQuit() throws {
        let db = try TempleDB.inMemory()
        let first = launch(db)
        try useThreeProjects(first)
        first.openSessions.activateProject(b)

        XCTAssertEqual(DBTabPersistence(db: db).loadProjectRecency(), [b, a, c])
    }

    /// Only projects with a tab open are switchable. Closing a project's last
    /// tab forgets it, in the stored list as in memory, and a project whose
    /// tabs did not come back is dropped at launch.
    func testOnlyProjectsWithTabsAreKept() throws {
        let db = try TempleDB.inMemory()
        let first = launch(db)
        try useThreeProjects(first)
        let tab = try XCTUnwrap(first.openSessions.openTab(forSessionID: "sc"))
        first.openSessions.closeTab(tab.id)
        XCTAssertEqual(DBTabPersistence(db: db).loadProjectRecency(), [a, b])

        // A stale list naming a project with no tab at launch.
        DBTabPersistence(db: db).saveProjectRecency([c, b, a])
        let relaunched = launch(db)
        XCTAssertEqual(relaunched.switchableProjectKeys, [a, b])
        XCTAssertEqual(DBTabPersistence(db: db).loadProjectRecency(), [a, b], "the active project moved to the front")
    }

    func testClosingEveryTabClearsTheKey() throws {
        let db = try TempleDB.inMemory()
        let app = launch(db)
        app.openSessions.openSession(Fixture.row("only", project: a.path))
        XCTAssertNotNil(try db.uiState(UIStateStore.Key.projectRecency))
        app.openSessions.closeTab(try XCTUnwrap(app.openSessions.openTab(forSessionID: "only")).id)
        XCTAssertNil(try db.uiState(UIStateStore.Key.projectRecency), "absent, not an empty list")
    }

    /// The same folder on two hosts is two projects, and stays two after a
    /// round trip.
    func testRecencyKeepsTheHost() throws {
        let db = try TempleDB.inMemory()
        let remote = ProjectKey(host: HostID(rawValue: "devbox"), path: a.path)
        DBTabPersistence(db: db).saveProjectRecency([remote, a])
        XCTAssertEqual(DBTabPersistence(db: db).loadProjectRecency(), [remote, a])
    }

    /// Unreadable means "follow tab order", never a throw and never another
    /// key's loss: the sidebar's state sits in the same table.
    func testAnUnreadableValueFallsBackToTabOrder() throws {
        let db = try TempleDB.inMemory()
        let first = launch(db)
        try useThreeProjects(first)
        first.sidebarVisibility = .detailOnly
        first.openSessions.prepareForQuit()
        try db.setUIState("{not json", for: UIStateStore.Key.projectRecency)

        let relaunched = launch(db)
        XCTAssertEqual(relaunched.switchableProjectKeys, [a, b, c])
        XCTAssertEqual(relaunched.sidebarVisibility, .detailOnly)
    }

    /// One bad element costs that element, not the list.
    func testMalformedElementsAreDropped() {
        let stored = """
        [{"host":"","path":"/work/b"}, 42, {"host":""}, {"path":""}, {"path":"/work/c"},
         {"host":"","path":"/work/b"}]
        """
        XCTAssertEqual(ProjectRecencyCodec.decode(stored), [b, c], "a missing host is this Mac; duplicates collapse")
        XCTAssertEqual(ProjectRecencyCodec.decode("\"/work/a\""), [])
        XCTAssertEqual(ProjectRecencyCodec.decode(nil), [])
    }

    func testTheListIsCapped() {
        let many = (0..<200).map { ProjectKey(host: .local, path: "/p\($0)") }
        let decoded = ProjectRecencyCodec.decode(ProjectRecencyCodec.encode(many))
        XCTAssertEqual(decoded, Array(many.prefix(ProjectRecencyCodec.limit)))
        XCTAssertNil(ProjectRecencyCodec.encode([]))
    }
}
