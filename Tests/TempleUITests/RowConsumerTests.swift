import XCTest
@testable import TempleUI
import TempleCore

@MainActor
final class RowConsumerTests: XCTestCase {
    func model(_ rows: [Session]) throws -> AppModel {
        let db = try TempleDB.inMemory()
        Fixture.join(rows, to: db)
        return AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])), database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
    }

    private func nextPresentationTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func key(_ path: String, host: HostID = .local) -> ProjectKey {
        ProjectKey(host: host, path: path)
    }

    private func freeze(_ app: AppModel) {
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: Dictionary(uniqueKeysWithValues: app.sessions.map { ($0.id, MemberResolution.confirmedAbsent) }),
            summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
    }

    /// Recompute from source rows, never the presentation cache. Explicit rank
    /// expectations keep the oracle independent of the production rank ledger.
    private func assertFrozenPresentation(_ app: AppModel, _ order: [(ProjectKey, [String])],
                                          file: StaticString = #filePath, line: UInt = #line) {
        let rows = app.overlay.rows.values.map { Session(state: $0) }
        let full = SessionRowProject.grouping(rows)
        XCTAssertEqual(app.sessions.count, rows.count, file: file, line: line)
        XCTAssertEqual(Set(app.sessions.map(\.state)), Set(rows.map(\.state)), file: file, line: line)
        XCTAssertEqual(Set(full.map(\.key)), Set(order.map { $0.0 }), file: file, line: line)
        XCTAssertEqual(app.rowProjects.count, full.count, file: file, line: line)
        XCTAssertEqual(Set(app.rowProjects.map(\.key)), Set(full.map(\.key)), file: file, line: line)
        for project in full {
            let cached = app.rowProjects.first { $0.key == project.key }
            XCTAssertEqual(Set(cached?.sessions.map(\.state) ?? []), Set(project.sessions.map(\.state)), file: file, line: line)
            XCTAssertEqual(cached?.lastActivity, project.lastActivity, file: file, line: line)
        }
        let expected = order.compactMap { projectKey, ids -> SessionRowProject? in
            let members = full.first { $0.key == projectKey }?.sessions ?? []
            XCTAssertEqual(Set(members.map(\.id)), Set(ids), file: file, line: line)
            guard !app.overlay.isProjectArchived(projectKey) else { return nil }
            let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            let visible = members.filter { !$0.state.archived }.sorted { rank[$0.id]! < rank[$1.id]! }
            return visible.isEmpty ? nil : SessionRowProject(key: projectKey, sessions: visible)
        }
        XCTAssertEqual(app.displayProjects.map(\.key), expected.map(\.key), file: file, line: line)
        XCTAssertEqual(app.displayProjects.map { $0.sessions.map(\.state) },
                       expected.map { $0.sessions.map(\.state) }, file: file, line: line)
        XCTAssertEqual(app.orderedVisibleProjectKeys, expected.map(\.key), file: file, line: line)
    }

    func testLastMemberRemovalMatchesFullFrozenRecomputation() throws {
        let app = try model([Fixture.row("a1", project: "/a", updated: 30),
                             Fixture.row("a2", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        assertFrozenPresentation(app, [(key("/a"), ["a1", "a2"]), (key("/b"), ["b"])])
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "a1", host: .local)]), ["a1"])
        assertFrozenPresentation(app, [(key("/a"), ["a2"]), (key("/b"), ["b"])])
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "a2", host: .local)]), ["a2"])
        assertFrozenPresentation(app, [(key("/b"), ["b"])])
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "b", host: .local)]), ["b"])
        assertFrozenPresentation(app, [])
    }

    func testLeaveAndRejoinAcrossHostsMatchesFullFrozenRecomputation() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("moving", project: "/same", updated: 20),
                             Fixture.row("anchor", project: "/same", updated: 10, host: remote)])
        freeze(app)
        assertFrozenPresentation(app, [(key("/same"), ["moving"]), (key("/same", host: remote), ["anchor"])])
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "moving", host: .local)]), ["moving"])
        assertFrozenPresentation(app, [(key("/same", host: remote), ["anchor"])])
        XCTAssertTrue(app.overlay.join("moving", via: .imported, agent: .claude,
            core: SessionCore(host: remote, directory: "/same", title: "Remote", lastActiveAt: Date(timeIntervalSince1970: 40))).isJoined)
        assertFrozenPresentation(app, [(key("/same", host: remote), ["moving", "anchor"])])
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "moving", host: .local)]), [], "the row is the remote host's now")
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "moving", host: remote)]), ["moving"])
        assertFrozenPresentation(app, [(key("/same", host: remote), ["anchor"])])
        XCTAssertTrue(app.overlay.join("moving", via: .imported, agent: .claude,
            core: SessionCore(directory: "/same", title: "Local again", lastActiveAt: Date(timeIntervalSince1970: 50))).isJoined)
        assertFrozenPresentation(app, [(key("/same"), ["moving"]), (key("/same", host: remote), ["anchor"])])
    }

    func testDirectoryMoveAndMoveBackMatchesFullFrozenRecomputation() throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("moving", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        assertFrozenPresentation(app, [(key("/a"), ["a", "moving"]), (key("/b"), ["b"])])
        app.overlay.observeLaunchDirectory("moving", host: .local, "/b")
        assertFrozenPresentation(app, [(key("/a"), ["a"]), (key("/b"), ["moving", "b"])])
        app.overlay.observeLaunchDirectory("moving", host: .local, "/a")
        assertFrozenPresentation(app, [(key("/a"), ["a", "moving"]), (key("/b"), ["b"])])
    }

    func testArchiveAndRestoreWithPendingTouchesMatchesFullFrozenRecomputation() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        let order = [(key("/a"), ["a"]), (key("/b"), ["b"])]
        assertFrozenPresentation(app, order)
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 40))
        app.archiveSession("b", undoManager: nil)
        assertFrozenPresentation(app, order)
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 50))
        app.restoreSession("b", undoManager: nil)
        assertFrozenPresentation(app, order)
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 60))
        app.archiveProject(key("/a"), undoManager: nil)
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 70))
        app.restoreProject(key("/a"), undoManager: nil)
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
    }

    func testContinuousTouchesAcrossTurnsNeverSortOrRegroupAfterFreeze() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("a2", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        let order = [(key("/a"), ["a", "a2"]), (key("/b"), ["b"])]
        assertFrozenPresentation(app, order)
        let sorts = app.rowPresentationSortCount
        let groups = app.rowProjectBuildCount
        let builds = app.sessionPresentationBuildCount
        for tick in 1...100 {
            let id = ["a", "a2", "b"][tick % 3]
            let date = Date(timeIntervalSince1970: Double(100 + tick))
            app.overlay.touch(id, host: .local, at: date)
            await nextPresentationTurn()
            XCTAssertEqual(app.sessions.first { $0.id == id }?.sortDate, date)
            XCTAssertEqual(app.sessionPresentationBuildCount, builds + tick, "continuous activity must not starve publication")
            XCTAssertEqual(app.rowPresentationSortCount, sorts)
            XCTAssertEqual(app.rowProjectBuildCount, groups)
            assertFrozenPresentation(app, order)
        }
    }

    func testArchiveStillReadsLiveRecencyAfterFrozenValueUpdates() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("b", project: "/b", updated: 20), Fixture.row("b2", project: "/b", updated: 10)])
        freeze(app)
        let order = [(key("/a"), ["a"]), (key("/b"), ["b", "b2"])]
        app.archiveSession("a", undoManager: nil)
        app.archiveSession("b2", undoManager: nil)
        app.overlay.touch("b2", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        XCTAssertEqual(app.archivedSessionResults("").map(\.id), ["b2", "a"])
        app.archiveProject(key("/a"), undoManager: nil)
        app.archiveProject(key("/b"), undoManager: nil)
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 50))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        XCTAssertEqual(app.archivedProjects.map(\.path), ["/a", "/b"])
        XCTAssertEqual(app.archivedProjects.last?.sessions.map(\.id), ["b2", "b"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 60))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        XCTAssertEqual(app.archivedProjects.map(\.path), ["/b", "/a"])
        XCTAssertEqual(app.archivedProjects.first?.sessions.map(\.id), ["b", "b2"])
    }

    func testAgentlessArchiveReturnRestoresBothFlagsAsOneUndoGroup() throws {
        let app = try model([Fixture.row("agentless", agent: nil, project: "/a", updated: 20)])
        freeze(app)
        let order = [(key("/a"), ["agentless"])]
        app.archiveSession("agentless", undoManager: nil)
        app.archiveProject(key("/a"), undoManager: nil)
        assertFrozenPresentation(app, order)
        let entry = ArchiveView.Entry.session(app.sessions[0])
        XCTAssertEqual(ArchiveView.returnHint(for: entry, model: app), "restore session")
        let undo = UndoManager()
        undo.groupsByEvent = false
        ArchiveView.activateSelection([entry], selection: 0, model: app, undoManager: undo)
        XCTAssertFalse(app.overlay.isArchived("agentless"))
        XCTAssertFalse(app.overlay.isProjectArchived(key("/a")))
        assertFrozenPresentation(app, order)
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["agentless"])
        XCTAssertTrue(app.openSessions.tabs.isEmpty)
        undo.undo()
        XCTAssertTrue(app.overlay.isArchived("agentless"))
        XCTAssertTrue(app.overlay.isProjectArchived(key("/a")))
        XCTAssertFalse(undo.canUndo, "both flags belong to one undo step")
        assertFrozenPresentation(app, order)
        undo.redo()
        XCTAssertFalse(app.overlay.isArchived("agentless"))
        XCTAssertFalse(app.overlay.isProjectArchived(key("/a")))
        assertFrozenPresentation(app, order)
    }

    func testBurstTouchesCoalescePresentationWithoutRegroupingAfterFreeze() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20),
                             Fixture.row("b", project: "/b", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        let builds = app.sessionPresentationBuildCount
        let groups = app.rowProjectBuildCount
        for tick in 1...100 { app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: Double(100 + tick))) }
        XCTAssertEqual(app.sessionPresentationBuildCount, builds)
        XCTAssertEqual(app.overlay.rows["b"]?.lastActiveAt, Date(timeIntervalSince1970: 200))
        await nextPresentationTurn()
        XCTAssertEqual(app.sessionPresentationBuildCount, builds + 1)
        XCTAssertEqual(app.rowProjectBuildCount, groups)
        XCTAssertEqual(app.sessions.first { $0.id == "b" }?.sortDate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
        XCTAssertEqual(app.projectPickerResults("").map(\.path), ["/b", "/a"])
        // A real title change is immediate and consumes queued activity too.
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 300))
        app.overlay.rename("a", to: "Renamed immediately")
        XCTAssertEqual(app.sessions.first?.displayTitle, "Renamed immediately")
        XCTAssertEqual(app.sessions.first?.sortDate, Date(timeIntervalSince1970: 300))
        let afterRename = app.sessionPresentationBuildCount
        await nextPresentationTurn()
        XCTAssertEqual(app.sessionPresentationBuildCount, afterRename)
    }

    func testPendingActivityIsIncludedWhenRanksFreezeAndDirectoriesStayImmediate() throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", updated: 10)])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        app.overlay.observeLaunchDirectory("b", host: .local, "/b")
        XCTAssertEqual(app.displayProjects.map(\.path), ["/b", "/a"])
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
        app.overlay.observeLaunchDirectory("b", host: .local, "/a")
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a"])
        // A newcomer to a frozen group takes its place by recency (b: 30, a: 40).
        XCTAssertEqual(app.displayProjects[0].sessions.map(\.id), ["a", "b"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(app.displayProjects[0].sessions.map(\.id), ["a", "b"], "and then stays frozen")
        app.overlay.join("new", via: .created, agent: .claude, core: SessionCore(directory: "/new"))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/new", "/a"])
    }

    func testHistoryDoesNotRebuildForCatalogMemberTouchBursts() async throws {
        let app = try model([Fixture.row("catalog", project: "/p", updated: 20),
                             Fixture.row("missing", updated: 10)])
        try await read(app, events: [.sessions([Fixture.session("catalog", project: "/p", updated: 5)], read: 1, total: 1)])
        await nextPresentationTurn()
        let builds = app.history.rebuildCount
        let chronology = app.history.allRows.map(\.id)
        for tick in 1...100 { app.overlay.touch("catalog", host: .local, at: Date(timeIntervalSince1970: Double(100 + tick))) }
        await nextPresentationTurn()
        await nextPresentationTurn()
        XCTAssertEqual(app.history.rebuildCount, builds)
        XCTAssertEqual(app.history.allRows.map(\.id), chronology)
        XCTAssertEqual(app.history.allRows.last?.updatedAt, Date(timeIntervalSince1970: 5))
        // An absent member DOES use row time, while titles still update for both.
        app.overlay.touch("missing", host: .local, at: Date(timeIntervalSince1970: 400))
        await nextPresentationTurn()
        await nextPresentationTurn()
        XCTAssertEqual(app.history.rebuildCount, builds + 1)
        XCTAssertEqual(app.history.allRows.first?.updatedAt, Date(timeIntervalSince1970: 400))
        app.overlay.rename("catalog", to: "New catalog member title")
        await nextPresentationTurn()
        XCTAssertEqual(app.history.rebuildCount, builds + 2)
        XCTAssertEqual(app.history.allRows.last?.title, "New catalog member title")
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

    func testPickerAndLauncherUseRowActivityWithoutTranscripts() async throws {
        let app = try model([Fixture.row("old", project: "/old", updated: 10),
            Fixture.row("new", project: "/new", updated: 20), Fixture.row("no-directory", updated: 30)])
        XCTAssertEqual(app.projectPickerResults("").map(\.path), ["/new", "/old"])
        XCTAssertEqual(app.launcherDefaultProjectKey, ProjectKey(host: .local, path: "/new"))
        app.overlay.touch("old", host: .local, at: Date(timeIntervalSince1970: 50))
        await nextPresentationTurn()
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

    private func read(_ app: AppModel, events: [CatalogBatch]) async throws {
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
        let disk = catalogFixture(id: "member", agent: .claude, projectPath: "/", title: "Disk title",
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

    func testFrozenRankWaitsForTheFirstCompleteGeneration() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .resolving], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen)
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.path), ["/b", "/a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .resolving, "b": .confirmedAbsent], summaries: [:]))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen, "a stale complete generation cannot freeze the newer one")
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent], summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 50))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
    }

    func testSidebarSessionsSortLiveUntilInitialResolutionCompletes() async throws {
        let app = try model([Fixture.row("a", project: "/same", updated: 20), Fixture.row("b", project: "/same", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .resolving], summaries: [:]))
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["b", "a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .unreadable], summaries: [:]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["b", "a"])
    }

    func testFrozenRankFallsBackThreeSecondsAfterStartAndKeepsHostsSeparate() async throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("a", project: "/same", updated: 20),
            Fixture.row("b", project: "/same", updated: 10, host: remote)])
        var deadline: (@MainActor () -> Void)?
        app.scheduleSidebarFreeze = { delay, action in XCTAssertEqual(delay, 3); deadline = action }
        app.beginSidebarRanking()
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .unreadable, "b": .awaitingCreation], summaries: [:]))
        XCTAssertFalse(app.sidebarRanksFrozen)
        app.overlay.touch("b", host: remote, at: Date(timeIntervalSince1970: 30))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.key.host), [remote, .local])
        try XCTUnwrap(deadline)()
        XCTAssertTrue(app.sidebarRanksFrozen)
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.key.host), [remote, .local])
        app.overlay.join("new", via: .created, agent: .claude, core: SessionCore(directory: "/new", lastActiveAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(app.displayProjects.map(\.path), ["/new", "/same", "/same"])
    }

    func testTabTranscriptActionsUseOnlyRowLocatorsAndResumeFacts() throws {
        let remote = HostID(rawValue: "remote")
        let app = try model([Fixture.row("local", project: "/row", title: "Row title"),
            Fixture.row("remote", project: "/row", host: remote)])
        let legacy = Fixture.session("local", agent: .codex, project: "/wrong")
        XCTAssertNil(app.transcriptURL(for: "local"), "legacy index presence is not a row locator")
        let localURL = URL(fileURLWithPath: "/tmp/local.jsonl")
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["local": .loaded(localURL),
            "remote": .loaded(TranscriptLocator(host: remote, path: "/remote/transcript.jsonl"))], summaries: [:]))
        XCTAssertEqual(app.transcriptURL(for: "local"), localURL)
        XCTAssertNil(app.transcriptURL(for: "remote"), "remote locators cannot reveal a local file")
        let tab = SessionTab(kind: .session, sessionID: "local", agent: .codex,
            projectPath: "/wrong", title: "Old title")
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
