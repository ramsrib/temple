import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class RowConsumerTests: XCTestCase {
    func model(_ rows: [Session]) throws -> AppModel {
        let db = try TempleDB.inMemory()
        Fixture.join(rows, to: db)
        return AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(SessionIndex(projects: [])), database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
    }

    func testHistoryArchivesDirectorylessMembersWithUndo() throws {
        let app = try model([Fixture.row("unknown"), Fixture.row("project", project: "/p")])
        let undo = UndoManager()
        for member in app.sessions {
            let row = HistoryRow(member: member)
            XCTAssertTrue(app.history.canArchive(row))
            app.history.hasOpenTab = { $0 == member.id }
            XCTAssertFalse(app.history.canArchive(row))
            app.history.archive(row, undoManager: undo)
            XCTAssertFalse(app.overlay.rows[member.id]!.archived)
            app.history.hasOpenTab = { _ in false }
            undo.beginUndoGrouping()
            app.history.archive(row, undoManager: undo)
            undo.endUndoGrouping()
            XCTAssertTrue(app.overlay.rows[member.id]!.archived)
            XCTAssertFalse(app.history.canArchive(row))
            undo.undo()
            XCTAssertFalse(app.overlay.rows[member.id]!.archived)
            undo.redo()
            XCTAssertTrue(app.overlay.rows[member.id]!.archived)
        }
        XCTAssertFalse(app.history.canArchive(HistoryRow(catalog: Fixture.session("outside", project: "/outside"))))
    }

    func testArchiveReturnRestoresNonResumableSelectionWithoutDismissing() throws {
        let app = try model([Fixture.row("unknown")])
        app.archiveSession("unknown", undoManager: nil)
        app.archivePresented = true
        let entry = ArchiveView.Entry.session(app.sessions[0])
        XCTAssertEqual(ArchiveView.returnHint(for: entry, model: app), "restore session")
        let undo = UndoManager()
        undo.beginUndoGrouping()
        ArchiveView.activateSelection([entry], selection: 0, model: app, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertFalse(app.overlay.rows["unknown"]!.archived)
        XCTAssertTrue(app.openSessions.tabs.isEmpty)
        XCTAssertTrue(app.archivePresented)
        undo.undo()
        XCTAssertTrue(app.overlay.rows["unknown"]!.archived)
    }

    func testProjectFinderRevealRequiresLocalHostEvenWithTheSamePath() {
        let local = SessionRowProject(key: ProjectKey(host: .local, path: "/same"), sessions: [])
        let remote = SessionRowProject(key: ProjectKey(host: HostID(rawValue: "remote"), path: "/same"), sessions: [])
        XCTAssertEqual(local.localDirectoryURL, URL(fileURLWithPath: "/same"))
        XCTAssertNil(remote.localDirectoryURL)
    }

    func testAMemberWithoutATranscriptStillHasASidebarRow() throws {
        let app = try model([Fixture.row("missing", project: "/gone", title: "Kept")])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["missing": .confirmedAbsent], summaries: [:]))
        XCTAssertEqual(app.displayProjects.flatMap(\.sessions).map(\.id), ["missing"])
        XCTAssertEqual(app.displayProjects.first?.sessions.first?.displayTitle, "Kept")
        XCTAssertNil(app.displayProjects.first?.sessions.first?.transcript)
        app.overlay.togglePin("missing")
        XCTAssertEqual(app.pinnedSessions.map(\.id), ["missing"])
    }

    func testDirectorylessRowsAreFoundByTheSwitcherNotTheRail() throws {
        let app = try model([Fixture.row("unknown", agent: .codex, title: "A remembered task")])
        XCTAssertEqual(app.paletteResults("remembered").map(\.id), ["unknown"])
        XCTAssertEqual(app.paletteResults("codex").map(\.id), ["unknown"])
        XCTAssertTrue(app.displayProjects.isEmpty)
        XCTAssertFalse(app.sessions[0].canResume)
    }

    func testRowSearchUsesDisplayTitleProjectAndAgent() {
        let rows = [Fixture.row("sub", project: "/other", title: "Fix auth"),
            Fixture.row("exact", project: "/other", title: "auth"),
            Fixture.row("prefix", project: "/other", title: "Auth cleanup"),
            Fixture.row("project", project: "/auth", title: "Else"),
            Fixture.row("agent", agent: .codex, title: "Else")]
        XCTAssertEqual(RowSearch.rank(rows, query: "auth").map(\.id), ["exact", "prefix", "sub", "project"])
        XCTAssertEqual(RowSearch.rank(rows, query: "codex").map(\.id), ["agent"])
    }

    func testPickerAndLauncherUseRowActivityWithoutTranscripts() throws {
        let app = try model([Fixture.row("old", project: "/old", updated: 10),
            Fixture.row("new", project: "/new", updated: 20), Fixture.row("no-directory", updated: 30)])
        XCTAssertEqual(app.projectPickerResults("").map(\.path), ["/new", "/old"])
        XCTAssertEqual(app.launcherDefaultProjectKey, ProjectKey(host: .local, path: "/new"))
        app.overlay.touch("old", at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(app.projectPickerResults("").map(\.path), ["/old", "/new"])
        XCTAssertEqual(app.launcherDefaultProjectKey?.path, "/old")
    }

    func testArchiveIncludesMembersWithoutTranscriptsAndDirectories() throws {
        let app = try model([Fixture.row("missing", project: "/gone", title: "Kept"), Fixture.row("unknown", title: "Directoryless")])
        app.overlay.setArchived(true, sessionID: "missing")
        app.overlay.setArchived(true, sessionID: "unknown")
        XCTAssertEqual(Set(app.archiveGroups("").flatMap(\.project.sessions).map(\.id)), ["missing", "unknown"])
        XCTAssertEqual(app.archiveGroups("directoryless").first?.name, "No project")
        XCTAssertNil(app.archiveGroups("directoryless").first?.project.sessions.first?.directory)
        app.restoreSession("unknown", undoManager: nil)
        XCTAssertFalse(app.archivedSessionResults("").contains { $0.id == "unknown" })
    }

    private func read(_ app: AppModel, events: [SessionCatalog.Event]) async throws {
        app.history.catalog = { AsyncStream { c in events.forEach { c.yield($0) }; c.finish() } }
        app.history.activate()
        let deadline = Date().addingTimeInterval(2)
        while app.history.readState != .done && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.history.readState, .done)
    }

    func testTempleRowsWithoutATranscriptAreTaggedOnlyFromACompletedResolution() async throws {
        let rows = ["absent", "unreadable", "resolving", "awaiting", "unknown"].map { Fixture.row($0, title: $0) }
        let app = try model(rows)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["absent": .confirmedAbsent,
            "unreadable": .unreadable, "resolving": .resolving, "awaiting": .awaitingCreation], summaries: [:]))
        try await read(app, events: [.storeFailed(.codex, message: "Failed scan")])
        XCTAssertEqual(app.history.allRows.count, 5)
        XCTAssertEqual(app.history.allRows.filter(\.transcriptMissing).map(\.id), ["absent"])
        XCTAssertTrue(app.history.allRows.allSatisfy { !$0.canResume })
        app.history.scope = .inTemple
        app.history.openSelected()
        XCTAssertTrue(app.openSessions.tabs.isEmpty)
        // A stale absence cannot replace newer unresolved evidence.
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["unknown": .confirmedAbsent], summaries: [:]))
        app.history.rebuild()
        XCTAssertFalse(app.history.allRows.first { $0.id == "unknown" }!.transcriptMissing)
        // Cancelling a later scan leaves the member union and its evidence intact.
        app.history.catalog = { AsyncStream { _ in } }
        app.history.refresh()
        app.history.deactivate()
        app.history.rebuild()
        XCTAssertEqual(app.history.allRows.count, 5)
        XCTAssertEqual(app.history.allRows.filter(\.transcriptMissing).map(\.id), ["absent"])
    }

    func testHistoryUnionsMembersWithTheUnfilteredCatalog() async throws {
        let app = try model([Fixture.row("member", project: "/", title: "Durable title", updated: 100),
            Fixture.row("missing", title: "Kept without catalog", updated: 50)])
        let disk = AgentSession(id: "member", agent: .claude, projectPath: "/", title: "Disk title",
            createdAt: nil, updatedAt: Date(timeIntervalSince1970: 10), filePath: URL(fileURLWithPath: "/tmp/member.jsonl"),
            lastMessagePreview: "Catalog preview", gitBranch: "catalog-branch")
        let noisy = Fixture.session("noisy-outside", project: "/", title: "Noise", updated: 20)
        let outside = Fixture.session("outside", project: NSTemporaryDirectory(), title: "Outside", updated: 30)
        try await read(app, events: [.sessions([disk, noisy, outside], read: 3, total: 3)])
        XCTAssertEqual(Set(app.history.allRows.map(\.id)), ["member", "missing", "outside"])
        XCTAssertEqual(app.history.inTempleCount, 2)
        let member = try XCTUnwrap(app.history.allRows.first { $0.id == "member" })
        XCTAssertEqual(member.title, "Durable title")
        XCTAssertEqual(member.updatedAt, disk.updatedAt)
        XCTAssertEqual(member.gitBranch, "catalog-branch")
        XCTAssertEqual(member.lastMessagePreview, "Catalog preview")
        XCTAssertFalse(member.transcriptMissing)
        XCTAssertEqual(app.history.allRows.first { $0.id == "missing" }?.updatedAt, Date(timeIntervalSince1970: 50))
        XCTAssertFalse(app.history.allRows.first { $0.id == "missing" }!.transcriptMissing)
        // The noisy disk entry was retained, so a later join reveals its disk facts.
        app.overlay.join("noisy-outside", via: .imported, agent: .claude,
            core: SessionCore(directory: "/", title: "New member", lastActiveAt: Date(timeIntervalSince1970: 200)))
        app.history.rebuild()
        let joined = try XCTUnwrap(app.history.allRows.first { $0.id == "noisy-outside" })
        XCTAssertEqual(joined.updatedAt, noisy.updatedAt)
        XCTAssertEqual(joined.title, "New member")
        XCTAssertEqual(app.history.inTempleCount, 3)
    }

    func testProjectSwitchingAndTabStripsKeepSamePathHostsSeparate() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("local", project: "/same", title: "Local row"),
            Fixture.row("remote", project: "/same", title: "Remote row", host: remote)])
        app.openSessions.openSession(app.sessions.first { $0.id == "local" }!)
        app.openSessions.openSession(app.sessions.first { $0.id == "remote" }!)
        let local = ProjectKey(host: .local, path: "/same"), other = ProjectKey(host: remote, path: "/same")
        XCTAssertEqual(app.openSessions.openProjectKeys, [local, other])
        XCTAssertEqual(app.switchableProjectKeys, [other, local])
        XCTAssertEqual(app.openSessions.visibleTabs.compactMap(\.sessionID), ["remote"])
        app.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(app.projectSwitcherKeySelection, local)
        app.commitProjectSwitcher()
        XCTAssertEqual(app.openSessions.activeProjectKey, local)
        XCTAssertEqual(app.openSessions.visibleTabs.compactMap(\.sessionID), ["local"])
        app.openSessions.activateProject(other)
        XCTAssertEqual(app.openSessions.activeTab?.sessionID, "remote")
    }

    func testRowTitlesAndProjectArchiveStateStayHostAware() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("local", project: "/same", title: "Local row"),
            Fixture.row("remote", project: "/same", title: "Remote row", host: remote)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["local": .confirmedAbsent, "remote": .confirmedAbsent], summaries: [:]))
        app.openSessions.openSession(app.sessions.first { $0.id == "remote" }!)
        let tab = try XCTUnwrap(app.openSessions.activeTab)
        tab.title = "Stale chip title"
        XCTAssertEqual(app.tabDisplayTitle(tab), "Remote row")
        app.overlay.rename("remote", to: "Renamed row")
        XCTAssertEqual(app.tabDisplayTitle(tab), "Renamed row")
        XCTAssertEqual(tab.projectKey.displayName, "same @remote")
        let local = ProjectKey(host: .local, path: "/same"), other = tab.projectKey
        app.archiveProject(other, undoManager: nil)
        XCTAssertFalse(app.overlay.isProjectArchived(local))
        XCTAssertTrue(app.overlay.isProjectArchived(other))
        XCTAssertEqual(app.archivedProjects.map(\.key), [other])
        XCTAssertEqual(app.displayProjects.map(\.key), [local])
        app.restoreProject(other, undoManager: nil)
        app.moveProject(other, before: local)
        XCTAssertEqual(app.overlay.projectKeyOrder, [other, local])
        XCTAssertEqual(app.displayProjects.map(\.key), [other, local])
    }

    func testFrozenRankWaitsForTheFirstCompleteGeneration() throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .resolving], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen)
        app.overlay.touch("b", at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/b", "/a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .resolving, "b": .confirmedAbsent], summaries: [:]))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen, "a stale complete generation cannot freeze the newer one")
        app.overlay.touch("a", at: Date(timeIntervalSince1970: 40))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
        app.overlay.touch("b", at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
    }

    func testSidebarSessionsSortLiveUntilInitialResolutionCompletes() throws {
        let app = try model([Fixture.row("a", project: "/same", updated: 20), Fixture.row("b", project: "/same", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .resolving], summaries: [:]))
        app.overlay.touch("b", at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["b", "a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .unreadable], summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        app.overlay.touch("a", at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["b", "a"])
    }

    func testFrozenRankFallsBackThreeSecondsAfterStartAndKeepsHostsSeparate() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("a", project: "/same", updated: 20),
            Fixture.row("b", project: "/same", updated: 10, host: remote)])
        var deadline: (@MainActor () -> Void)?
        app.scheduleSidebarFreeze = { delay, action in XCTAssertEqual(delay, 3); deadline = action }
        app.beginSidebarRanking()
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .unreadable, "b": .awaitingCreation], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen)
        app.overlay.touch("b", at: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(app.displayProjects.map(\.key.host), [remote, .local])
        try XCTUnwrap(deadline)()
        XCTAssertTrue(app.sidebarRanksFrozen)
        app.overlay.touch("a", at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(app.displayProjects.map(\.key.host), [remote, .local])
        app.overlay.join("new", via: .created, agent: .claude, core: SessionCore(directory: "/new", lastActiveAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/new", "/same", "/same"])
    }

    func testTabTranscriptActionsUseOnlyRowLocatorsAndResumeFacts() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("local", project: "/row", title: "Row title"),
            Fixture.row("remote", project: "/row", host: remote)])
        let legacy = Fixture.session("local", agent: .codex, project: "/wrong")
        app.index = SessionIndex(projects: [Project(path: "/wrong", sessions: [legacy])])
        XCTAssertNil(app.transcriptURL(for: "local"), "legacy index presence is not a row locator")
        let localURL = URL(fileURLWithPath: "/tmp/local.jsonl")
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["local": .loaded(localURL),
            "remote": .loaded(URL(fileURLWithPath: "/remote/transcript.jsonl"))], summaries: [:]))
        XCTAssertEqual(app.transcriptURL(for: "local"), localURL)
        XCTAssertNil(app.transcriptURL(for: "remote"), "remote locators cannot reveal a local file")
        let tab = SessionTab(kind: .session, sessionID: "local", agent: .codex,
            projectPath: "/wrong", title: "Old title", command: nil)
        XCTAssertEqual(app.resumeArgv(for: tab), ["claude", "--resume", "local"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["local": .confirmedAbsent,
            "remote": .unreadable], summaries: [:]))
        XCTAssertNil(app.transcriptURL(for: "local"))
        XCTAssertNil(app.transcriptURL(for: "remote"))
    }

    func testRailGroupsByHostAndOmitsDirectorylessMembers() throws {
        let app = try model([Fixture.row("local", project: "/same"),
            Fixture.row("remote", project: "/same", host: HostID(rawValue: "remote")), Fixture.row("unknown")])
        XCTAssertEqual(Set(app.displayProjects.map(\.key)), [ProjectKey(host: .local, path: "/same"), ProjectKey(host: HostID(rawValue: "remote"), path: "/same")])
        app.overlay.togglePin("unknown")
        XCTAssertFalse(app.highlightableSessions.contains { $0.id == "unknown" })
        XCTAssertEqual(app.sessions.count, 3)
    }
}
