import XCTest
import Foundation
import AppKit
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

    /// Return in the folder sheet is the sheet's: with no tab active (the
    /// launcher on screen) the window's key catcher would otherwise take it
    /// as "open the highlighted sidebar row" and the sheet never saw it.
    func testTheFolderSheetOwnsReturnWhileTheLauncherIsOnScreen() async throws {
        let remote = FakeRemoteHost("box")
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("a", project: "/home/u/old", updated: 1, host: hostID)], to: db)
        let app = try app(remote, db: db)
        await settle { app.sessions.count == 1 }
        app.openSessions.showHome()
        let catcher = KeyCatcher.Coordinator()
        func returnKey() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                             keyCode: 36)!
        }
        XCTAssertTrue(catcher.handle(returnKey(), app), "without a sheet, Return opens the sidebar's row")
        app.openSessions.showHome()
        app.chooseRemoteFolder(host: hostID, agent: .claude)
        XCTAssertFalse(catcher.handle(returnKey(), app), "with the folder sheet up, Return goes to its field")
        XCTAssertFalse(catcher.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                       timestamp: 0, windowNumber: 0, context: nil, characters: "w",
                                                       charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!, app),
                       "and no shortcut acts behind it")
        app.remoteFolderSheet = nil
        app.showRemoteSessions(hostID)
        XCTAssertFalse(catcher.handle(returnKey(), app), "the Sessions sheet owns Return too")
    }

    /// A host's project heading: its first line is exactly a local one (the
    /// name, nothing else), and the host goes on a second line behind the
    /// globe, as the host spells it; the row grows from 28 to 44. This
    /// Mac's projects are unchanged.
    func testAHostsProjectHeadingPutsTheHostOnASecondLine() {
        let remote = ProjectHeaderTitle(ProjectKey(host: hostID, path: "/home/u/temple-cu-1a"))
        XCTAssertEqual(remote, ProjectHeaderTitle(name: "TEMPLE-CU-1A", hostLine: .init(glyph: "network", host: "box")))
        XCTAssertEqual(remote.rowHeight, 44)
        XCTAssertEqual(ProjectHeaderTitle.help(ProjectKey(host: hostID, path: "/home/u/temple-cu-1a")), "box:/home/u/temple-cu-1a")
        let local = ProjectHeaderTitle(ProjectKey(host: .local, path: "/Users/me/temple"))
        XCTAssertEqual(local, ProjectHeaderTitle(name: "TEMPLE", hostLine: nil))
        XCTAssertEqual(local.rowHeight, 28)
        XCTAssertEqual(ProjectHeaderTitle.help(ProjectKey(host: .local, path: "/Users/me/temple")), "")
        XCTAssertEqual(ProjectHeaderTitle.nameIndent, 18, "the host line starts under the name")
    }

    /// The sidebar's selection follows the active tab: a new Codex session
    /// on a host has no row until it is identified, so nothing is selected
    /// while it is active (the last tab's row stayed selected), and its row
    /// is the moment it has one.
    func testTheSelectionFollowsAPendingCodexTabAndItsIdentity() async throws {
        let remote = FakeRemoteHost("box")
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("a", project: "/home/u/p", host: hostID)], to: db)
        let app = try app(remote, db: db)
        await settle { app.sessions.count == 1 }
        app.openSessions.remoteTabs.recordPollDelays = [0.01]
        app.openSessions.remoteTabs.identitySchedule = [60]
        app.openSessions.openSession(try XCTUnwrap(app.sessions.first))
        await settle { app.highlightedID == "a" }
        XCTAssertEqual(app.highlightedID, "a")

        let codex = app.openSessions.newSession(agent: .codex, project: ProjectKey(host: hostID, path: "/home/u/p"))
        await settle { codex.hasLiveProcess && app.highlightedID == nil }
        XCTAssertNil(app.highlightedID, "the Codex tab is active; no row is it yet")

        remote.identityResult = .adopted("c9", directory: "/home/u/p")
        app.openSessions.remoteTabs.retryIdentity(codex)
        await settle { codex.sessionID == "c9" }
        await settle { app.highlightedID == "c9" }
        XCTAssertEqual(app.highlightedID, "c9", "identified while active: its row is selected")

        app.openSessions.activate(try XCTUnwrap(app.openSessions.openTab(forSessionID: "a")))
        await settle { app.highlightedID == "a" }
        app.openSessions.openSettings()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(app.highlightedID, "a", "a utility tab leaves the selection as it was")
    }

    /// A yes for a Codex session that ended unidentified closes its tab and
    /// selects its row, though the close activated another tab.
    func testAYesForAnEndedCodexSessionSelectsItsRow() async throws {
        let remote = FakeRemoteHost("box")
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("a", project: "/home/u/p", host: hostID)], to: db)
        let app = try app(remote, db: db)
        await settle { app.sessions.count == 1 }
        app.openSessions.openSession(try XCTUnwrap(app.sessions.first))
        remote.pending = [.init(handle: "p7", directory: "/home/u/p", ended: true, typed: true)]
        remote.suggestionsResult = .candidates([RemoteSuggestion(rolloutPath: "/r/c7.jsonl", sessionID: "c7",
                                                                 firstPrompt: "hi", startedAt: Date(), directory: "/home/u/p")])
        app.openSessions.remoteTabs.restorePending(hosts: [hostID])
        await settle { app.openSessions.tabs.contains { $0.remote?.handle == "p7" } }
        let chip = try XCTUnwrap(app.openSessions.tabs.first { $0.remote?.handle == "p7" })
        app.openSessions.activate(chip)
        await settle { chip.remote?.suggestions.count == 1 }
        app.openSessions.remoteTabs.confirm(try XCTUnwrap(chip.remote?.suggestions.first), in: chip)
        await settle { !app.openSessions.tabs.contains { $0 === chip } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, "a", "the close activated the other tab")
        XCTAssertEqual(app.highlightedID, "c7", "the now-identified row is selected")
        XCTAssertNotNil(app.overlay.rows["c7"])
    }

    /// The selection made again after the close's activation (sol rounds
    /// 1 and 2) replaces only the follower's write of the neighbour's row:
    /// a row the user selected meanwhile stays selected, even the
    /// neighbour's own row selected again.
    func testAYesForAnEndedCodexSessionNeverTakesANewerSelection() async throws {
        for chosen in ["b", "a"] {
            let remote = FakeRemoteHost("box")
            let db = try TempleDB.inMemory()
            Fixture.join([Fixture.row("a", project: "/home/u/p", host: hostID),
                          Fixture.row("b", project: "/home/u/p", host: hostID)], to: db)
            let app = try app(remote, db: db)
            await settle { app.sessions.count == 2 }
            app.openSessions.openSession(try XCTUnwrap(app.sessions.first { $0.id == "a" }))
            let hold = Gate()
            var reached = false
            app.rowSelectionTurn = { reached = true; await hold.wait() }
            remote.pending = [.init(handle: "p7", directory: "/home/u/p", ended: true, typed: true)]
            remote.suggestionsResult = .candidates([RemoteSuggestion(rolloutPath: "/r/c7.jsonl", sessionID: "c7",
                                                                     firstPrompt: "hi", startedAt: Date(), directory: "/home/u/p")])
            app.openSessions.remoteTabs.restorePending(hosts: [hostID])
            await settle { app.openSessions.tabs.contains { $0.remote?.handle == "p7" } }
            let chip = try XCTUnwrap(app.openSessions.tabs.first { $0.remote?.handle == "p7" })
            app.openSessions.activate(chip)
            await settle { chip.remote?.suggestions.count == 1 }
            app.openSessions.remoteTabs.confirm(try XCTUnwrap(chip.remote?.suggestions.first), in: chip)
            await settle { reached && app.highlightedID == "a" }
            XCTAssertEqual(app.highlightedID, "a", "the follower wrote the neighbour's row")
            app.highlightedID = chosen
            await hold.open()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(app.highlightedID, chosen, "the user's selection of \(chosen) stands")
        }
    }

    /// A session started on a host shows its project heading at once, from
    /// the folder typed, before the pane reports where it went: display
    /// only. Nothing is written for it; the reported folder is what the row
    /// records, and the hint goes.
    func testAHostProjectHeadingShowsFromTheTypedFolderUntilThePaneReports() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        app.openSessions.remoteTabs.recordPollDelays = [60]
        app.openSessions.remoteTabs.identitySchedule = [60]
        let typed = ProjectKey(host: hostID, path: "~/new")
        let claude = app.openSessions.newSession(agent: .claude, project: typed)
        await settle { claude.hasLiveProcess }
        let id = try XCTUnwrap(claude.sessionID)
        await settle { app.overlay.rows[id] != nil }
        let hinted = try XCTUnwrap(app.displayProjects.first { $0.key == typed }, "the heading is there at once")
        XCTAssertEqual(hinted.sessions.map(\.id), [id], "the row with no folder yet sits under it")
        XCTAssertNil(app.overlay.rows[id]?.directory, "nothing written to the row")
        XCTAssertFalse(app.overlay.projectKeyOrder.contains(typed), "nor to the project order")
        XCTAssertFalse(app.orderedVisibleProjectKeys.contains(typed), "and no Move or drag can persist it")

        let codex = app.openSessions.newSession(agent: .codex, project: ProjectKey(host: hostID, path: "~/cx"))
        await settle { codex.hasLiveProcess }
        let pending = try XCTUnwrap(app.displayProjects.first { $0.key == ProjectKey(host: hostID, path: "~/cx") })
        XCTAssertTrue(pending.sessions.isEmpty, "a pending Codex session: the heading alone")

        // The pane reports where it went: that folder wins and is recorded.
        app.openSessions.applyLaunchDirectory(claude, canonical: "/home/u/new")
        await settle { app.overlay.rows[id]?.directory == "/home/u/new" }
        await settle { app.displayProjects.contains { $0.key == ProjectKey(host: self.hostID, path: "/home/u/new") } }
        XCTAssertFalse(app.displayProjects.contains { $0.key == typed }, "the hint went")
        XCTAssertEqual(app.displayProjects.first { $0.key.path == "/home/u/new" }?.sessions.map(\.id), [id])
    }

    /// The --no-daemon hint reads as the copy says, the flag set as code.
    func testTheNoDaemonHintSetsTheFlagAsCode() {
        let hint = MainContentView.noDaemonHint
        XCTAssertEqual(String(hint.characters), RemoteCopy.noDaemonHint)
        let flagged = hint.runs.filter { $0.font != nil }.map { String(hint[$0.range].characters) }
        XCTAssertEqual(flagged, ["--no-daemon"])
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
