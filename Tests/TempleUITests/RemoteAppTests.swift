import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// The app model's side of sessions on hosts: the command line's close,
/// the notices, the launch-time contact, and remote project state.
@MainActor
final class RemoteAppTests: XCTestCase {
    let hostID = HostID(rawValue: "box")

    private func app(_ remote: FakeRemoteHost, db: TempleDB? = nil) throws -> AppModel {
        let local = Fixture.hostsWithoutFolderEvidence().entries[0]
        let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: hostID), launcher: remote)])
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try db ?? TempleDB.inMemory(),
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()), hostRegistry: hosts)
        app.start()
        return app
    }

    private func settle(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTheCommandLineRefusesAWorkingRemoteAgentDetachesWithForceAndStopsAnIdleOne() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        let tab = app.openSessions.newSession(agent: .claude, project: ProjectKey(host: hostID, path: "/home/u/p"))
        await settle { tab.hasLiveProcess }
        let id = try XCTUnwrap(tab.sessionID)
        tab.activity = .running

        let refused = await app.handleControl(ControlRequest(.sessionsClose, id: id))
        XCTAssertEqual(refused.error?.code, .refused)
        XCTAssertEqual(refused.error?.message, "Its agent is working on box. Pass --force to detach, or stop it in Temple.")
        XCTAssertNotNil(app.openSessions.openTab(forSessionID: id))

        let detached = await app.handleControl(ControlRequest(.sessionsClose, id: id, force: true))
        XCTAssertEqual(detached.session?.id, id)
        XCTAssertNil(app.openSessions.openTab(forSessionID: id))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(remote.stops.isEmpty, "--force detaches, never stops")

        let idle = app.openSessions.newSession(agent: .claude, project: ProjectKey(host: hostID, path: "/home/u/p"))
        await settle { idle.hasLiveProcess }
        idle.activity = .idle
        let closed = await app.handleControl(ControlRequest(.sessionsClose, id: try XCTUnwrap(idle.sessionID)))
        XCTAssertNil(closed.error)
        await settle { remote.stops.count == 1 }
        XCTAssertEqual(remote.stops.first?.fromAttachedTab, true, "an idle agent is stopped now, as ⌘W stops it")
    }

    func testALeftRunningCloseShowsOneNoticeAndShowOpensTheSheet() async throws {
        let remote = FakeRemoteHost("box")
        remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: nil)
        let app = try app(remote)
        let tab = app.openSessions.newSession(agent: .claude, project: ProjectKey(host: hostID, path: "/home/u/p"))
        await settle { tab.hasLiveProcess }
        tab.activity = .idle
        app.openSessions.closeTab(tab.id)
        await settle { app.remoteNotice != nil }
        XCTAssertEqual(app.remoteNotice?.message,
                       "Left running: box didn't answer when you closed it. Stop it under Sessions on box.")
        app.showRemoteSessions(hostID)
        XCTAssertEqual(app.remoteSessionsSheet?.host, hostID)
    }

    /// Launch: a host with flags whose line was never shown is asked once
    /// (a listing, nothing stopped); the line shows once per flag.
    func testTheLeftRunningLineShowsOncePerFlag() async throws {
        let remote = FakeRemoteHost("box")
        remote.unnoticed = 2
        let defaults = Fixture.uniqueDefaults()
        defaults.set(true, forKey: RemoteHostsModel.featureKey)
        defaults.set(try JSONEncoder().encode([["name": "box", "source": "config"]]), forKey: RemoteHostsModel.hostsKey)
        let local = Fixture.hostsWithoutFolderEvidence().entries[0]
        let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: hostID), launcher: remote)])
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory(),
                           settings: SettingsStore(defaults: defaults), hostRegistry: hosts,
                           remoteHosts: RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }))
        app.start()
        await settle { app.remoteNotice != nil }
        XCTAssertEqual(app.remoteNotice?.message, "2 sessions left running on box")
        XCTAssertTrue(remote.stops.isEmpty, "a contact lists; it never stops")
        app.dismissRemoteNotice()
        await settle { remote.unnoticed == 0 }
        XCTAssertEqual(remote.unnoticed, 0, "dismissed, it does not come back")
        XCTAssertNil(app.remoteNotice)
        XCTAssertEqual(RemoteCopy.leftRunningCount(1, host: "box"), "1 session left running on box")
    }

    func testRemoteProjectMasksLiveInTheRemoteStoreAndProjectStateIsUntouched() throws {
        let db = try TempleDB.inMemory()
        let remoteKey = ProjectKey(host: hostID, path: "/home/u/p")
        let localKey = ProjectKey(host: .local, path: "/l")
        let store = FakeRemoteProjects()
        store.states = [(remoteKey, true, 1)]
        let overlay = SessionOverlayStore(db: db)
        overlay.setProjectKeyOrder([localKey])
        overlay.remoteProjectState = store
        XCTAssertTrue(overlay.isProjectArchived(remoteKey), "loaded from the remote store")
        XCTAssertEqual(overlay.projectKeyOrder, [localKey, remoteKey], "the remote part at its place in the whole order")
        overlay.setProjectArchived(false, key: remoteKey)
        XCTAssertEqual(store.archived[remoteKey], false)
        overlay.setProjectArchived(true, key: remoteKey)
        XCTAssertEqual(store.archived[remoteKey], true)
        XCTAssertEqual(try db.projectStates().map(\.path), ["/l"], "project_state never meets a host's project")
        overlay.setProjectKeyOrder([remoteKey, localKey])
        XCTAssertEqual(store.order.map(\.key), [remoteKey])
        XCTAssertEqual(store.order.map(\.position), [0])
        // A Restore lifts a remote mask in the remote store; its Undo puts it back.
        try db.join(sessionID: "r1", via: .imported, agent: .claude, core: SessionCore(host: hostID, directory: remoteKey.path))
        let record = try XCTUnwrap(overlay.restoreSessions([], unmasking: [remoteKey]))
        XCTAssertEqual(store.archived[remoteKey], false)
        overlay.revert(record)
        XCTAssertEqual(store.archived[remoteKey], true)
    }

    final class FakeRemoteProjects: RemoteProjectStatePersisting {
        var states: [(key: ProjectKey, archived: Bool, position: Int?)] = []
        var archived: [ProjectKey: Bool] = [:]
        var order: [(key: ProjectKey, position: Int)] = []
        func projectStates() -> [(key: ProjectKey, archived: Bool, position: Int?)] { states }
        func setArchived(_ archived: Bool, key: ProjectKey) { self.archived[key] = archived }
        func setOrder(_ keys: [(key: ProjectKey, position: Int)]) { order = keys }
    }

    func testTheFolderSheetsHostsAndRecentFolders() async throws {
        let remote = FakeRemoteHost("box")
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("a", project: "/home/u/old", updated: 1, host: hostID),
                      Fixture.row("b", project: "/home/u/new", updated: 2, host: hostID),
                      Fixture.row("c", project: "/local", updated: 3)], to: db)
        let app = try app(remote, db: db)
        await settle { app.sessions.count == 3 }
        XCTAssertEqual(app.recentRemoteFolders(hostID), ["/home/u/new", "/home/u/old"])
        app.chooseRemoteFolder(host: hostID, agent: .claude)
        XCTAssertEqual(app.remoteFolderSheet?.host, hostID)
        app.startRemoteSession(host: hostID, agent: .claude, folder: "/home/u/new")
        XCTAssertNil(app.remoteFolderSheet)
        XCTAssertEqual(app.openSessions.activeTab?.projectKey, ProjectKey(host: hostID, path: "/home/u/new"))
    }

    /// Discard's row disposition acts only on the membership it was chosen
    /// for: a stale incarnation (the row left and joined again) changes nothing.
    func testDiscardDisposesOnlyTheSameMembership() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("d1", project: "/p", host: hostID)], to: db)
        let app = try app(FakeRemoteHost("box"), db: db)
        await settle { app.overlay.rows["d1"] != nil }
        let incarnation = try XCTUnwrap(app.overlay.rows["d1"]?.incarnation)
        try app.openSessions.remoteTabs.discardHandler?("d1", hostID, "another-membership")
        XCTAssertEqual(app.overlay.rows["d1"]?.archived, false, "a replaced row is left alone")
        try app.openSessions.remoteTabs.discardHandler?("d1", hostID, incarnation)
        await settle { app.overlay.rows["d1"]?.archived == true || app.overlay.rows["d1"] == nil }
        XCTAssertTrue(app.overlay.rows["d1"] == nil || app.overlay.rows["d1"]?.archived == true)
    }
}
