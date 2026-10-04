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
                             indexSource: FakeIndexSource(index),
                             database: database,
                             settings: settings,
                             overlay: overlay)

        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, MemberResolution.confirmedAbsent) }), summaries: [:]))
        return (model, overlay)
    }

    private func makeRowModel(_ rows: [Session]) -> (AppModel, SessionOverlayStore) {
        let db = try! TempleDB.inMemory()
        Fixture.join(rows, to: db)
        let overlay = SessionOverlayStore(db: db)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(CatalogFixtureIndex(projects: [])), database: db,
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
        XCTAssertEqual(model.switchableProjects, ["/p/notes", "/p/web", "/p/api"])

        // One press highlights the PREVIOUS project; releasing lands on it.
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherSelection, "/p/web")
        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/web")
        XCTAssertFalse(model.projectSwitcherPresented)

        // ...and pressing again bounces straight back, because /p/notes is now
        // the most recent. That bounce is the whole point of the gesture.
        model.advanceProjectSwitcher(by: 1)
        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/notes")
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
        XCTAssertEqual(model.projectSwitcherSelection, "/p/b")

        // /p/b's only tab exits while the switcher is up.
        let bTab = model.openSessions.tabs.first { $0.projectPath == "/p/b" }!
        model.openSessions.closeTab(bTab.id)

        model.commitProjectSwitcher()
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/c",
                       "must not land on a project that is no longer open, nor on whatever took its slot")
        XCTAssertFalse(model.projectSwitcherPresented)
        // ...and the closed project is forgotten, not kept forever in the MRU list.
        XCTAssertFalse(model.switchableProjects.contains("/p/b"))
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
        let active = model.openSessions.activeProjectPath

        model.advanceProjectSwitcher(by: 1, heldCommand: false)
        model.commandReleasedForSwitcher()                     // e.g. ⌘ pressed for something else

        XCTAssertTrue(model.projectSwitcherPresented, "a click-opened switcher waits for Return or Esc")
        XCTAssertEqual(model.openSessions.activeProjectPath, active)
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
        let active = model.openSessions.activeProjectPath

        // Holding ⌘ and tapping P twice walks two along; wrapping is circular.
        let order = model.switchableProjects
        model.advanceProjectSwitcher(by: 1)
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherSelection, order[2])
        model.advanceProjectSwitcher(by: 1)
        XCTAssertEqual(model.projectSwitcherSelection, order[0], "wraps back to where you started")

        // Esc leaves you exactly where you were.
        model.cancelProjectSwitcher()
        XCTAssertFalse(model.projectSwitcherPresented)
        XCTAssertEqual(model.openSessions.activeProjectPath, active)
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
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["a1": .confirmedAbsent, "b1": .confirmedAbsent], summaries: [:]))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        overlay.touch("b1", at: Date(timeIntervalSince1970: 50))
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
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: ["s1": .confirmedAbsent, "s2": .confirmedAbsent], summaries: [:]))
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2"])
        overlay.touch("s2", at: Date(timeIntervalSince1970: 50))
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
            "s2": .confirmedAbsent, "b1": .confirmedAbsent], summaries: [:]))
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

    func testPaletteEmptyQueryBreaksRecencyTiesByID() async {
        let b = Fixture.row("b", project: "/p/a", updated: 10)
        let a = Fixture.row("a", project: "/p/b", updated: 10)
        let (model, _) = makeRowModel( [
            b,
            a,
        ])

        model.openSessions.openSession(b)
        model.openSessions.openSession(a)
        model.overlay.touch("a", at: Date(timeIntervalSince1970: 9_000_000_000))
        model.overlay.touch("b", at: Date(timeIntervalSince1970: 9_000_000_000))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(model.paletteResults("").map(\.id), ["a", "b"])
    }
}
