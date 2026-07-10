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

    func testDefaultNoiseFilterHidesRootAndMissingDirs() {
        let filter = DefaultNoiseFilter()
        XCTAssertTrue(filter.isNoise(Fixture.session("a", project: "/")))
        XCTAssertTrue(filter.isNoise(Fixture.session("b", project: "/does/not/exist/xyz")))
        XCTAssertFalse(filter.isNoise(Fixture.session("c", project: NSTemporaryDirectory())))
    }

    // MARK: AppModel sidebar wiring

    private func makeAppModel(_ index: SessionIndex, noise: NoiseFilter = NoNoiseFilter())
        -> (AppModel, SessionOverlayStore) {
        let overlay = SessionOverlayStore(defaults: Fixture.uniqueDefaults())
        let settings = SettingsStore(defaults: Fixture.uniqueDefaults())
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(),
                             indexSource: FakeIndexSource(index),
                             noiseFilter: noise,
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
}
