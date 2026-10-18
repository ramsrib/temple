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
        XCTAssertEqual(refused.error?.message, "Its agent is working on box. Pass --force to detach it (it keeps running), or stop it in Temple.")
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
                       "The new Claude Code session in p wasn't stopped: box didn't answer when you closed its tab. It may still be running.")
        XCTAssertEqual(app.remoteNotice?.saysStillRunning, true, "orange")
        app.showRemoteSessions(hostID)
        XCTAssertEqual(app.remoteSessionsSheet?.host, hostID)
    }

    /// Launch: a host with flags whose line was never shown is asked once
    /// (a listing, nothing stopped); the line shows once per flag.
    func testTheLeftRunningLineShowsOncePerFlag() async throws {
        let remote = FakeRemoteHost("box")
        remote.unnoticed = 2
        let defaults = Fixture.uniqueDefaults()
        defaults.set(try JSONEncoder().encode([["name": "box", "source": "config"]]), forKey: RemoteHostsModel.hostsKey)
        let local = Fixture.hostsWithoutFolderEvidence().entries[0]
        let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: hostID), launcher: remote)])
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory(),
                           settings: SettingsStore(defaults: defaults), hostRegistry: hosts,
                           remoteHosts: RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }))
        app.start()
        await settle { app.remoteNotice != nil }
        XCTAssertEqual(app.remoteNotice?.message, "2 sessions you closed are still running on box.")
        XCTAssertTrue(remote.stops.isEmpty, "a contact lists; it never stops")
        app.dismissRemoteNotice()
        await settle { remote.unnoticed == 0 }
        XCTAssertEqual(remote.unnoticed, 0, "dismissed, it does not come back")
        XCTAssertNil(app.remoteNotice)
        XCTAssertEqual(RemoteCopy.leftRunningCount(1, host: "box"), "A session you closed is still running on box.")
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
        app.remoteSessionsSheet = nil
        // Any other remote sheet (the Hosts card's, a tab's confirmation)
        // is marked while it is up; nothing else changes the catcher.
        app.openSessions.showHome()
        XCTAssertTrue(catcher.handle(returnKey(), app), "no remote sheet: as before")
        let marker = UUID()
        app.openRemoteSheets.insert(marker)
        XCTAssertFalse(catcher.handle(returnKey(), app), "a marked remote sheet owns Return")
        app.openRemoteSheets.remove(marker)
        app.openSessions.showHome()
        XCTAssertTrue(catcher.handle(returnKey(), app))
    }

    /// A host's project heading is one line, like a local one: the name,
    /// then `@host` as the host spells it (never uppercased, never part of
    /// the name), at the local heading's 28pt. This Mac's projects are
    /// unchanged and carry no host.
    func testAHostsProjectHeadingPutsTheHostOnTheHeadingLine() {
        let remote = ProjectHeaderTitle(ProjectKey(host: HostID(rawValue: "Box-Mentes"), path: "/home/u/temple-cu-1a"))
        XCTAssertEqual(remote, ProjectHeaderTitle(name: "TEMPLE-CU-1A", host: "Box-Mentes"))
        XCTAssertEqual(remote.hostLabel, "@Box-Mentes", "as typed, not uppercased")
        XCTAssertEqual(ProjectHeaderTitle(ProjectKey(host: hostID, path: "/home/u/temple-cu-1a")).hostLabel, "@box")
        XCTAssertEqual(ProjectHeaderTitle.help(ProjectKey(host: hostID, path: "/home/u/temple-cu-1a")), "box:/home/u/temple-cu-1a")
        let local = ProjectHeaderTitle(ProjectKey(host: .local, path: "/Users/me/temple"))
        XCTAssertEqual(local, ProjectHeaderTitle(name: "TEMPLE", host: nil))
        XCTAssertNil(local.hostLabel)
        XCTAssertEqual(ProjectHeaderTitle.lineHeight, 28, "one height for every heading")
        XCTAssertEqual(ProjectHeaderTitle.help(ProjectKey(host: .local, path: "/Users/me/temple")), "")
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

    /// A yes for a Codex session that ended unidentified closes its tab;
    /// the selection follows the tab its close activated, as after any
    /// close, and nothing selects the identified row afterwards. That row
    /// shows the candidate's first prompt as its title (display only) until
    /// the transcript's title fact fills it, never "New Codex session", and
    /// the ended tab's terminal title is never written as its title.
    func testAYesForAnEndedCodexSessionHintsItsRowsTitleAndLeavesTheSelectionToTheFollower() async throws {
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
        chip.title = "Reply ok | temple-ux3"
        app.openSessions.remoteTabs.confirm(try XCTUnwrap(chip.remote?.suggestions.first), in: chip)
        await settle { !app.openSessions.tabs.contains { $0 === chip } }
        await settle { app.sessions.contains { $0.id == "c7" } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, "a", "the close activated the other tab")
        XCTAssertEqual(app.highlightedID, "a", "the selection follows it")
        let row = try XCTUnwrap(app.sessions.first { $0.id == "c7" })
        XCTAssertEqual(app.displayTitle(row), "hi", "the candidate's prompt, never the launcher placeholder")
        XCTAssertNil(row.state.title, "nothing written for it")
        app.overlay.flushPendingTitles()
        XCTAssertNil(try db.sessionState("c7")?.generatedTitle, "the terminal's title is not the session's")

        // The transcript's title fact arrives: it wins, and the hint goes.
        let summary = TranscriptSummary(id: "c7", agent: .codex,
                                        locator: TranscriptLocator(host: hostID, path: "/r/c7.jsonl"),
                                        modifiedAt: Date(), cwd: "/home/u/p", firstPrompt: "hi there")
        app.overlay.applyFacts(["c7": try XCTUnwrap(AuthorizedFacts.current(summary, in: db))])
        await settle { app.titleHints["c7"] == nil }
        XCTAssertNil(app.titleHints["c7"])
        XCTAssertEqual(app.displayTitle(try XCTUnwrap(app.sessions.first { $0.id == "c7" })), "hi there")
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
        for enabled in [true, false] {
            let hint = HostsSettingsSection.noDaemonHint(enabled: enabled)
            XCTAssertEqual(String(hint.characters), RemoteCopy.noDaemonHint(enabled: enabled))
            let flagged = hint.runs.filter { $0.font != nil }.map { String(hint[$0.range].characters) }
            XCTAssertEqual(flagged, ["--no-daemon"])
        }
        // Every flag in the Hosts notes is code, the arguments note's too.
        let note = HostsSettingsSection.flagsAsCode(HostsSettingsSection.argumentsNote)
        XCTAssertEqual(String(note.characters), HostsSettingsSection.argumentsNote)
        XCTAssertEqual(note.runs.filter { $0.font != nil }.map { String(note[$0.range].characters) },
                       ["--dangerously-skip-permissions"])
        let two = HostsSettingsSection.flagsAsCode("Use --a-b and --c, not -d.")
        XCTAssertEqual(two.runs.filter { $0.font != nil }.map { String(two[$0.range].characters) }, ["--a-b", "--c"])
        // The folder sheet's title leaves the host to its mono slot.
        XCTAssertEqual(RemoteCopy.folderSheetTitle(.claude), "New Claude Code session")
    }

    /// Discard's row disposition acts only on the membership it was chosen
    /// for: a stale incarnation (the row left and joined again) changes nothing.
    func testDiscardDisposesOnlyTheSameMembership() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("d1", project: "/p", host: hostID)], to: db)
        let app = try app(FakeRemoteHost("box"), db: db)
        await settle { app.overlay.rows["d1"] != nil }
        let incarnation = try XCTUnwrap(app.overlay.rows["d1"]?.incarnation)
        try app.openSessions.remoteTabs.discardHandler?("d1", hostID, "another-membership", nil)
        XCTAssertEqual(app.overlay.rows["d1"]?.archived, false, "a replaced row is left alone")
        try app.openSessions.remoteTabs.discardHandler?("d1", hostID, incarnation, nil)
        await settle { app.overlay.rows["d1"]?.archived == true || app.overlay.rows["d1"] == nil }
        XCTAssertTrue(app.overlay.rows["d1"] == nil || app.overlay.rows["d1"]?.archived == true)
    }

    /// Retiring a host takes its notice and any sheet asked for it with it,
    /// and nothing opens a sheet for a host that is not enabled (Sol
    /// round 1: no remote UI without an enabled host).
    func testRetiringAHostClearsItsNoticeAndSheets() throws {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(RemoteHostList(records: [.config("box")]).encode(), forKey: RemoteHostsModel.hostsKey)
        let hosts = RemoteHostsModel(defaults: defaults, readConfigAliases: { [] })
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: try TempleDB.inMemory(),
                           settings: SettingsStore(defaults: defaults),
                           hostRegistry: Fixture.hostsWithoutFolderEvidence(), remoteHosts: hosts)
        XCTAssertNotNil(app.remoteHost(hostID))
        app.remoteNotice = RemoteNotice(host: hostID, message: "Left running", kind: .closed)
        app.showRemoteSessions(hostID)
        XCTAssertEqual(app.remoteSessionsSheet?.host, hostID)
        app.chooseRemoteFolder(host: hostID, agent: .codex)
        XCTAssertEqual(app.remoteFolderSheet?.host, hostID)
        hosts.remove("box")
        XCTAssertNil(app.remoteNotice)
        XCTAssertNil(app.remoteSessionsSheet)
        XCTAssertNil(app.remoteFolderSheet)
        app.remoteNotice = RemoteNotice(host: hostID, message: "stale", kind: .closed)
        app.showRemoteSessions(hostID)
        XCTAssertNil(app.remoteSessionsSheet, "no sheet for a host that is not enabled")
        XCTAssertNil(app.remoteNotice)
        app.chooseRemoteFolder(host: hostID)
        XCTAssertNil(app.remoteFolderSheet)
    }

    /// Not this one on a session Temple linked on its own: the row the link
    /// made is archived as a person's archive (History restores it), the
    /// run is pending again, and nothing is stopped.
    func testNotThisOneArchivesTheLinkedRowReversibly() async throws {
        let remote = FakeRemoteHost("box")
        remote.excludesDeclined = true
        remote.suggestionsResult = .candidates([RemoteSuggestion(rolloutPath: "/r/c7.jsonl", sessionID: "c7",
                                                                 firstPrompt: "hi", startedAt: Date(),
                                                                 directory: "/home/u/p")])
        let app = try app(remote)
        app.openSessions.remoteTabs.identitySchedule = [0.01]
        app.openSessions.remoteTabs.identityInterval = 0.05
        let tab = app.openSessions.newSession(agent: .codex, project: ProjectKey(host: hostID, path: "/home/u/p"))
        await settle { tab.hasLiveProcess }
        app.openSessions.surfaceDidSubmitInput(try XCTUnwrap(tab.surface))
        await settle { tab.remote?.linkedOnItsOwn == true }
        XCTAssertEqual(app.overlay.rows["c7"]?.archived, false)
        app.openSessions.remoteTabs.unlink(tab)
        await settle { app.overlay.rows["c7"]?.archived == true }
        XCTAssertEqual(app.overlay.rows["c7"]?.archived, true, "archived, not deleted")
        XCTAssertNil(app.overlay.rows["c7"]?.archiveReason, "a person's archive: History's Restore brings it back")
        XCTAssertNil(tab.sessionID)
        await settle { remote.unlinks.count == 1 }
        XCTAssertTrue(remote.stops.isEmpty, "the agent keeps running")
        app.overlay.setArchived(false, sessionID: "c7")
        XCTAssertEqual(app.overlay.rows["c7"]?.archived, false, "restorable")
    }
}
