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

    func testRailGroupsByHostAndOmitsDirectorylessMembers() throws {
        let app = try model([Fixture.row("local", project: "/same"),
            Fixture.row("remote", project: "/same", host: HostID(rawValue: "remote")), Fixture.row("unknown")])
        XCTAssertEqual(Set(app.displayProjects.map(\.key)), [ProjectKey(host: .local, path: "/same"), ProjectKey(host: HostID(rawValue: "remote"), path: "/same")])
        app.overlay.togglePin("unknown")
        XCTAssertFalse(app.highlightableSessions.contains { $0.id == "unknown" })
        XCTAssertEqual(app.sessions.count, 3)
    }
}
