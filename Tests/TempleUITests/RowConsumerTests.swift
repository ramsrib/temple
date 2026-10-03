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

    func testRailGroupsByHostAndOmitsDirectorylessMembers() throws {
        let app = try model([Fixture.row("local", project: "/same"),
            Fixture.row("remote", project: "/same", host: HostID(rawValue: "remote")), Fixture.row("unknown")])
        XCTAssertEqual(Set(app.displayProjects.map(\.key)), [ProjectKey(host: .local, path: "/same"), ProjectKey(host: HostID(rawValue: "remote"), path: "/same")])
        app.overlay.togglePin("unknown")
        XCTAssertFalse(app.highlightableSessions.contains { $0.id == "unknown" })
        XCTAssertEqual(app.sessions.count, 3)
    }
}
