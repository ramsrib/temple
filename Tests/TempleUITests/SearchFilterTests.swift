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
}
