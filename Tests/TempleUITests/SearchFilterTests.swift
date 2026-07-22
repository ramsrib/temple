import XCTest
@testable import TempleUI
import TempleCore

struct NoNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

@MainActor
final class SearchFilterTests: XCTestCase {

    // MARK: Seams (C3 / C2 defaults)

    func testDefaultSearchFiltersByTitle() {
        let search = DefaultSessionSearch()
        let sessions = [
            Fixture.session("1", project: "/p", title: "Analyze project setup"),
            Fixture.session("2", project: "/p", title: "Inspect journal"),
        ]
        let hits = search.filter(sessions, query: "journal")
        XCTAssertEqual(hits.map(\.id), ["2"])
        XCTAssertEqual(search.filter(sessions, query: "").count, 2)  // empty → all
    }

    func testDefaultSearchRanksPrefixHighest() {
        let search = DefaultSessionSearch()
        let sessions = [
            Fixture.session("sub", project: "/p", title: "Deep analyze routine"),
            Fixture.session("pre", project: "/p", title: "Analyze project"),
            Fixture.session("word", project: "/p", title: "Run the analyze step"),
        ]
        let ranked = search.rank(sessions, query: "analyze")
        XCTAssertEqual(ranked.first?.id, "pre")   // prefix wins
    }

    func testCoreSearchUsesCoreRankingButKeepsFilterTitleOnly() {
        let search = CoreSessionSearch()
        let sessions = [
            Fixture.session("substring", project: "/work/else", title: "Fix the auth bug"),
            Fixture.session("exact", project: "/work/else", title: "auth"),
            Fixture.session("prefix", project: "/work/else", title: "Auth cleanup"),
            Fixture.session("project", project: "/work/auth", title: "Unrelated"),
            Fixture.session("agent", agent: .codex, project: "/work/else", title: "Other"),
        ]

        XCTAssertEqual(search.rank(sessions, query: "auth").map(\.id),
                       ["exact", "prefix", "substring", "project"])
        XCTAssertEqual(search.filter(sessions, query: "auth").map(\.id),
                       ["substring", "exact", "prefix"])
        XCTAssertTrue(search.filter(sessions, query: "codex").isEmpty)
    }

    func testDefaultNoiseFilterHidesRootAndMissingDirs() {
        let filter = DefaultNoiseFilter()
        XCTAssertTrue(filter.isNoise(Fixture.session("a", project: "/")))
        XCTAssertTrue(filter.isNoise(Fixture.session("b", project: "/does/not/exist/xyz")))
        XCTAssertFalse(filter.isNoise(Fixture.session("c", project: NSTemporaryDirectory())))
    }

    func testCoreNoiseFilterDelegatesAutomationClassification() {
        let session = AgentSession(
            id: "automation",
            agent: .codex,
            projectPath: NSTemporaryDirectory(),
            title: "Automation",
            createdAt: nil,
            updatedAt: Date(),
            filePath: URL(fileURLWithPath: "/tmp/automation.jsonl"),
            originator: "codex_exec"
        )
        XCTAssertTrue(CoreNoiseFilter().isNoise(session))
    }

    // MARK: AppModel sidebar wiring

    private func makeAppModel(_ index: SessionIndex, noise: NoiseFilter = NoNoiseFilter())
        -> (AppModel, SessionOverlayStore) {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        let settings = SettingsStore(defaults: Fixture.uniqueDefaults())
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             indexSource: FakeIndexSource(index),
                             noiseFilter: noise,
                             database: database,
                             settings: settings,
                             overlay: overlay)
        model.index = index
        return (model, overlay)
    }

    func testDisplayProjectsAppliesSearch() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [
                Fixture.session("1", project: "/p/a", title: "Analyze setup"),
                Fixture.session("2", project: "/p/a", title: "Inspect logs"),
            ]),
        ])
        let (model, _) = makeAppModel(index)
        model.searchText = "analyze"
        XCTAssertEqual(model.displayProjects.flatMap { $0.sessions }.map(\.id), ["1"])
    }

    func testPinnedSectionReflectsOverlay() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "T")]),
        ])
        let (model, overlay) = makeAppModel(index)
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        overlay.togglePin("1")
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["1"])
    }

    func testCustomNameOverridesTitle() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "Original")]),
        ])
        let (model, overlay) = makeAppModel(index)
        overlay.rename("1", to: "My name")
        XCTAssertEqual(model.displayTitle(index.allSessions[0]), "My name")
    }

    func testNoiseFilterHidesNoisySessionsUnlessShown() {
        let index = SessionIndex(projects: [
            Project(path: "/", sessions: [Fixture.session("noise", project: "/", title: "ambient")]),
            Project(path: NSTemporaryDirectory(), sessions: [
                Fixture.session("real", project: NSTemporaryDirectory(), title: "real"),
            ]),
        ])
        let (model, _) = makeAppModel(index, noise: DefaultNoiseFilter())
        XCTAssertEqual(model.displayProjects.flatMap { $0.sessions }.map(\.id), ["real"])
        model.showNoise = true
        XCTAssertEqual(Set(model.displayProjects.flatMap { $0.sessions }.map(\.id)), ["noise", "real"])
    }

    func testPaletteRanksAcrossAllProjects() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "Alpha task")]),
            Project(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "Alpine hike")]),
        ])
        let (model, _) = makeAppModel(index)
        let results = model.paletteResults("alp")
        XCTAssertEqual(Set(results.map(\.id)), ["1", "2"])
    }

    /// ⌘P is the ⌘⇥ gesture: the switcher walks projects most-recently-used
    /// first, so one tap-and-release lands on the project you were just in.
    func testProjectSwitcherWalksMostRecentlyUsedFirst() {
        let index = SessionIndex(projects: [
            Project(path: "/p/api", sessions: [Fixture.session("1", project: "/p/api", title: "t")]),
            Project(path: "/p/web", sessions: [Fixture.session("2", project: "/p/web", title: "t")]),
            Project(path: "/p/notes", sessions: [Fixture.session("3", project: "/p/notes", title: "t")]),
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
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            Project(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
            Project(path: "/p/c", sessions: [Fixture.session("3", project: "/p/c", title: "t")]),
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
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            Project(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
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
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("1", project: "/p/a", title: "t")]),
            Project(path: "/p/b", sessions: [Fixture.session("2", project: "/p/b", title: "t")]),
            Project(path: "/p/c", sessions: [Fixture.session("3", project: "/p/c", title: "t")]),
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

    private func manyProjectsIndex() -> SessionIndex {
        SessionIndex(projects: (0..<12).map { number in
            let path = "/projects/\(number)"
            return Project(path: path, sessions: [
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

    func testProjectOrderFrozenAtFirstPublishAndStableAcrossUpdates() {
        let a = Project(path: "/p/a", sessions: [Fixture.session("a1", project: "/p/a")])
        let b = Project(path: "/p/b", sessions: [Fixture.session("b1", project: "/p/b")])
        let (model, _) = makeAppModel(SessionIndex(projects: [a, b]))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])

        // New activity re-sorts the incoming index (b now first) — the sidebar
        // must NOT shuffle: launch order holds.
        model.index = SessionIndex(projects: [b, a])
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])

        // A genuinely new project surfaces at the top; existing ones stay put.
        let c = Project(path: "/p/c", sessions: [Fixture.session("c1", project: "/p/c")])
        model.index = SessionIndex(projects: [c, b, a])
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/c", "/p/a", "/p/b"])
    }

    func testSessionOrderWithinProjectFrozenAndNewSessionsPrepend() {
        let s1 = Fixture.session("s1", project: "/p/a")
        let s2 = Fixture.session("s2", project: "/p/a")
        let (model, _) = makeAppModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [s1, s2]),
        ]))
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2"])

        // Opening/resuming s2 bumps its recency — the incoming index reorders,
        // but the sidebar must not shuffle.
        model.index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [s2, s1]),
        ])
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s1", "s2"])

        // A brand-new session prepends at the top (fresh), others stay put.
        let s3 = Fixture.session("s3", project: "/p/a")
        model.index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [s3, s2, s1]),
        ])
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["s3", "s1", "s2"])
    }

    func testPaletteEmptyQueryListsOpenSessionsOnlyByRecency() {
        let a = Fixture.session("a1", project: "/p/a", updated: 50)
        let b = Fixture.session("b1", project: "/p/b", updated: 40)
        let c = Fixture.session("c1", project: "/p/c", updated: 20)
        let (model, _) = makeAppModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [a]),
            Project(path: "/p/b", sessions: [b]),
            Project(path: "/p/c", sessions: [c]),
        ]))
        // Nothing open → empty-query palette is empty (type-to-search hint);
        // browsing everything is ⌘Y's job.
        XCTAssertTrue(model.paletteResults("").isEmpty)

        model.openSessions.openSession(c)
        model.openSessions.openSession(a)
        // Open in "wrong" recency order: the switcher sorts by live activity,
        // not tab order, and never mixes in closed sessions ("b1").
        XCTAssertEqual(model.paletteResults("").map(\.id), ["a1", "c1"])
    }

    func testPaletteNonEmptyQueryWeightsOpenMatches() {
        let a = Fixture.session("a1", project: "/p/a", title: "alpha work", updated: 10)
        let b = Fixture.session("b1", project: "/p/b", title: "alpha review", updated: 30)
        let c = Fixture.session("c1", project: "/p/c", title: "alpha notes", updated: 20)
        let (model, _) = makeAppModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [a]),
            Project(path: "/p/b", sessions: [b]),
            Project(path: "/p/c", sessions: [c]),
        ]))

        model.openSessions.openSession(c)
        model.openSessions.openSession(a)
        // Search puts open matches above closed ones ("b1" matches but is closed).
        XCTAssertEqual(model.paletteResults("alpha").map(\.id).last, "b1")
        XCTAssertEqual(Set(model.paletteResults("alpha").prefix(2).map(\.id)), ["a1", "c1"])
    }

    func testCoreSearchRanksOverlayTitles() {
        let search = CoreSessionSearch()
        let sessions = [
            Fixture.session("renamed", project: "/p", title: "can you look at this thing"),
            Fixture.session("raw", project: "/p", title: "fivetran replication question"),
        ]
        // Without the override the renamed session is invisible to its
        // displayed title; with it, both match and the better band wins.
        XCTAssertEqual(search.rank(sessions, query: "fivetran").map(\.id), ["raw"])
        let ranked = search.rank(sessions, query: "finish fivetran",
                                 titleOverrides: ["renamed": "finish fivetran setup"])
        XCTAssertEqual(ranked.map(\.id), ["renamed"])
    }

    func testPaletteSearchMatchesRenamedAndGeneratedTitles() {
        let a = Fixture.session("a1", project: "/p/a", title: "first prompt about databases")
        let b = Fixture.session("b1", project: "/p/b", title: "unrelated prompt")
        let (model, overlay) = makeAppModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [a]),
            Project(path: "/p/b", sessions: [b]),
        ]))

        // The palette renders display titles, so search must match them too.
        overlay.rename("b1", to: "finish fivetran setup")
        XCTAssertEqual(model.paletteResults("fivetran").map(\.id), ["b1"])

        // Agent-generated titles participate the same way…
        overlay.titleFlushDelay = 0
        overlay.recordGeneratedTitle("fivetran backfill audit", for: "a1")
        overlay.flushPendingTitles()
        XCTAssertEqual(Set(model.paletteResults("fivetran").map(\.id)), ["a1", "b1"])

        // …and the raw file title still matches after an overlay exists.
        XCTAssertEqual(model.paletteResults("databases").map(\.id), ["a1"])
    }

    func testPaletteEmptyQueryBreaksRecencyTiesByID() {
        let b = Fixture.session("b", project: "/p/a", updated: 10)
        let a = Fixture.session("a", project: "/p/b", updated: 10)
        let (model, _) = makeAppModel(SessionIndex(projects: [
            Project(path: "/p/a", sessions: [b]),
            Project(path: "/p/b", sessions: [a]),
        ]))

        model.openSessions.openSession(b)
        model.openSessions.openSession(a)
        XCTAssertEqual(model.paletteResults("").map(\.id), ["a", "b"])
    }
}
