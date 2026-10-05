import XCTest
import Combine
@testable import TempleUI
import TempleCore

@MainActor
final class RowConsumerTests: XCTestCase {
    func model(_ rows: [Session]) throws -> AppModel {
        let db = try TempleDB.inMemory()
        Fixture.join(rows, to: db)
        return AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
    }

    private func nextPresentationTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// History's rows in `scope`, members only (no disk read).
    private func historyPage(_ app: AppModel, _ scope: HistoryScope = .archived) async -> [String] {
        app.history.catalog = { AsyncStream { $0.finish() } }
        app.history.activate()
        app.history.scope = scope
        await app.history.settle()
        return app.history.visibleRows.map(\.sessionID)
    }

    private func key(_ path: String, host: HostID = .local) -> ProjectKey {
        ProjectKey(host: host, path: path)
    }

    private func freeze(_ app: AppModel) {
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: Dictionary(uniqueKeysWithValues: app.sessions.map { ($0.id, MemberResolution.confirmedAbsent) })))
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

    /// Ported for B9: activity after the freeze used to rebuild (values only)
    /// once per turn. It now builds nothing, and the current value is still
    /// what every reader sees.
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
            XCTAssertEqual(app.sessions.first { $0.id == id }?.sortDate, date, "read on demand, current")
            XCTAssertEqual(app.sessionPresentationBuildCount, builds)
            XCTAssertEqual(app.rowPresentationSortCount, sorts)
            XCTAssertEqual(app.rowProjectBuildCount, groups)
            assertFrozenPresentation(app, order)
        }
    }

    func testHistorysArchivedScopeReadsLiveRecencyAfterFrozenValueUpdates() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("b", project: "/b", updated: 20), Fixture.row("b2", project: "/b", updated: 10)])
        freeze(app)
        let order = [(key("/a"), ["a"]), (key("/b"), ["b", "b2"])]
        app.archiveSession("a", undoManager: nil)
        app.archiveSession("b2", undoManager: nil)
        app.overlay.touch("b2", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        let first = await historyPage(app)
        XCTAssertEqual(first, ["b2", "a"])
        app.archiveProject(key("/a"), undoManager: nil)
        app.archiveProject(key("/b"), undoManager: nil)
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 50))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        await app.history.settle()
        XCTAssertEqual(app.history.visibleRows.map(\.sessionID), ["a", "b2", "b"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 60))
        await nextPresentationTurn()
        assertFrozenPresentation(app, order)
        await app.history.settle()
        XCTAssertEqual(app.history.visibleRows.map(\.sessionID), ["b", "a", "b2"])
        app.history.deactivate()
    }
    func testAgentlessArchiveReturnRestoresBothFlagsAsOneUndoGroup() async throws {
        let app = try model([Fixture.row("agentless", agent: nil, project: "/a", updated: 20)])
        freeze(app)
        let order = [(key("/a"), ["agentless"])]
        app.archiveSession("agentless", undoManager: nil)
        app.archiveProject(key("/a"), undoManager: nil)
        assertFrozenPresentation(app, order)
        let archived = await historyPage(app)
        XCTAssertEqual(archived, ["agentless"])
        XCTAssertFalse(app.history.visibleRows[0].canResume, "no agent: Return restores")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        app.history.openSelected(undoManager: undo)
        undo.endUndoGrouping()
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
        app.history.deactivate()
    }
    func testBurstTouchesCoalescePresentationWithoutRegroupingAfterFreeze() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20),
                             Fixture.row("b", project: "/b", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent]))
        let builds = app.sessionPresentationBuildCount
        let groups = app.rowProjectBuildCount
        for tick in 1...100 { app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: Double(100 + tick))) }
        XCTAssertEqual(app.sessionPresentationBuildCount, builds)
        XCTAssertEqual(app.overlay.rows["b"]?.lastActiveAt, Date(timeIntervalSince1970: 200))
        await nextPresentationTurn()
        // Ported for B9: the burst used to cost one coalesced build; after
        // the freeze it costs none.
        XCTAssertEqual(app.sessionPresentationBuildCount, builds)
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

    // MARK: B9 — no presentation rebuild that changes nothing shown

    /// Counts what one action costs the presentation: builds, sorts, project
    /// groupings and `AppModel.objectWillChange` emissions.
    private final class PresentationCost {
        private(set) var willChange = 0
        private var cancellable: AnyCancellable?
        let builds: Int, sorts: Int, groups: Int
        private weak var app: AppModel?
        @MainActor init(_ app: AppModel) {
            self.app = app
            builds = app.sessionPresentationBuildCount
            sorts = app.rowPresentationSortCount
            groups = app.rowProjectBuildCount
            cancellable = app.objectWillChange.sink { [unowned self] _ in self.willChange += 1 }
        }
        @MainActor var addedBuilds: Int { (app?.sessionPresentationBuildCount ?? 0) - builds }
        @MainActor var addedSorts: Int { (app?.rowPresentationSortCount ?? 0) - sorts }
        @MainActor var addedGroups: Int { (app?.rowProjectBuildCount ?? 0) - groups }
    }

    /// Let forwarded publications from setup land before counting.
    private func settle() async throws {
        await nextPresentationTurn()
        try await Task.sleep(for: .milliseconds(20))
        await nextPresentationTurn()
    }

    /// The B9 acceptance: after the freeze, recency-only touches whose
    /// displayed values do not change — across turns, through the coalesced
    /// DB write, and a flush that finds nothing new — cost no build, sort or
    /// grouping and emit no `objectWillChange`. Readers still get the
    /// current values.
    func testRecencyOnlyTouchesAfterTheFreezeRebuildAndPublishNothing() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("a2", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        let order = [(key("/a"), ["a", "a2"]), (key("/b"), ["b"])]
        try await settle()
        let cost = PresentationCost(app)
        for tick in 1...60 {
            let id = ["b", "a", "a2"][tick % 3]
            app.overlay.touch(id, host: .local, at: Date(timeIntervalSince1970: Double(100 + tick)))
            if tick % 10 == 0 { await nextPresentationTurn() }
            if tick % 20 == 0 { app.overlay.flushPendingTouches() }
        }
        app.overlay.flushPendingTouches()
        try await settle()
        XCTAssertEqual(cost.addedBuilds, 0)
        XCTAssertEqual(cost.addedSorts, 0)
        XCTAssertEqual(cost.addedGroups, 0)
        XCTAssertEqual(cost.willChange, 0, "nothing the window draws changed")
        assertFrozenPresentation(app, order)
        // b (touched last, at 160) leads live recency; the rail stays frozen.
        XCTAssertEqual(app.sessions.first { $0.id == "b" }?.sortDate, Date(timeIntervalSince1970: 160))
        XCTAssertEqual(app.projectPickerResults("").map(\.path), ["/b", "/a"])
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
    }

    /// The surfaces that do show recency redraw themselves on activity —
    /// AppModel still publishes nothing. The launcher's recent projects are
    /// what it draws; its refresh fires when that changes and stays quiet
    /// when it does not. (History's Archived scope follows recency through
    /// its own projection.)
    func testVisibleRecencyConsumersRefreshThemselvesWhileTheModelStaysSilent() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30),
                             Fixture.row("b", project: "/b", updated: 20), Fixture.row("b2", project: "/b", updated: 10),
                             Fixture.row("c", project: "/c", updated: 5)])
        freeze(app)
        app.archiveSession("b2", undoManager: nil)
        app.archiveSession("c", undoManager: nil)
        try await settle()
        // Default scheduling: the check runs a turn later, after every
        // subscriber (AppModel included) has taken the change.
        let launcher = RecencyRefresh()
        launcher.watch(app.overlay) { AnyHashable(LauncherView.recentPresentation(app)) }
        XCTAssertEqual(LauncherView.recentProjects(app).map(\.path), ["/a", "/b"])
        let cost = PresentationCost(app)

        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 100))
        await nextPresentationTurn()
        XCTAssertEqual(launcher.revision, 1, "the recent list reordered: it redraws")
        XCTAssertEqual(LauncherView.recentProjects(app).map(\.path), ["/b", "/a"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 101))
        await nextPresentationTurn()
        XCTAssertEqual(launcher.revision, 1, "same order, same times: no redraw")

        app.overlay.touch("c", host: .local, at: Date(timeIntervalSince1970: 200))
        await nextPresentationTurn()
        XCTAssertEqual(launcher.revision, 1, "an archived session is not on the launcher")

        try await settle()
        XCTAssertEqual(cost.willChange, 0)
        XCTAssertEqual(cost.addedBuilds, 0)
    }

    /// The other half: one membership change, one fact change, one
    /// resolution change each cost exactly one build (two sorts: the rows and
    /// the projects), and are published.
    func testOneMembershipFactOrResolutionChangeCostsExactlyOneBuild() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 30), Fixture.row("b", project: "/b", updated: 10)])
        freeze(app)
        try await settle()

        var cost = PresentationCost(app)
        XCTAssertTrue(app.overlay.join("new", via: .imported, agent: .claude, core: SessionCore(directory: "/new")).isJoined)
        XCTAssertEqual(cost.addedBuilds, 1, "a join")
        XCTAssertEqual(cost.addedSorts, 2)
        XCTAssertGreaterThan(cost.willChange, 0)
        XCTAssertEqual(app.displayProjects.map(\.path), ["/new", "/a", "/b"])
        try await settle()

        cost = PresentationCost(app)
        XCTAssertEqual(app.overlay.leave([SessionKey(id: "new", host: .local)]), ["new"])
        XCTAssertEqual(cost.addedBuilds, 1, "a leave")
        XCTAssertGreaterThan(cost.willChange, 0)
        try await settle()

        cost = PresentationCost(app)
        app.overlay.rename("b", to: "Renamed")
        XCTAssertEqual(cost.addedBuilds, 1, "a fact (the name)")
        XCTAssertGreaterThan(cost.willChange, 0)
        XCTAssertEqual(app.sessions.first { $0.id == "b" }?.displayTitle, "Renamed")
        try await settle()

        cost = PresentationCost(app)
        app.overlay.observeLaunchDirectory("b", host: .local, "/a")
        XCTAssertEqual(cost.addedBuilds, 1, "a fact (the folder)")
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a"])
        try await settle()

        cost = PresentationCost(app)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2,
            resolutions: ["a": .confirmedAbsent, "b": .loaded(TranscriptLocator(host: .local, path: "/tmp/b.jsonl"))]))
        XCTAssertEqual(cost.addedBuilds, 1, "a resolution")
        XCTAssertGreaterThan(cost.willChange, 0)
        try await settle()

        // A snapshot that changes nothing builds nothing.
        cost = PresentationCost(app)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 3,
            resolutions: ["a": .confirmedAbsent, "b": .loaded(TranscriptLocator(host: .local, path: "/tmp/b.jsonl"))]))
        XCTAssertEqual(cost.addedBuilds, 0)
        XCTAssertEqual(cost.willChange, 0)
    }

    /// A fill from engine facts is one fact change: one build, however many
    /// columns it writes.
    func testAFillFromEngineFactsCostsExactlyOneBuild() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "a", via: .opened, agent: .claude, core: SessionCore(directory: "/a"))
        let app = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()))
        freeze(app)
        try await settle()
        let summary = TranscriptSummary(id: "a", agent: .claude, locator: TranscriptLocator(host: .local, path: "/tmp/a.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 50), cwd: "/a", firstPrompt: "Filled title")
        let cost = PresentationCost(app)
        app.receiveEngineSnapshot(.authorized(generation: 2, resolutions: ["a": .confirmedAbsent],
                                              summaries: ["a": summary], in: db))
        XCTAssertEqual(try db.sessionState("a")?.title, "Filled title")
        XCTAssertEqual(cost.addedBuilds, 1)
        XCTAssertEqual(app.sessions.first?.displayTitle, "Filled title")
    }

    func testPendingActivityIsIncludedWhenRanksFreezeAndDirectoriesStayImmediate() throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", updated: 10)])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        app.overlay.observeLaunchDirectory("b", host: .local, "/b")
        XCTAssertEqual(app.displayProjects.map(\.path), ["/b", "/a"])
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1,
            resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent]))
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

    /// Another host's catalog entry for the same id is not this member's
    /// row: the member stands alone and shows its own activity time, so a
    /// touch must still reach the page.
    func testAStandaloneMemberBesideAConflictingCatalogEntryShowsItsTouches() async throws {
        let app = try model([Fixture.row("shared", project: "/p", updated: 20)])
        let elsewhere = TranscriptSummary(id: "shared", agent: .claude,
            locator: TranscriptLocator(host: HostID(rawValue: "box"), path: "opaque:shared"),
            modifiedAt: Date(timeIntervalSince1970: 5), cwd: "/p", firstPrompt: "Box copy")
        app.history.catalog = { AsyncStream { c in
            c.yield(.sessions([elsewhere], read: 1, total: 1), host: elsewhere.locator.host); c.finish()
        } }
        app.history.activate()
        let deadline = Date().addingTimeInterval(2)
        while app.history.readState != .done && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await app.history.settle()
        let member = try XCTUnwrap(app.history.allRows.first { $0.member != nil })
        XCTAssertNil(member.catalog, "the box's entry does not attach to this Mac's member")
        XCTAssertEqual(app.history.allRows.count, 2)
        let builds = app.history.rebuildCount
        app.overlay.touch("shared", host: .local, at: Date(timeIntervalSince1970: 400))
        await nextPresentationTurn()
        await app.history.settle()
        XCTAssertEqual(app.history.rebuildCount, builds + 1)
        XCTAssertEqual(app.history.allRows.first { $0.member != nil }?.updatedAt, Date(timeIntervalSince1970: 400))
    }

    func testHistoryDoesNotRebuildForCatalogMemberTouchBursts() async throws {
        let app = try model([Fixture.row("catalog", project: "/p", updated: 20),
                             Fixture.row("missing", updated: 10)])
        try await read(app, events: [.sessions([Fixture.session("catalog", project: "/p", updated: 5)], read: 1, total: 1)])
        await app.history.settle()
        let builds = app.history.rebuildCount
        let chronology = app.history.allRows.map(\.sessionID)
        for tick in 1...100 { app.overlay.touch("catalog", host: .local, at: Date(timeIntervalSince1970: Double(100 + tick))) }
        await nextPresentationTurn()
        await app.history.settle()
        XCTAssertEqual(app.history.rebuildCount, builds)
        XCTAssertEqual(app.history.allRows.map(\.sessionID), chronology)
        XCTAssertEqual(app.history.allRows.last?.updatedAt, Date(timeIntervalSince1970: 5))
        // An absent member DOES use row time, while titles still update for both.
        app.overlay.touch("missing", host: .local, at: Date(timeIntervalSince1970: 400))
        await nextPresentationTurn()
        await app.history.settle()
        XCTAssertEqual(app.history.rebuildCount, builds + 1)
        XCTAssertEqual(app.history.allRows.first?.updatedAt, Date(timeIntervalSince1970: 400))
        app.overlay.rename("catalog", to: "New catalog member title")
        await app.history.settle()
        XCTAssertEqual(app.history.rebuildCount, builds + 2)
        XCTAssertEqual(app.history.allRows.last?.title, "New catalog member title")
    }

    /// The rows an upgrade surfaces are archived from the selection bar in
    /// one go, as one undo step, with the import's notice pattern. The bar
    /// offers it only when every selected row can be archived.
    func testHistoryArchivesTheWholeSelectionAsOneUndoableStep() async throws {
        let app = try model([Fixture.row("a"), Fixture.row("b"), Fixture.row("c", project: "/p")])
        app.overlay.togglePin("b")
        app.history.catalog = { AsyncStream { $0.finish() } }
        app.history.activate()
        let deadline = Date().addingTimeInterval(2)
        while (app.history.readState != .done || app.history.allRows.count < 3) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        app.history.selectAll()
        XCTAssertEqual(app.history.selectedRows.count, 3)

        app.history.hasOpenTab = { $0.sessionID == "c" }
        XCTAssertFalse(app.history.canArchiveSelection, "not when it would skip a row")
        app.history.archiveSelected(undoManager: nil)
        XCTAssertFalse(app.overlay.rows["a"]!.archived)
        app.history.hasOpenTab = { _ in false }
        XCTAssertTrue(app.history.canArchiveSelection)

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        app.history.archiveSelected(undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(["a", "b", "c"].map { app.overlay.rows[$0]!.archived }, [true, true, true])
        XCTAssertTrue(app.history.selection.isEmpty)
        XCTAssertEqual(app.history.notice, HistoryModel.Notice(text: "3 sessions archived", offersUndo: true))
        XCTAssertEqual(undo.undoActionName, "Archive Sessions")

        undo.undo()
        XCTAssertEqual(["a", "b", "c"].map { app.overlay.rows[$0]!.archived }, [false, false, false])
        XCTAssertTrue(app.overlay.isPinned("b"), "the pin the archive dropped comes back")
        XCTAssertEqual(app.history.notice, HistoryModel.Notice(text: "3 archives undone", offersUndo: false))

        undo.redo()
        XCTAssertEqual(["a", "b", "c"].map { app.overlay.rows[$0]!.archived }, [true, true, true])
        XCTAssertEqual(app.history.notice?.text, "3 sessions archived")
    }

    func testHistoryArchivesDirectorylessMembersWithUndo() throws {
        let app = try model([Fixture.row("unknown"), Fixture.row("project", project: "/p")])
        let undo = UndoManager()
        for member in app.sessions {
            let row = HistoryRow(member: member)
            XCTAssertTrue(app.history.canArchive(row))
            app.history.hasOpenTab = { $0.sessionID == member.id }
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

    func testHistoryReturnRestoresANonResumableArchivedRowAndOpensNothing() async throws {
        let app = try model([Fixture.row("unknown")])
        app.archiveSession("unknown", undoManager: nil)
        let archived = await historyPage(app)
        XCTAssertEqual(archived, ["unknown"])
        let undo = UndoManager()
        undo.beginUndoGrouping()
        app.history.openSelected(undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertFalse(app.overlay.rows["unknown"]!.archived)
        XCTAssertTrue(app.openSessions.tabs.isEmpty)
        XCTAssertTrue(app.historyActive || app.openSessions.activeTab == nil, "nothing navigated away")
        undo.undo()
        XCTAssertTrue(app.overlay.rows["unknown"]!.archived)
        app.history.deactivate()
    }
    func testProjectFinderRevealRequiresLocalHostEvenWithTheSamePath() {
        let local = SessionRowProject(key: ProjectKey(host: .local, path: "/same"), sessions: [])
        let remote = SessionRowProject(key: ProjectKey(host: HostID(rawValue: "remote"), path: "/same"), sessions: [])
        XCTAssertEqual(local.localDirectoryURL, URL(fileURLWithPath: "/same"))
        XCTAssertNil(remote.localDirectoryURL)
    }

    func testAMemberWithoutATranscriptStillHasASidebarRow() throws {
        let app = try model([Fixture.row("missing", project: "/gone", title: "Kept")])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["missing": .confirmedAbsent]))
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
        XCTAssertEqual(SessionRowSearch.rank(rows, query: "auth").map(\.id), ["exact", "prefix", "sub", "project"])
        XCTAssertEqual(SessionRowSearch.rank(rows, query: "codex").map(\.id), ["agent"])
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

    func testHistoryArchivedIncludesMembersWithoutTranscriptsAndDirectories() async throws {
        let app = try model([Fixture.row("missing", project: "/gone", title: "Kept"), Fixture.row("unknown", title: "Directoryless")])
        app.overlay.setArchived(true, sessionID: "missing")
        app.overlay.setArchived(true, sessionID: "unknown")
        let archived = await historyPage(app)
        XCTAssertEqual(Set(archived), ["missing", "unknown"])
        let directoryless = try XCTUnwrap(app.history.visibleRows.first { $0.sessionID == "unknown" })
        XCTAssertEqual(directoryless.projectName, "No project")
        XCTAssertNil(directoryless.project)
        app.restoreSession("unknown", undoManager: nil)
        await app.history.settle()
        XCTAssertFalse(app.history.visibleRows.contains { $0.sessionID == "unknown" })
        app.history.deactivate()
    }
    private func read(_ app: AppModel, events: [CatalogBatch]) async throws {
        app.history.catalog = { AsyncStream { c in events.forEach { c.yield($0) }; c.finish() } }
        app.history.activate()
        let deadline = Date().addingTimeInterval(2)
        while app.history.readState != .done && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(app.history.readState, .done)
        await app.history.settle()
    }

    func testTempleRowsWithoutATranscriptAreTaggedOnlyFromACompletedResolution() async throws {
        let rows = ["absent", "unreadable", "resolving", "awaiting", "unknown"].map { Fixture.row($0, title: $0) }
        let app = try model(rows)
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["absent": .confirmedAbsent,
            "unreadable": .unreadable, "resolving": .resolving, "awaiting": .awaitingCreation]))
        try await read(app, events: [.storeFailed(agent: .codex, message: "Failed scan")])
        XCTAssertEqual(app.history.allRows.count, 5)
        XCTAssertEqual(app.history.allRows.filter(\.transcriptMissing).map(\.sessionID), ["absent"])
        XCTAssertTrue(app.history.allRows.allSatisfy { !$0.canResume })
        app.history.scope = .inTemple
        await app.history.settle()
        app.history.openSelected()
        await app.history.settle()
        XCTAssertTrue(app.openSessions.tabs.isEmpty)
        // A stale absence cannot replace newer unresolved evidence.
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["unknown": .confirmedAbsent]))
        await app.history.rebuild()
        XCTAssertFalse(app.history.allRows.first { $0.sessionID == "unknown" }!.transcriptMissing)
        // Cancelling a later scan leaves the member union and its evidence intact.
        app.history.catalog = { AsyncStream { _ in } }
        app.history.refresh()
        app.history.deactivate()
        await app.history.rebuild()
        XCTAssertEqual(app.history.allRows.count, 5)
        XCTAssertEqual(app.history.allRows.filter(\.transcriptMissing).map(\.sessionID), ["absent"])
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
        XCTAssertEqual(Set(app.history.allRows.map(\.sessionID)), ["member", "missing", "outside"])
        XCTAssertEqual(app.history.inTempleCount, 2)
        let member = try XCTUnwrap(app.history.allRows.first { $0.sessionID == "member" })
        XCTAssertEqual(member.title, "Durable title")
        XCTAssertEqual(member.updatedAt, disk.updatedAt)
        XCTAssertEqual(member.gitBranch, "catalog-branch")
        XCTAssertEqual(member.lastMessagePreview, "Catalog preview")
        XCTAssertFalse(member.transcriptMissing)
        XCTAssertEqual(app.history.allRows.first { $0.sessionID == "missing" }?.updatedAt, Date(timeIntervalSince1970: 50))
        XCTAssertFalse(app.history.allRows.first { $0.sessionID == "missing" }!.transcriptMissing)
        // The noisy disk entry was retained, so a later join reveals its disk facts.
        app.overlay.join("noisy-outside", via: .imported, agent: .claude,
            core: SessionCore(directory: "/", title: "New member", lastActiveAt: Date(timeIntervalSince1970: 200)))
        await app.history.rebuild()
        let joined = try XCTUnwrap(app.history.allRows.first { $0.sessionID == "noisy-outside" })
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
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["local": .confirmedAbsent, "remote": .confirmedAbsent]))
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
        XCTAssertEqual(app.overlay.archivedProjectKeys, [other])
        XCTAssertEqual(app.displayProjects.map(\.key), [local])
        app.restoreProject(other, undoManager: nil)
        app.moveProject(other, before: local)
        XCTAssertEqual(app.overlay.projectKeyOrder, [other, local])
        XCTAssertEqual(app.displayProjects.map(\.key), [other, local])
    }

    func testFrozenRankWaitsForTheFirstCompleteGeneration() async throws {
        let app = try model([Fixture.row("a", project: "/a", updated: 20), Fixture.row("b", project: "/b", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .resolving]))
        XCTAssertFalse(app.sidebarRanksFrozen)
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.path), ["/b", "/a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .resolving, "b": .confirmedAbsent]))
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent]))
        XCTAssertFalse(app.sidebarRanksFrozen, "a stale complete generation cannot freeze the newer one")
        app.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 40))
        await nextPresentationTurn()
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent]))
        XCTAssertTrue(app.sidebarRanksFrozen)
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 50))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.map(\.path), ["/a", "/b"])
    }

    func testSidebarSessionsSortLiveUntilInitialResolutionCompletes() async throws {
        let app = try model([Fixture.row("a", project: "/same", updated: 20), Fixture.row("b", project: "/same", updated: 10)])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .resolving]))
        app.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 30))
        await nextPresentationTurn()
        XCTAssertEqual(app.displayProjects.first?.sessions.map(\.id), ["b", "a"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .loaded(URL(fileURLWithPath: "/tmp/a.jsonl")), "b": .unreadable]))
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
        app.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .unreadable, "b": .awaitingCreation]))
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
            "remote": .loaded(TranscriptLocator(host: remote, path: "/remote/transcript.jsonl"))]))
        XCTAssertEqual(app.transcriptURL(for: "local"), localURL)
        XCTAssertNil(app.transcriptURL(for: "remote"), "remote locators cannot reveal a local file")
        let tab = SessionTab(kind: .session, sessionID: "local", agent: .codex,
            projectPath: "/wrong", title: "Old title")
        XCTAssertEqual(app.resumeArgv(for: tab), ["claude", "--resume", "local"])
        app.receiveEngineSnapshot(EngineSnapshot(generation: 2, resolutions: ["local": .confirmedAbsent,
            "remote": .unreadable]))
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
