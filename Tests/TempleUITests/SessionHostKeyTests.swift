import XCTest
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// ADR-041 in the app: the same session id on two hosts (a transcript
/// copied with rsync, say) is two sessions, with two rows, two tabs and two
/// saved tabs, and nothing done to one reaches the other.
@MainActor
final class SessionHostKeyTests: XCTestCase {
    private let box = HostID(rawValue: "box")
    private let id = "68161a98-545a-42c0-b211-9914d7f5b900"

    private func joinBoth(_ db: TempleDB) throws {
        try db.join(sessionID: id, via: .opened, agent: .claude,
                    core: SessionCore(host: .local, directory: "/Users/me/work", directorySource: .tab, title: "Here"))
        try db.join(sessionID: id, via: .opened, agent: .claude,
                    core: SessionCore(host: box, directory: "/Users/me/work", directorySource: .tab, title: "There"))
    }

    func testBothHostsTabsOfOneIDAreSavedRestoredAndClosedApart() throws {
        let db = try TempleDB.inMemory()
        try joinBoth(db)
        let persistence = DBTabPersistence(db: db)
        persistence.save([
            PersistedTab(sessionID: id, host: .local, agent: .claude, projectPath: "/Users/me/work", title: "Here"),
            PersistedTab(sessionID: id, host: box, agent: .claude, projectPath: "/Users/me/work", title: "There"),
        ])
        XCTAssertEqual(try db.openTabRecords().map(\.host), [.local, box], "same folder path, same id: two saved tabs")

        let rows = try Dictionary(uniqueKeysWithValues: db.sessionStates().map { ($0.key, Session(state: $0)) })
        let model = OpenSessionsModel(surfaceFactory: FakeTerminalSurfaceFactory(), appearanceProvider: { .default },
            runtime: SessionRuntimeController(), registry: InMemoryProcessRegistry(), persistence: persistence)
        model.sessionRow = { rows[$0] }
        model.restore()
        XCTAssertEqual(model.tabs.map(\.sessionKey), [SessionKey(id: id, host: .local), SessionKey(id: id, host: box)])
        XCTAssertEqual(model.tabs.map(\.title), ["Here", "There"], "each chip takes its own host's row")
        XCTAssertEqual(Set(model.openProjectKeys), [Fixture.key("/Users/me/work"), Fixture.key("/Users/me/work", host: box)])
        XCTAssertTrue(model.openTab(for: SessionKey(id: id, host: box)) === model.tabs[1])

        model.closeTab(model.tabs[0].id)
        XCTAssertEqual(model.tabs.map(\.sessionKey), [SessionKey(id: id, host: box)], "closing this Mac's leaves the box's")
        XCTAssertEqual(try db.openTabRecords().map(\.host), [box])
    }

    func testOpenByIDOnTheOtherHostOpensItsOwnSession() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: id, via: .opened, agent: .claude,
                    core: SessionCore(host: .local, directory: "/Users/me/work", directorySource: .tab))
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        var resumed: [ResumeRequest] = []
        let sheet = OpenByIDSheetModel(request: OpenByIDRequest(host: box, sessionID: id), dependencies: .init(
            hosts: { [.local, self.box] },
            lookup: { _, _ in SessionLookup(agents: [.claude: .found(TranscriptLocator(host: self.box, path: "/h/\(self.id).jsonl"),
                                                                      directory: "/Users/me/work"), .codex: .notFound]) },
            checkFolder: { _, path in .exists(path) },
            member: { app.presentedByID[$0] },
            hasLiveTab: { app.openSessions.openTab(for: $0)?.hasSurface ?? false },
            openMember: { _ in XCTFail("this Mac's session is not the one asked for") },
            resume: { resumed.append($0); return true },
            configuration: { _ in 1 }, recentFolders: { _ in [] })) {}
        sheet.confirm()
        for _ in 0..<200 where sheet.check == .checking { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(sheet.check, .idle)
        XCTAssertEqual(resumed.map(\.host), [box])
        XCTAssertEqual(resumed.first?.id, id)
    }

    /// No `--host` means this Mac's session; `--host` names another
    /// machine's, and a host Temple doesn't have is said as that.
    func testTheCommandLineMeansThisMacUnlessTheHostIsNamed() async throws {
        let db = try TempleDB.inMemory()
        try joinBoth(db)
        try db.replaceOpenTabs([
            OpenTabRecord(projectPath: "/Users/me/work", sessionID: id, host: .local, position: 0, agent: "claude", title: "Here"),
            OpenTabRecord(projectPath: "/Users/me/work", sessionID: id, host: box, position: 0, agent: "claude", title: "There"),
        ])
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        XCTAssertEqual(app.openSessions.tabs.count, 2)

        let plain = await app.handleControl(ControlRequest(.sessionsGet, id: id))
        XCTAssertEqual(plain.session?.host, "", "no --host: this Mac's")
        XCTAssertEqual(plain.session?.title, "Here")
        let spelled = await app.handleControl(ControlRequest(.sessionsGet, id: id, host: "This Mac"))
        XCTAssertEqual(spelled.session?.host, "", "the tables' spelling names this Mac too")
        let nowhere = await app.handleControl(ControlRequest(.sessionsGet, id: id, host: "jet"))
        XCTAssertEqual(nowhere.error?.message, "Temple has no host named jet.")

        // Only the box has it open: no --host still means this Mac.
        app.openSessions.closeTab(try XCTUnwrap(app.openSessions.openTab(for: SessionKey(id: id, host: .local))).id)
        let notHere = await app.handleControl(ControlRequest(.sessionsClose, id: id))
        XCTAssertEqual(notHere.error?.code, .notFound)
        XCTAssertNotNil(app.openSessions.openTab(for: SessionKey(id: id, host: box)), "the box's tab is not closed on a guess")
    }

    /// A notification an older build posted names the id alone: it opens
    /// only when one host has that id, never a guess between two.
    func testALegacyNotificationOpensOnlyAnUnambiguousSession() throws {
        let db = try TempleDB.inMemory()
        try joinBoth(db)
        try db.join(sessionID: "solo", via: .opened, agent: .claude,
                    core: SessionCore(host: .local, directory: "/Users/me/solo", directorySource: .tab))
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence())
        app.start()
        app.activateNotified(id, host: nil)
        XCTAssertTrue(app.openSessions.tabs.isEmpty, "two hosts have it: nothing opens")
        app.activateNotified("solo", host: nil)
        XCTAssertEqual(app.openSessions.tabs.map(\.sessionKey), [SessionKey(id: "solo", host: .local)])
        app.activateNotified(id, host: .local)
        XCTAssertEqual(app.openSessions.activeTab?.sessionKey, SessionKey(id: id, host: .local))
    }
}
