import XCTest
import Foundation
@testable import TempleCore
@testable import TempleUI
import TempleTestSupport

/// The behaviour the cold-read round changed (docs/designs/remote-ssh.md,
/// "Cold-read round"): Remove asks when sessions still run there; Detach
/// is a menu item; Running sessions opens or shows every row and dismisses
/// only a note; the folder sheet's Test connection runs the real test and
/// comes back; Stop asks first for a working agent; one tmux rule; and the
/// launch notice for sessions from before a quit. Copy is checked in
/// `RemoteCodexIdentityTests.testTheCopyIsOneSourceAndHasNoEmDash`; nothing
/// here pins a label a computer-use pass would read (docs/copy-review.md).
@MainActor
final class RemoteColdReadTests: XCTestCase {
    let hostID = HostID(rawValue: "box")
    /// The last app's database.
    private var db: TempleDB!

    /// An app with `box` added (from ~/.ssh/config) and registered to a
    /// scripted host.
    private func app(_ remote: FakeRemoteHost, records: [RemoteHostRecord] = [.config("box")]) throws -> AppModel {
        let defaults = Fixture.uniqueDefaults()
        defaults.set(RemoteHostList(records: records).encode(), forKey: RemoteHostsModel.hostsKey)
        let local = Fixture.hostsWithoutFolderEvidence().entries[0]
        let hosts = HostRegistry(entries: [local, .init(source: FakeHostSource(host: hostID), launcher: remote)])
        db = try TempleDB.inMemory()
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: defaults), hostRegistry: hosts,
                           remoteHosts: RemoteHostsModel(defaults: defaults, readConfigAliases: { [] }))
        app.start()
        app.openSessions.earlyExitGraceSeconds = 0.3
        app.openSessions.remoteTabs.recordPollDelays = [0.01]
        app.openSessions.settleDelaySeconds = 60
        return app
    }

    private func settle(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func running(_ handle: String, _ id: String?, agent: Agent = .claude) -> RemoteTrackedSession {
        RemoteTrackedSession(handle: handle, sessionID: id, agent: agent, state: .present(attached: false), leftRunning: nil)
    }

    private func connectedTab(_ app: AppModel, id: String = "s1") async throws -> SessionTab {
        let row = Fixture.row(id, project: "/home/u/p", host: hostID)
        Fixture.join([row], to: db)
        await settle { app.sessions.contains { $0.id == id } }
        app.openSessions.openSession(try XCTUnwrap(app.sessions.first { $0.id == id }))
        let tab = try XCTUnwrap(app.openSessions.activeTab)
        await settle { tab.hasLiveProcess }
        return tab
    }

    // MARK: Remove

    /// Remove asks the host first: nothing of Temple's running there (or no
    /// answer) removes at once; otherwise the alert gets what is running.
    func testRemoveWithNothingRunningOrNoAnswerRemovesAtOnce() async throws {
        for answer in [(sessions: [RemoteTrackedSession](), checked: true),
                       (sessions: [RemoteTrackedSession(handle: "h1", sessionID: "s1", agent: .claude,
                                                        state: .unknown("no answer"), leftRunning: nil)], checked: false)] {
            let remote = FakeRemoteHost("box")
            remote.tracked = answer
            let app = try app(remote)
            var asked: RemoteRemoval?? = .none
            app.requestRemoveHost("box") { asked = .some($0) }
            await settle { asked != nil }
            XCTAssertEqual(asked, .some(nil), "no alert")
            XCTAssertNil(app.remoteHosts.record(named: "box"), "removed at once")
            XCTAssertTrue(remote.stops.isEmpty)
        }
    }

    /// Running sessions there: the alert's two choices. "Remove, leave them
    /// running" removes and stops nothing; "Stop them and remove" stops each
    /// (no per-session question), then removes.
    func testRemoveWithRunningSessionsAsksAndBothChoicesDoWhatTheySay() async throws {
        let remote = FakeRemoteHost("box")
        remote.runs = [.init(handle: "h1", sessionID: "s1", resume: true), .init(handle: "h2", sessionID: "s2", resume: true)]
        remote.tracked = ([running("h1", "s1"), running("h2", "s2")], true)
        let app = try app(remote)
        var removal: RemoteRemoval?
        app.requestRemoveHost("box") { removal = $0 }
        await settle { removal != nil }
        let found = try XCTUnwrap(removal)
        XCTAssertEqual(found.live.map(\.handle), ["h1", "h2"])
        XCTAssertTrue(found.fromConfig, "the alert says ~/.ssh/config is not changed")
        XCTAssertNotNil(app.remoteHosts.record(named: "box"), "nothing is removed while the alert asks")

        app.removeHostLeavingSessions(found)
        XCTAssertNil(app.remoteHosts.record(named: "box"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(remote.stops.isEmpty, "left running")

        let second = FakeRemoteHost("box")
        second.runs = remote.runs
        second.tracked = remote.tracked
        let other = try self.app(second)
        var again: RemoteRemoval?
        other.requestRemoveHost("box") { again = $0 }
        await settle { again != nil }
        var failures: [String]?
        other.stopSessionsAndRemoveHost(try XCTUnwrap(again)) { failures = $0 }
        await settle { failures != nil }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(second.stops.map(\.handle).sorted(), ["h1", "h2"], "each stopped, none asked about")
        XCTAssertNil(other.remoteHosts.record(named: "box"), "then removed")
    }

    /// A stop that fails cancels the removal and says why.
    func testAStopThatFailsKeepsTheHost() async throws {
        let remote = FakeRemoteHost("box")
        remote.runs = [.init(handle: "h1", sessionID: "s1", resume: true)]
        remote.tracked = ([running("h1", "s1")], true)
        remote.stopResult = .leftRunning(.anotherClientAttached, detail: nil)
        let app = try app(remote, records: [RemoteHostRecord(name: "box", source: .temple, address: "10.0.0.2")])
        var removal: RemoteRemoval?
        app.requestRemoveHost("box") { removal = $0 }
        await settle { removal != nil }
        XCTAssertEqual(removal?.fromConfig, false)
        var failures: [String]?
        app.stopSessionsAndRemoveHost(try XCTUnwrap(removal)) { failures = $0 }
        await settle { failures != nil }
        XCTAssertEqual(failures?.count, 1)
        XCTAssertNotNil(app.remoteHosts.record(named: "box"), "a failed stop cancels the removal")
    }

    /// Both kinds of host offer the same four actions; a config host opens
    /// ~/.ssh/config where one added by address has Edit.
    func testConfigRowsOpenTheConfigWhereAddedRowsEdit() {
        typealias Action = HostsSettingsSection.HostAction
        XCTAssertEqual(HostsSettingsSection.actions(for: .config("box")), [Action.test, .runningSessions, .openConfig, .remove])
        let added = RemoteHostRecord(name: "build-box", source: .temple, address: "10.0.0.2")
        XCTAssertEqual(HostsSettingsSection.actions(for: added), [Action.test, .runningSessions, .edit, .remove])
        XCTAssertEqual(Action.runningSessions.title("build-box"), RemoteCopy.sessionsOnMenuItem("build-box"),
                       "the link names the host in full")
    }

    // MARK: Detach, Stop, Archive

    /// Detach (the row's and the tab's menus, File): the tab closes, the
    /// agent keeps running whether it was working or waiting, the row stays.
    func testDetachClosesTheTabAndLeavesTheAgentRunning() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        let tab = try await connectedTab(app)
        tab.activity = .idle
        app.openSessions.remoteTabs.detach(tab.id)
        XCTAssertFalse(app.openSessions.tabs.contains { $0 === tab })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(remote.stops.isEmpty, "a waiting agent keeps running too")
        XCTAssertNotNil(app.overlay.rows["s1"], "its row stays")
        XCTAssertTrue(app.openSessions.remoteTabs.hasRun(sessionID: "s1", host: hostID))
    }

    /// Stop asks first only for a working agent: a live tab whose agent is
    /// busy. One waiting for input, or with no tab here, stops at once.
    func testOnlyAWorkingAgentIsAskedAboutBeforeAStop() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        let tab = try await connectedTab(app)
        let handle = try XCTUnwrap(tab.remote?.handle)
        tab.activity = .running
        app.openSessions.lastTitleChange[tab.id] = Date()
        tab.inputSubmitted = true
        XCTAssertTrue(app.openSessions.remoteTabs.workingTab(host: hostID, sessionID: "s1") === tab)
        XCTAssertTrue(app.openSessions.remoteTabs.workingTab(host: hostID, handle: handle) === tab)
        tab.activity = .idle
        XCTAssertNil(app.openSessions.remoteTabs.workingTab(host: hostID, sessionID: "s1"), "waiting: no question")
        XCTAssertNil(app.openSessions.remoteTabs.workingTab(host: hostID, sessionID: "other"), "no tab here")
    }

    /// A row whose agent still runs on its host can't be archived until it
    /// is stopped (named, as "Close tab to archive" is); local rows are as
    /// they were.
    func testArchiveWaitsForALiveAgentOnTheHost() async throws {
        let remote = FakeRemoteHost("box")
        remote.runs = [.init(handle: "h9", sessionID: "s9", resume: true)]
        let app = try app(remote)
        let row = Fixture.row("s9", project: "/home/u/p", host: hostID)
        Fixture.join([row], to: db)
        await settle { app.sessions.contains { $0.id == "s9" } }
        let session = try XCTUnwrap(app.sessions.first { $0.id == "s9" })
        XCTAssertEqual(app.archiveBlocker(session), RemoteCopy.stopToArchive("box"))
        remote.runs[0].ended = true
        XCTAssertNil(app.archiveBlocker(session), "stopped: it can be archived")
        let local = Fixture.row("l1", project: "/Users/me/p")
        Fixture.join([local], to: db)
        await settle { app.sessions.contains { $0.id == "l1" } }
        XCTAssertNil(app.archiveBlocker(try XCTUnwrap(app.sessions.first { $0.id == "l1" })))
    }

    // MARK: Running sessions

    /// Every row not in a tab offers Open (a tab attached to it, as the
    /// sidebar row opens it); one in a tab here offers Show tab (that tab).
    /// Dismiss is only on a row with a left-running note, and clears it.
    func testRunningSessionsOpensShowsAndDismissesOnlyNotes() async throws {
        let remote = FakeRemoteHost("box")
        remote.runs = [.init(handle: "h9", sessionID: "s9", resume: true)]
        let app = try app(remote)
        let row = Fixture.row("s9", project: "/home/u/p", host: hostID)
        Fixture.join([row], to: db)
        await settle { app.sessions.contains { $0.id == "s9" } }
        app.showRemoteSessions(hostID)
        let sheet = app.sessionsSheetModel(try XCTUnwrap(app.remoteSessionsSheet))
        let session = running("h9", "s9")
        XCTAssertFalse(app.openSessions.remoteTabs.hasLiveTab(handle: "h9", host: hostID), "Open, not Show tab")
        sheet.open(session, rows: app.sessions)
        let tab = try XCTUnwrap(app.openSessions.openTab(forSessionID: "s9"))
        await settle { tab.hasLiveProcess }
        XCTAssertEqual(remote.opens.last?.sessionID, "s9")
        XCTAssertEqual(tab.remote?.handle, "h9", "attached to the running session")
        XCTAssertTrue(app.openSessions.remoteTabs.hasLiveTab(handle: "h9", host: hostID), "now Show tab")
        app.openSessions.showHome()
        sheet.showTab(session)
        XCTAssertTrue(app.openSessions.activeTab === tab, "Show tab focuses it")

        let flagged = RemoteTrackedSession(handle: "h9", sessionID: "s9", agent: .claude, state: .present(attached: false),
                                           leftRunning: .hostDidNotAnswer)
        XCTAssertFalse(RemoteSessionsSheet.offersDismiss(session, dismissed: []), "no note, nothing to dismiss")
        XCTAssertTrue(RemoteSessionsSheet.offersDismiss(flagged, dismissed: []))
        sheet.dismissNote(flagged)
        XCTAssertFalse(RemoteSessionsSheet.offersDismiss(flagged, dismissed: sheet.dismissedNotes), "the note goes")
        await settle { remote.kept == ["h9"] }
        XCTAssertEqual(remote.kept, ["h9"], "its flag is cleared")
        XCTAssertTrue(remote.stops.isEmpty, "it keeps running")
    }

    /// A Stop from the sheet that fails is said under its row, still
    /// running (orange in the view).
    func testAFailedStopInTheSheetSaysSo() async throws {
        let remote = FakeRemoteHost("box")
        remote.runs = [.init(handle: "h9", sessionID: "s9", resume: true)]
        remote.stopResult = .leftRunning(.hostDidNotAnswer, detail: "no answer")
        let app = try app(remote)
        app.showRemoteSessions(hostID)
        let sheet = app.sessionsSheetModel(try XCTUnwrap(app.remoteSessionsSheet))
        sheet.stop(running("h9", "s9"))
        await settle { sheet.results["h9"] != nil }
        XCTAssertEqual(sheet.results["h9"], RemoteCopy.notStoppedLine(.hostDidNotAnswer, detail: "no answer"))
    }

    // MARK: The folder sheet

    /// Test connection runs the host's real test (not Settings), keeps the
    /// typed path, and a test that passed checks the folder again; one that
    /// failed leaves the sheet as it was.
    func testTheFolderSheetsTestConnectionRunsTheTestAndComesBack() async throws {
        let remote = FakeRemoteHost("box")
        remote.folder = .transport("ssh: connect to host box port 22: Connection refused")
        let app = try app(remote)
        app.chooseRemoteFolder(host: hostID, agent: .claude)
        let sheet = app.folderSheetModel(try XCTUnwrap(app.remoteFolderSheet))
        sheet.path = "~/Projects/temple"
        sheet.confirm()
        await settle { if case .unreachable = sheet.check { true } else { false } }
        let test = try XCTUnwrap(sheet.testConnection(), "the host's own test")
        XCTAssertEqual(test.record.name, "box")
        XCTAssertNil(app.openSessions.activeTab, "Settings is not opened")
        test.cancel()
        sheet.testClosed(test)
        XCTAssertEqual(sheet.path, "~/Projects/temple", "back with the typed path")
        if case .unreachable = sheet.check {} else { XCTFail("an unfinished test checks nothing: \(sheet.check)") }
        app.remoteHosts.endTest(test)
    }

    // MARK: One tmux rule

    /// A host whose last test proved tmux missing or older than 3.2: no
    /// start-page row, no ⌘N row, and the folder sheet won't start, with
    /// the host's line.
    func testOneTmuxRule() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        XCTAssertEqual(app.remoteLaunchHosts, [hostID])
        XCTAssertNil(app.remoteTmuxProblem(hostID))
        for tmux in [TempleRemoteHostTmux.tooOld, .missing] {
            app.remoteHosts.recordSummary(tmux.summary, for: "box")
            XCTAssertEqual(app.remoteLaunchHosts, [], "left out of the launcher and ⌘N")
            let line = try XCTUnwrap(app.remoteTmuxProblem(hostID))
            XCTAssertTrue(line.contains("3.2 or newer"), line)
            app.chooseRemoteFolder(host: hostID, agent: .claude)
            let sheet = app.folderSheetModel(try XCTUnwrap(app.remoteFolderSheet))
            XCTAssertEqual(sheet.tmuxProblem, line)
            sheet.path = "~/p"
            sheet.confirm()
            sheet.startAnyway()
            XCTAssertEqual(sheet.check, .idle, "Start does nothing")
            XCTAssertTrue(app.openSessions.tabs.isEmpty)
        }
        app.remoteHosts.recordSummary(TempleRemoteHostTmux.refused.summary, for: "box")
        XCTAssertEqual(app.remoteLaunchHosts, [hostID], "a refusal is said, not the rule")
    }

    // MARK: The launch notice

    /// A quit leaves every agent on a host running and flags each connected
    /// tab's run; at the next launch a host that answers says how many are
    /// still running, once, and Running sessions… or × marks them seen.
    func testTheLaunchNoticeSaysSessionsFromBeforeTheQuitOnce() async throws {
        let remote = FakeRemoteHost("box")
        remote.unnoticedQuit = 2
        let app = try app(remote)
        await settle { app.remoteNotice != nil }
        XCTAssertEqual(app.remoteNotice?.message, RemoteCopy.quitCount(2, host: "box"))
        XCTAssertEqual(app.remoteNotice?.saysStillRunning, true)
        app.showRemoteSessions(hostID)
        XCTAssertNil(app.remoteNotice)
        await settle { remote.unnoticedQuit == 0 }
        XCTAssertEqual(remote.unnoticedQuit, 0, "seen: it does not come back")
        XCTAssertTrue(remote.stops.isEmpty, "a contact never stops anything")

        let both = FakeRemoteHost("box")
        both.unnoticed = 1
        both.unnoticedQuit = 1
        let other = try self.app(both)
        await settle { other.remoteNotice != nil }
        XCTAssertEqual(other.remoteNotice?.message,
                       RemoteCopy.leftRunningCount(1, host: "box") + " " + RemoteCopy.quitCount(1, host: "box"))
        other.dismissRemoteNotice()
        await settle { both.unnoticed == 0 && both.unnoticedQuit == 0 }
    }

    /// Only a tab connected at the quit is flagged: a disconnected one, or
    /// a host with none, gives no launch notice.
    func testOnlyConnectedTabsAreFlaggedAtTheQuit() async throws {
        let remote = FakeRemoteHost("box")
        let app = try app(remote)
        let tab = try await connectedTab(app)
        try await Task.sleep(for: .milliseconds(400))
        (tab.surface as? FakeTerminalSurface)?.simulateExit(status: 0)
        await settle { tab.remote?.phase == .disconnected }
        let connected = try await connectedTab(app, id: "s2")
        app.openSessions.prepareForQuit()
        _ = app.openSessions.quitDrainPlan()
        await settle { !remote.leftRunningCalls.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(remote.leftRunningCalls.map(\.handle), [try XCTUnwrap(connected.remote?.handle)])
        XCTAssertEqual(remote.leftRunningCalls.map(\.reason), [.detachedAtQuit])
    }
}

/// Test summaries for the tmux rule.
private enum TempleRemoteHostTmux {
    case tooOld, missing, refused

    var summary: HostTestSummary {
        switch self {
        case .tooOld: HostTestSummary(tmux: .tooOld(version: "3.0a"))
        case .missing: HostTestSummary(tmux: .missing)
        case .refused: HostTestSummary(tmux: .refused(version: "3.4", command: "new-session", line: "no server"))
        }
    }
}
