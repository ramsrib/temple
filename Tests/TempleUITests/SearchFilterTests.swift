import XCTest
@testable import TempleUI
import TempleCore


@MainActor
final class SearchFilterTests: XCTestCase {

    // MARK: Seams (C3 / C2 defaults)

    // MARK: AppModel sidebar wiring

    private func makeAppModel(_ index: CatalogFixtureIndex)
        -> (AppModel, SessionOverlayStore) {
        let database = try! TempleDB.inMemory()
        Fixture.join(index, to: database)
        let overlay = SessionOverlayStore(db: database)
        let settings = SettingsStore(defaults: Fixture.uniqueDefaults())
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             engines: [FakeEngine(index)],
                             database: database,
                             settings: settings,
                             overlay: overlay)

        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, MemberResolution.confirmedAbsent) })))
        return (model, overlay)
    }

    private func makeRowModel(_ rows: [Session]) -> (AppModel, SessionOverlayStore) {
        let db = try! TempleDB.inMemory()
        Fixture.join(rows, to: db)
        let overlay = SessionOverlayStore(db: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))], database: db,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()), overlay: overlay)
        return (model, overlay)
    }

    func testDisplayProjectsAppliesSearch() {
        let (model, _) = makeRowModel([
            Fixture.row("1", project: "/p/a", title: "Analyze setup"),
            Fixture.row("2", project: "/p/a", title: "Inspect logs")])
        model.searchText = "analyze"
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["1"])
    }

    func testPinnedSectionReflectsOverlay() {
        let (model, overlay) = makeRowModel([Fixture.row("1", project: "/p/a", title: "T")])
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        overlay.togglePin("1")
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["1"])
    }

    func testCustomNameOverridesTitle() {
        let (model, overlay) = makeRowModel([Fixture.row("1", project: "/p/a", title: "Original")])
        overlay.rename("1", to: "My name")
        XCTAssertEqual(model.displayProjects.first?.sessions.first?.displayTitle, "My name")
    }

    func testNoiseNeverHidesAMember() {
        let (model, _) = makeRowModel([Fixture.row("noise", project: "/", title: "ambient"),
            Fixture.row("real", project: NSTemporaryDirectory(), title: "real")])
        XCTAssertEqual(Set(model.displayProjects.flatMap(\.sessions).map(\.id)), ["noise", "real"])
        XCTAssertEqual(Set(model.displayProjects.flatMap(\.sessions).map(\.id)), ["noise", "real"])
    }

    func testPaletteRanksAcrossAllProjects() {
        let rows = [
            Fixture.row("1", project: "/p/a", title: "Alpha task"),
            Fixture.row("2", project: "/p/b", title: "Alpine hike"),
        ]
        let (model, _) = makeRowModel(rows)
        let results = model.paletteResults("alp")
        XCTAssertEqual(Set(results.map(\.id)), ["1", "2"])
    }

    /// ⌘P is the ⌘⇥ gesture: the switcher walks projects most-recently-used
    /// first, so one tap-and-release lands on the project you were just in.
    func testProjectSwitcherWalksMostRecentlyUsedFirst() {
        let index = CatalogFixtureIndex(projects: [
            CatalogFixtureProject(path: "/p/api", sessions: [Fixture.session("1", project: "/p/api", title: "t")]),
            CatalogFixtureProject(path: "/p/web", sessions: [Fixture.session("2", project: "/p/web", title: "t")]),
            CatalogFixtureProject(path: "/p/notes", sessions: [Fixture.session("3", project: "/p/notes", title: "t")]),
        ])
        let (model, _) = makeAppModel(index)
        model.openSessions.openSession(Fixture.session("1", project: "/p/api", title: "t"))
        model.openSessions.openSession(Fixture.session("2", project: "/p/web", title: "t"))
        model.openSessions.openSession(Fixture.session("3", project: "/p/notes", title: "t"))

        // Current project first, then the rest in the order you last used them —
        // NOT the order they were opened, which is what the sidebar shows.
        XCTAssertEqual(model.switchableProjectKeys.map(\.path), ["/p/notes", "/p/web", "/p/api"])

        // One press highlights the PREVIOUS project; releasing lands on it.
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherKeySelection?.path, "/p/web")
        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/web")
        XCTAssertFalse(model.projectSwitcherPresented)

        // ...and pressing again bounces straight back, because /p/notes is now
        // the most recent. That bounce is the whole point of the gesture.
        model.advanceProjectSwitcher(by: 1)
        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/notes")
    }

    /// A project's last tab can exit while the switcher is up. With the selection
    /// held as an index into a list that then shrank, releasing ⌘ would land on
    /// whatever slid into that slot — a project you never highlighted.
    func testProjectSwitcherSurvivesAProjectClosingWhileItIsUp() {
        let index = CatalogFixtureIndex(projects: [
            CatalogFixtureProject(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            CatalogFixtureProject(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
            CatalogFixtureProject(path: "/p/c", sessions: [Fixture.session("3", project: "/p/c", title: "t")]),
        ])
        let (model, _) = makeAppModel(index)
        model.openSessions.openSession(Fixture.session("1", project: "/p/a", title: "t"))
        model.openSessions.openSession(Fixture.session("2", project: "/p/b", title: "t"))
        model.openSessions.openSession(Fixture.session("3", project: "/p/c", title: "t"))

        model.advanceProjectSwitcher(by: 1)                   // highlights /p/b
        XCTAssertEqual(model.projectSwitcherKeySelection?.path, "/p/b")

        // /p/b's only tab exits while the switcher is up.
        let bTab = model.openSessions.tabs.first { $0.projectPath == "/p/b" }!
        model.openSessions.closeTab(bTab.id)

        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/c",
                       "must not land on a project that is no longer open, nor on whatever took its slot")
        XCTAssertFalse(model.projectSwitcherPresented)
        // ...and the closed project is forgotten, not kept forever in the MRU list.
        XCTAssertFalse(model.switchableProjectKeys.map(\.path).contains("/p/b"))
    }

    /// Opening the switcher from the home page (a click, no ⌘ held) must not be
    /// committed by the next unrelated modifier press.
    func testMouseOpenedSwitcherIsNotCommittedByAModifierRelease() {
        let index = CatalogFixtureIndex(projects: [
            CatalogFixtureProject(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            CatalogFixtureProject(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
        ])
        let (model, _) = makeAppModel(index)
        model.openSessions.openSession(Fixture.session("1", project: "/p/a", title: "t"))
        model.openSessions.openSession(Fixture.session("2", project: "/p/b", title: "t"))
        let active = model.openSessions.activeProjectKey?.path

        model.advanceProjectSwitcher(by: 1, heldCommand: false)
        model.commandReleasedForSwitcher()                     // e.g. ⌘ pressed for something else

        XCTAssertTrue(model.projectSwitcherPresented, "a click-opened switcher waits for Return or Esc")
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, active)
    }

    func testProjectSwitcherWalksAndCancels() {
        let index = CatalogFixtureIndex(projects: [
            CatalogFixtureProject(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            CatalogFixtureProject(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
            CatalogFixtureProject(path: "/p/c", sessions: [Fixture.session("3", project: "/p/c", title: "t")]),
        ])
        let (model, _) = makeAppModel(index)
        for id in ["1", "2", "3"] {
            model.openSessions.openSession(Fixture.session(id, project: "/p/\(["1": "a", "2": "b", "3": "c"][id]!)", title: "t"))
        }
        let active = model.openSessions.activeProjectKey?.path

        // Holding ⌘ and tapping P twice walks two along; wrapping is circular.
        let order = model.switchableProjectKeys.map(\.path)
        model.advanceProjectSwitcher(by: 1)
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherKeySelection?.path, order[2])
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherKeySelection?.path, order[0], "wraps back to where you started")

        // Esc leaves you exactly where you were.
        model.cancelProjectSwitcher()
        XCTAssertFalse(model.projectSwitcherPresented)
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, active)
    }

    // MARK: Project cap

    private func manyProjectsIndex() -> CatalogFixtureIndex {
        CatalogFixtureIndex(projects: (0..<12).map { number in
            let path = "/projects/\(number)"
            return CatalogFixtureProject(path: path, sessions: [
                Fixture.session(
                    "session-\(number)",
                    project: path,
                    title: "Project task \(number)",
                    updated: TimeInterval(12 - number)
                ),
            ])
        })
    }

    func testProjectListIsCappedByDefault() {
        let (model, _) = makeAppModel(manyProjectsIndex())

        XCTAssertEqual(model.cappedDisplayProjects.count, AppModel.projectCap)
        XCTAssertEqual(model.hiddenProjectsCount, 4)
    }

    func testActiveProjectOutsideCapRemainsVisible() {
        let index = manyProjectsIndex()
        let (model, _) = makeAppModel(index)
        let outsideProject = index.projects[11]

        model.openSessions.openSession(outsideProject.sessions[0])

        XCTAssertEqual(model.cappedDisplayProjects.count, AppModel.projectCap + 1)
        XCTAssertTrue(model.cappedDisplayProjects.contains { $0.path == outsideProject.path })
    }

    func testSearchBypassesProjectCap() {
        let (model, _) = makeAppModel(manyProjectsIndex())

        model.searchText = "Project task 11"

        XCTAssertEqual(model.cappedDisplayProjects.map(\.path), ["/projects/11"])
        XCTAssertEqual(model.hiddenProjectsCount, 0)
    }

    func testProjectCapDoesNotLimitHighlightOrPaletteData() {
        let (model, _) = makeAppModel(manyProjectsIndex())

        XCTAssertEqual(model.highlightableSessions.count, 12)
        XCTAssertEqual(model.paletteResults("Project task").count, 12)
    }

    // MARK: Launch-frozen project order

    func testProjectOrderFrozenAtFirstCompleteSnapshotAndStableAcrossUpdates() async {
        let (model, overlay) = makeRowModel([Fixture.row("a1", project: "/p/a", updated: 20),
            Fixture.row("b1", project: "/p/b", updated: 10)])
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a1": .confirmedAbsent, "b1": .confirmedAbsent]))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        overlay.touch("b1", host: .local, at: Date(timeIntervalSince1970: 50))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        overlay.join("c1", via: .created, agent: .claude, core: SessionCore(directory: "/p/c", title: "Title", lastActiveAt: Date(timeIntervalSince1970: 60)))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/c", "/p/a", "/p/b"])
    }

    func testSessionOrderWithinProjectFrozenAndNewSessionsPrepend() async {
        let (model, overlay) = makeRowModel([Fixture.row("s1", project: "/p/a", updated: 20),
            Fixture.row("s2", project: "/p/a", updated: 10)])
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["s1": .confirmedAbsent, "s2": .confirmedAbsent]))
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2"])
        overlay.touch("s2", host: .local, at: Date(timeIntervalSince1970: 50))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2"])
        overlay.join("s3", via: .created, agent: .claude, core: SessionCore(directory: "/p/a", title: "Title", lastActiveAt: Date(timeIntervalSince1970: 60)))
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s3", "s1", "s2"])
    }

    /// After the freeze a newcomer takes its place by recency: an old legacy
    /// row whose folder is filled in late does not jump to the top.
    func testALateOldRowIsPlacedByRecencyNotPrepended() async throws {
        let (model, overlay) = makeRowModel([Fixture.row("s1", project: "/p/a", updated: 20),
            Fixture.row("s2", project: "/p/a", updated: 10), Fixture.row("b1", project: "/p/b", updated: 15)])
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["s1": .confirmedAbsent,
            "s2": .confirmedAbsent, "b1": .confirmedAbsent]))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        overlay.join("old", via: .imported, agent: .claude,
                     core: SessionCore(directory: "/p/a", title: "Old", lastActiveAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2", "old"])
        overlay.join("oldproject", via: .imported, agent: .claude,
                     core: SessionCore(directory: "/p/old", title: "Old", lastActiveAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b", "/p/old"])
    }

    func testPaletteEmptyQueryListsOpenSessionsOnlyByRecency() async {
        let a = Fixture.row("a1", project: "/p/a", updated: 50)
        let b = Fixture.row("b1", project: "/p/b", updated: 40)
        let c = Fixture.row("c1", project: "/p/c", updated: 20)
        let (model, _) = makeRowModel( [
            a,
            b,
            c,
        ])
        // Nothing open → empty-query palette is empty (type-to-search hint);
        // browsing everything is ⌘Y's job.
        XCTAssertTrue(model.paletteResults("").isEmpty)

        model.openSessions.openSession(c)
        model.openSessions.openSession(a)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // Open in "wrong" recency order: the switcher sorts by live activity,
        // not tab order, and never mixes in closed sessions ("b1").
        XCTAssertEqual(model.paletteResults("").map(\.id), ["a1", "c1"])
    }

    func testPaletteNonEmptyQueryWeightsOpenMatches() {
        let a = Fixture.row("a1", project: "/p/a", title: "alpha work", updated: 10)
        let b = Fixture.row("b1", project: "/p/b", title: "alpha review", updated: 30)
        let c = Fixture.row("c1", project: "/p/c", title: "alpha notes", updated: 20)
        let (model, _) = makeRowModel( [
            a,
            b,
            c,
        ])

        model.openSessions.openSession(c)
        model.openSessions.openSession(a)
        // Search puts open matches above closed ones ("b1" matches but is closed).
        XCTAssertEqual(model.paletteResults("alpha").map(\.id).last, "b1")
        XCTAssertEqual(Set(model.paletteResults("alpha").prefix(2).map(\.id)), ["a1", "c1"])
    }



    func testPaletteSearchMatchesRenamedAndGeneratedTitles() {
        let a = Fixture.row("a1", project: "/p/a", title: "first prompt about databases")
        let b = Fixture.row("b1", project: "/p/b", title: "unrelated prompt")
        let (model, overlay) = makeRowModel( [
            a,
            b,
        ])

        // The palette renders display titles, so search must match them too.
        overlay.rename("b1", to: "finish fivetran setup")
        XCTAssertEqual(model.paletteResults("fivetran").map(\.id), ["b1"])

        // Agent-generated titles participate the same way…
        overlay.titleFlushDelay = 0
        overlay.recordGeneratedTitle("fivetran backfill audit", for: "a1")
        overlay.flushPendingTitles()
        XCTAssertEqual(Set(model.paletteResults("fivetran").map(\.id)), ["a1", "b1"])

        // Search follows the displayed title after a retitle.
        XCTAssertTrue(model.paletteResults("databases").isEmpty)
    }

    /// After the freeze a touch reorders the open-session palette without a
    /// redraw. Return must open the session the highlight is drawn on, not
    /// whichever one slid into its row.
    func testATouchBetweenDrawAndReturnStillOpensTheHighlightedSession() async {
        let a = Fixture.row("a", project: "/p/a", updated: 50)
        let b = Fixture.row("b", project: "/p/b", updated: 40)
        let (model, _) = makeRowModel([a, b])
        model.openSessions.openSession(b)
        model.openSessions.openSession(a)
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a": .confirmedAbsent, "b": .confirmedAbsent]))
        XCTAssertTrue(model.sidebarRanksFrozen)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let drawn = CommandPaletteView.results("", model: model)
        var cursor = PaletteCursor()
        cursor.anchor(in: drawn)
        let highlighted = try! XCTUnwrap(drawn.first)
        XCTAssertEqual(cursor.index(in: drawn), 0)
        // The user is on the other session's tab, so opening the highlighted
        // one is a visible change.
        let other = highlighted.id == "a" ? "b" : "a"
        model.openSessions.activate(model.openSessions.openTab(forSessionID: other)!)
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, other)

        // The other session works on: its touch reorders the list unseen.
        model.overlay.touch(other, host: .local, at: Date(timeIntervalSince1970: 9_000_000_000))
        XCTAssertEqual(CommandPaletteView.results("", model: model).first?.id, other, "the list moved under the highlight")

        CommandPaletteView.submit(cursor, query: "", model: model)
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, highlighted.id)
        // And the next draw lights the same session, wherever it now sits.
        let redrawn = CommandPaletteView.results("", model: model)
        XCTAssertEqual(cursor.selected(in: redrawn)?.id, highlighted.id)
        XCTAssertEqual(cursor.index(in: redrawn), 1)
    }

    /// Activity pushes the highlighted session past the 40-row cap between
    /// the draw and Return: Return still opens it, never the new first row.
    func testReturnOpensTheHighlightedSessionEvenWhenActivityPushesItPastTheCap() async {
        let rows = (0..<41).map { n in
            Fixture.row(String(format: "s%02d", n), project: "/p/\(n)", title: "session \(n)",
                        updated: TimeInterval(1_000 - n))
        }
        let (model, _) = makeRowModel(rows)
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions:
            Dictionary(uniqueKeysWithValues: rows.map { ($0.id, MemberResolution.confirmedAbsent) })))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let drawn = CommandPaletteView.results("session", model: model)
        XCTAssertEqual(drawn.count, 40)
        var cursor = PaletteCursor()
        cursor.select(try! XCTUnwrap(drawn.last))
        let highlighted = drawn.last!.id
        // The 41st session works on and moves ahead of the highlighted one,
        // which falls to row 41 — outside what the palette lists.
        let hidden = try! XCTUnwrap(model.paletteResults("session").last { !drawn.map(\.id).contains($0.id) })
        model.overlay.touch(hidden.id, host: .local, at: Date(timeIntervalSince1970: 9_000_000_000))
        XCTAssertFalse(CommandPaletteView.results("session", model: model).contains { $0.id == highlighted },
                       "the highlighted session left the capped list")

        CommandPaletteView.submit(cursor, query: "session", model: model)
        XCTAssertEqual(model.openSessions.activeTab?.sessionID, highlighted)
    }

    func testPaletteEmptyQueryBreaksRecencyTiesByID() async {
        let b = Fixture.row("b", project: "/p/a", updated: 10)
        let a = Fixture.row("a", project: "/p/b", updated: 10)
        let (model, _) = makeRowModel( [
            b,
            a,
        ])

        model.openSessions.openSession(b)
        model.openSessions.openSession(a)
        model.overlay.touch("a", host: .local, at: Date(timeIntervalSince1970: 9_000_000_000))
        model.overlay.touch("b", host: .local, at: Date(timeIntervalSince1970: 9_000_000_000))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.paletteResults("").map(\.id), ["a", "b"])
    }
    // MARK: ⌘K's way on to History

    /// Archived sessions are never in ⌘K, so a query that finds live
    /// sessions still ends with "Search history for …": ↓ past the last
    /// result reaches it, Return there opens History searching, ↑ goes back.
    func testATypedQueryEndsWithSearchHistoryEvenWithResults() async {
        let (model, _) = makeRowModel([
            Fixture.row("a", project: "/p/a", title: "deploy staging", updated: 20),
            Fixture.row("b", project: "/p/b", title: "deploy prod", updated: 10)])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let results = CommandPaletteView.results("deploy", model: model)
        XCTAssertEqual(results.count, 2)
        var cursor = PaletteCursor()
        cursor.anchor(in: results)
        cursor.move(1, in: results, historyRow: true)
        XCTAssertFalse(cursor.onHistoryRow)
        XCTAssertEqual(cursor.index(in: results), 1)
        cursor.move(1, in: results, historyRow: true)
        XCTAssertTrue(cursor.onHistoryRow, "↓ past the last result is the history row")
        XCTAssertNil(cursor.index(in: results), "no result is lit with it")
        cursor.anchor(in: results)
        XCTAssertTrue(cursor.onHistoryRow, "a redraw keeps the highlight where it is")
        cursor.move(1, in: results, historyRow: true)
        XCTAssertTrue(cursor.onHistoryRow, "it is the last row")
        cursor.move(-1, in: results, historyRow: true)
        XCTAssertEqual(cursor.selected(in: results)?.id, results.last?.id, "↑ goes back to the last result")
        cursor.move(1, in: results, historyRow: true)

        CommandPaletteView.submit(cursor, query: " deploy ", model: model)
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertEqual(model.history.query, "deploy")
        XCTAssertEqual(model.openSessions.activeTab?.kind, .history)
    }

    /// With no query there is no history row: ↓ stops at the last session.
    func testAnEmptyQueryHasNoHistoryRow() {
        let rows = [Fixture.row("a", project: "/p/a"), Fixture.row("b", project: "/p/b")]
        var cursor = PaletteCursor()
        cursor.select(rows[1])
        cursor.move(1, in: rows, historyRow: false)
        XCTAssertFalse(cursor.onHistoryRow)
        XCTAssertEqual(cursor.selected(in: rows)?.id, "b")
        var empty = PaletteCursor()
        empty.move(1, in: [], historyRow: true)
        XCTAssertTrue(empty.onHistoryRow, "with nothing found it is the only row")
    }
}
