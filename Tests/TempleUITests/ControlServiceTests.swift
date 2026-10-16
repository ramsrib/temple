import XCTest
@testable import TempleCore
@testable import TempleUI
@testable import TempleLocalHost

/// The app's side of the command line (ADR-034): it answers from the open
/// tabs and acts through the app's own calls, guards included.
@MainActor
final class ControlServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func model(_ db: TempleDB, hosts: HostRegistry? = nil) -> AppModel {
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), database: db,
                           settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                           hostRegistry: hosts ?? Fixture.hostsWithoutFolderEvidence())
        app.start()
        return app
    }

    private func ask(_ app: AppModel, _ request: ControlRequest) async -> ControlResponse {
        await app.handleControl(request)
    }

    func testListsOpenTabsByProjectWithWhatEachIsDoing() async throws {
        let app = model(try TempleDB.inMemory())
        let a = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p/a"))
        let pending = app.openSessions.newSession(agent: .codex, project: Fixture.key("/p/b"))
        let a2 = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p/a"))
        a.activity = .needsAttention

        let sessionsAnswer = await ask(app, ControlRequest(.sessionsList))
        let sessions = try XCTUnwrap(sessionsAnswer.sessions)
        XCTAssertEqual(sessions.map(\.id), [a.sessionID, a2.sessionID, nil], "grouped by project, then strip order")
        XCTAssertEqual(sessions[0].state, .attention)
        XCTAssertEqual(sessions[2].cli, .codex)
        XCTAssertNil(pending.sessionID, "a new Codex session is pending until its rollout appears")
        XCTAssertEqual(sessions.filter(\.focused).map(\.id), [a2.sessionID])

        let projectsAnswer = await ask(app, ControlRequest(.projectsList))
        let projects = try XCTUnwrap(projectsAnswer.projects)
        XCTAssertEqual(projects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertEqual(projects.map(\.sessions), [2, 1])
        XCTAssertEqual(projects.filter(\.focused).map(\.path), ["/p/a"])

        let codex = await ask(app, ControlRequest(.sessionsList, cli: .codex)).sessions
        XCTAssertEqual(codex?.count, 1)
        let inA = await ask(app, ControlRequest(.sessionsList, directory: "/p/a")).sessions
        XCTAssertEqual(inA?.count, 2)
        let project = await ask(app, ControlRequest(.projectsGet, directory: "/p/b"))
        XCTAssertEqual(project.project?.sessions, 1)
        XCTAssertEqual(project.sessions?.count, 1)
        let none = await ask(app, ControlRequest(.projectsGet, directory: "/p/none"))
        XCTAssertEqual(none.error?.code, .notFound)
    }

    func testARestoredChipSaysSo() async throws {
        let db = try TempleDB.inMemory()
        let first = model(db)
        let background = first.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let onScreen = first.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let backgroundID = try XCTUnwrap(background.sessionID), onScreenID = try XCTUnwrap(onScreen.sessionID)
        first.openSessions.prepareForQuit()
        let second = model(db)
        let sessions = await ask(second, ControlRequest(.sessionsList)).sessions
        XCTAssertEqual(sessions?.first { $0.id == backgroundID }?.state, .restored, "not started until it is shown")
        XCTAssertNotEqual(sessions?.first { $0.id == onScreenID }?.state, .restored, "the tab on screen starts")
    }

    func testCloseRefusesAWorkingAgentUnlessForced() async throws {
        let app = model(try TempleDB.inMemory())
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        tab.activity = .running

        let refused = await ask(app, ControlRequest(.sessionsClose, id: id))
        XCTAssertEqual(refused.error?.code, .refused)
        XCTAssertNotNil(app.openSessions.openTab(forSessionID: id), "nothing closed")

        let closed = await ask(app, ControlRequest(.sessionsClose, id: id, force: true))
        XCTAssertEqual(closed.session?.id, id)
        XCTAssertNil(app.openSessions.openTab(forSessionID: id))

        let again = await ask(app, ControlRequest(.sessionsClose, id: id))
        XCTAssertEqual(again.error?.code, .notFound)
    }

    func testAnIdleAgentClosesWithoutForce() async throws {
        let app = model(try TempleDB.inMemory())
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        tab.activity = .idle
        let id = try XCTUnwrap(tab.sessionID)
        let answer1 = await ask(app, ControlRequest(.sessionsClose, id: id))
        XCTAssertNil(answer1.error)
        XCTAssertNil(app.openSessions.openTab(forSessionID: id))
    }

    /// The CLI's close takes ⌘W's early rule (nothing done since the spawn,
    /// title quiet: at rest) and its guard otherwise, deciding without
    /// touching the tab: an expired request leaves it as it was.
    func testCloseTakesTheEarlyRestRuleAndAnExpiredOneChangesNothing() async throws {
        let app = model(try TempleDB.inMemory())
        app.openSessions.titleQuietWindow = 0.1
        let quiet = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let quietID = try XCTUnwrap(quiet.sessionID)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(quiet.activity, .running)
        let commit = ControlCommit()
        _ = commit.expire()
        _ = await app.handleControl(ControlRequest(.sessionsClose, id: quietID), commit: commit)
        XCTAssertEqual(quiet.activity, .running, "an expired close changes nothing")
        XCTAssertNotNil(app.openSessions.openTab(forSessionID: quietID))
        let closed = await ask(app, ControlRequest(.sessionsClose, id: quietID))
        XCTAssertNil(closed.error)
        XCTAssertEqual(closed.session?.state, .idle, "it closed an agent at rest")
        XCTAssertNil(app.openSessions.openTab(forSessionID: quietID))

        let asked = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let askedID = try XCTUnwrap(asked.sessionID)
        (asked.surface as? FakeTerminalSurface)?.simulateSubmitInput()
        (asked.surface as? FakeTerminalSurface)?.simulateTitle("running a long tool")
        try await Task.sleep(for: .milliseconds(200))
        let refused = await ask(app, ControlRequest(.sessionsClose, id: askedID))
        XCTAssertEqual(refused.error?.code, .refused, "after a Return it is working")
        XCTAssertEqual(asked.activity, .running)
    }

    func testGetGivesTheResumeCommand() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("m-1", project: "/p")], to: db)
        let app = model(db)
        try await settle { !app.sessions.isEmpty }
        app.openSession(id: "m-1")
        let id = "m-1"
        let session = await ask(app, ControlRequest(.sessionsGet, id: id)).session
        XCTAssertEqual(session?.resumeCommand, ["claude", "--resume", id])
        let answer2 = await ask(app, ControlRequest(.sessionsList))
        XCTAssertNil(answer2.sessions?.first?.resumeCommand, "get only")
        let answer3 = await ask(app, ControlRequest(.sessionsGet, id: "nope"))
        XCTAssertEqual(answer3.error?.code, .notFound)
    }

    func testSearchRanksOpenSessionsOnly() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("open-1", project: "/p", title: "fix the keychain prompt"),
                      Fixture.row("closed-1", project: "/p", title: "keychain prompt, closed")], to: db)
        let app = model(db)
        app.openSession(id: "open-1")
        try await settle { app.openSessions.openTab(forSessionID: "open-1") != nil }
        let found = await ask(app, ControlRequest(.sessionsSearch, term: "keychain")).sessions
        XCTAssertEqual(found?.map(\.id), ["open-1"])
        let answer4 = await ask(app, ControlRequest(.sessionsSearch, term: "  "))
        XCTAssertEqual(answer4.error?.code, .invalid)
    }

    func testNewKeepsTheSpellingTempleAlreadyHasForTheFolder() async throws {
        let folder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let known = folder.path  // /private/tmp/…
        let other = known.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("known", project: known)], to: db)
        let app = model(db)
        try await settle { !app.sessions.isEmpty }

        let started = await ask(app, ControlRequest(.sessionsNew, directory: other, cli: .codex)).session
        XCTAssertEqual(started?.project, known)
        XCTAssertEqual(started?.cli, .codex)
        XCTAssertNil(started?.id, "a Codex session is pending")
        XCTAssertEqual(app.openSessions.activeTab?.projectPath, known)

        let missing = await ask(app, ControlRequest(.sessionsNew, directory: root.appendingPathComponent("gone").path))
        XCTAssertEqual(missing.error?.code, .notFound)
    }

    func testNewUsesTheDefaultCLIWhenNoneIsNamed() async throws {
        let app = model(try TempleDB.inMemory())
        app.settings.defaultAgent = .codex
        let started = await ask(app, ControlRequest(.sessionsNew, directory: root.path)).session
        XCTAssertEqual(started?.cli, .codex)
    }

    func testOpenResumesAMemberAndFocusesAnOpenOne() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("m-1", project: "/p", title: "member")], to: db)
        let app = model(db)
        try await settle { !app.sessions.isEmpty }

        let opened = await ask(app, ControlRequest(.sessionsOpen, id: "m-1"))
        XCTAssertEqual(opened.session?.id, "m-1")
        let tab = try XCTUnwrap(app.openSessions.openTab(forSessionID: "m-1"))
        let other = app.openSessions.newSession(agent: .claude, project: Fixture.key("/q"))
        XCTAssertEqual(app.openSessions.activeTabID, other.id)

        _ = await ask(app, ControlRequest(.sessionsOpen, id: "m-1"))
        XCTAssertEqual(app.openSessions.activeTabID, tab.id, "an open session is focused, not opened twice")
        XCTAssertEqual(app.openSessions.tabs.filter { $0.sessionID == "m-1" }.count, 1)
    }

    func testOpenRefusesAMemberThatCannotResumeAndChangesNothing() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("no-folder", project: nil)], to: db)
        let app = model(db)
        try await settle { !app.sessions.isEmpty }
        let response = await ask(app, ControlRequest(.sessionsOpen, id: "no-folder"))
        XCTAssertEqual(response.error?.code, .refused)
        XCTAssertTrue(app.openSessions.tabs.filter { $0.kind == .session }.isEmpty)
    }

    /// A session Temple has never seen is found the way History finds it,
    /// and joins as opened.
    func testOpenFindsASessionOutsideTempleInTheStores() async throws {
        let store = root.appendingPathComponent("claude")
        let project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "11111111-2222-4333-8444-555555555555"
        let folder = store.appendingPathComponent(project.path.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = #"{"type":"user","message":{"role":"user","content":"outside work"},"cwd":"\#(project.path)","timestamp":"2026-10-13T19:34:06.726Z","sessionId":"\#(id)"}"#
        try Data((line + "\n").utf8).write(to: folder.appendingPathComponent("\(id).jsonl"))
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: store)], debounceInterval: 0.01, monitorChanges: false)
        let hosts = HostRegistry(entries: [.init(source: source, launcher: LocalHostLauncher(folderEvidence: { _ in .exists }))])
        let db = try TempleDB.inMemory()
        let app = model(db, hosts: hosts)

        let opened = await ask(app, ControlRequest(.sessionsOpen, id: id))
        XCTAssertNil(opened.error, opened.error?.message ?? "")
        XCTAssertEqual(opened.session?.project, project.path)
        XCTAssertNotNil(app.openSessions.openTab(forSessionID: id))

        let unknown = await ask(app, ControlRequest(.sessionsOpen, id: "99999999-0000-4000-8000-000000000000"))
        XCTAssertEqual(unknown.error?.code, .notFound)
    }

    func testNothingChangesOnceQuitting() async throws {
        let app = model(try TempleDB.inMemory())
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(tab.sessionID)
        tab.activity = .idle
        app.openSessions.prepareForQuit()
        for request in [ControlRequest(.sessionsClose, id: id, force: true), ControlRequest(.sessionsOpen, id: id),
                        ControlRequest(.sessionsNew, directory: root.path)] {
            let answer = await ask(app, request)
            XCTAssertEqual(answer.error?.code, .refused, "\(request.command)")
        }
        XCTAssertEqual(app.openSessions.tabs.filter { $0.kind == .session }.count, 1)
        let listed = await ask(app, ControlRequest(.sessionsList))
        XCTAssertEqual(listed.sessions?.count, 1, "reads still answer")
    }

    /// A restored chip opens as clicking it does, whatever its row knows.
    func testOpeningARestoredChipFocusesIt() async throws {
        let db = try TempleDB.inMemory()
        let first = model(db)
        let background = first.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        _ = first.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        let id = try XCTUnwrap(background.sessionID)
        first.openSessions.prepareForQuit()
        let second = model(db)
        let answer = await ask(second, ControlRequest(.sessionsOpen, id: id))
        XCTAssertEqual(answer.session?.id, id)
        XCTAssertEqual(answer.session?.focused, true)
        XCTAssertEqual(second.openSessions.activeTab?.sessionID, id)
    }

    /// History's rule, not one of our own: Temple archived it because its
    /// folder went, and History would not open it either.
    func testOpenRefusesWhatHistoryWouldNotOpen() async throws {
        let db = try TempleDB.inMemory()
        Fixture.join([Fixture.row("gone", project: "/p/gone")], to: db)
        let state = try XCTUnwrap(try db.sessionState("gone"))
        let ref = MembershipRef(id: "gone", host: .local, incarnation: try XCTUnwrap(state.incarnation))
        _ = try db.autoArchive([AutoArchiveEntry(ref: ref, reason: .folderMissing, directory: "/p/gone")],
                               idleBefore: .distantFuture)
        let app = model(db)
        try await settle { app.sessions.contains { $0.id == "gone" && $0.state.archived } }
        let answer = await ask(app, ControlRequest(.sessionsOpen, id: "gone"))
        XCTAssertEqual(answer.error?.code, .refused)
        XCTAssertEqual(answer.error?.message, "The folder it ran in is gone.")
        XCTAssertTrue(app.openSessions.tabs.filter { $0.kind == .session }.isEmpty)
    }

    /// The deadline answered first: the request changes nothing.
    func testAnExpiredRequestChangesNothing() async throws {
        let app = model(try TempleDB.inMemory())
        let tab = app.openSessions.newSession(agent: .claude, project: Fixture.key("/p"))
        tab.activity = .idle
        let id = try XCTUnwrap(tab.sessionID)
        for request in [ControlRequest(.sessionsNew, directory: root.path), ControlRequest(.sessionsClose, id: id),
                        ControlRequest(.sessionsOpen, id: id)] {
            let commit = ControlCommit()
            _ = commit.expire()
            _ = await app.handleControl(request, commit: commit)
        }
        XCTAssertEqual(app.openSessions.tabs.filter { $0.kind == .session }.map(\.sessionID), [id])
    }

    func testTheServerIsTheAppsAlone() throws {
        let app = model(try TempleDB.inMemory())
        app.startControlServer()
        XCTAssertNil(app.controlServer, "a model on an in-memory database opens no socket")
    }

    private func settle(_ condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(3)
        while try !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
