import XCTest
@testable import TempleUI
import TempleCore

/// The sidebar order the user arranges, and that it survives archiving and
/// a new overlay (ADR-017). Archiving itself is covered with History
/// (HistoryArchiveTests), where archived sessions are found and restored.
@MainActor
final class ProjectOrderTests: XCTestCase {
    private func makeModel(_ rows: [Session],
                           database: TempleDB? = nil) -> (AppModel, SessionOverlayStore) {
        let database = database ?? (try! TempleDB.inMemory())
        Fixture.join(rows, to: database)
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay
        )
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, MemberResolution.confirmedAbsent) })))
        return (model, overlay)
    }

    private func twoProjects() -> [Session] {
        [

                Fixture.row("a1", project: "/p/a", title: "Alpha one", updated: 40),
                Fixture.row("a2", project: "/p/a", title: "Alpha two", updated: 30),

                Fixture.row("b1", project: "/p/b", title: "Beta one", updated: 20),
        ]
    }

    // MARK: Persistence

    func testArchiveStateAndProjectOrderSurviveANewOverlayOnTheSameDatabase() {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(twoProjects(), database: database)
        // Reorder while both projects are visible, so the move is a real one.
        model.moveProject(Fixture.key("/p/a"), after: Fixture.key("/p/b"))
        XCTAssertEqual(overlay.projectKeyOrder.map(\.path), ["/p/b", "/p/a"])
        overlay.setArchived(true, sessionID: "a2")
        overlay.setProjectArchived(true, key: Fixture.key("/p/b"))

        let reloaded = SessionOverlayStore(db: database)

        XCTAssertEqual(Set(reloaded.rows.values.filter(\.archived).map(\.id)), ["a2"])
        XCTAssertEqual(Set(reloaded.archivedProjectKeys.map(\.path)), ["/p/b"])
        XCTAssertEqual(reloaded.projectKeyOrder.map(\.path), ["/p/b", "/p/a"])
        XCTAssertTrue(reloaded.isArchived("a2"))
        XCTAssertTrue(reloaded.isProjectArchived(Fixture.key("/p/b")))
    }

    /// Archived (or noise-hidden) projects are absent from the list a move acts
    /// on, but they were placed too. A move must rewrite the visible slots and
    /// leave theirs alone — otherwise archiving C and nudging B would silently
    /// un-place C, and it would resurface "new", on top.
    func testMovingWhileAProjectIsArchivedKeepsItsSlot() {
        let index = [
            Fixture.row("a1", project: "/p/a", updated: 30),
            Fixture.row("b1", project: "/p/b", updated: 20),
            Fixture.row("c1", project: "/p/c", updated: 10),
        ]
        let (model, overlay) = makeModel(index)
        model.moveProject(Fixture.key("/p/c"), before: Fixture.key("/p/b"))               // A, C, B
        XCTAssertEqual(overlay.projectKeyOrder.map(\.path), ["/p/a", "/p/c", "/p/b"])

        overlay.setProjectArchived(true, key: Fixture.key("/p/c"))
        model.moveProject(Fixture.key("/p/b"), before: Fixture.key("/p/a"))               // visible: B, A
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a"])
        XCTAssertEqual(overlay.projectKeyOrder.map(\.path), ["/p/b", "/p/c", "/p/a"])

        overlay.setProjectArchived(false, key: Fixture.key("/p/c"))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/c", "/p/a"])
    }

    func testMergePlacesFirstTimeVisiblePathsAfterTheStoredOnes() {
        XCTAssertEqual(AppModel.merge(visibleOrder: ["d", "b", "a"], into: ["a", "c", "b"]),
                       ["d", "c", "b", "a"])
        XCTAssertEqual(AppModel.merge(visibleOrder: ["b", "a"], into: []), ["b", "a"])
        XCTAssertEqual(AppModel.merge(visibleOrder: [], into: ["a", "b"]), ["a", "b"])
    }

    // MARK: Manual order

    /// Drop on a header = before that project; drop in a body = after it. Both
    /// are stated against the visible order with the moving project already
    /// out of it, so dragging downward needs no off-by-one fix-up.
    func testDroppingAProjectBeforeOrAfterAnotherReordersTheSidebarAndPersists() {
        let index = [
            Fixture.row("a1", project: "/p/a", updated: 30),
            Fixture.row("b1", project: "/p/b", updated: 20),
            Fixture.row("c1", project: "/p/c", updated: 10),
        ]
        let (model, overlay) = makeModel(index)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b", "/p/c"])

        model.moveProject(Fixture.key("/p/c"), before: Fixture.key("/p/b"))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/c", "/p/b"])
        XCTAssertEqual(overlay.projectKeyOrder.map(\.path), ["/p/a", "/p/c", "/p/b"])

        model.moveProject(Fixture.key("/p/b"), before: Fixture.key("/p/a"))               // to the top
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a", "/p/c"])

        model.moveProject(Fixture.key("/p/b"), after: Fixture.key("/p/c"))                // to the bottom, dragging down
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/c", "/p/b"])

        model.moveProject(Fixture.key("/p/a"), after: Fixture.key("/p/c"))                // down past one
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/c", "/p/a", "/p/b"])
        XCTAssertEqual(model.orderedVisibleProjectKeys.map(\.path), ["/p/c", "/p/a", "/p/b"])
    }

    /// A drag that ends off any target (released over the terminal, cancelled
    /// with Escape) has no drop callback; `endProjectDrag` is the one exit
    /// every path takes, and nothing survives it.
    func testEndingAProjectDragClearsEveryPieceOfDragState() {
        let (model, _) = makeModel(twoProjects())

        model.beginProjectDrag(Fixture.key("/p/a"))
        model.projectDropSlot = .init(key: Fixture.key("/p/b"), edge: .top)
        model.projectDropOwner = "/p/b#header"
        XCTAssertEqual(model.draggedProjectKey?.path, "/p/a")

        model.endProjectDrag()

        XCTAssertNil(model.draggedProjectKey?.path)
        XCTAssertNil(model.projectDropSlot)
        XCTAssertNil(model.projectDropOwner)
    }

    func testDroppingAProjectWhereItAlreadySitsIsANoOp() {
        let index = [
            Fixture.row("a1", project: "/p/a", updated: 30),
            Fixture.row("b1", project: "/p/b", updated: 20),
        ]
        let (model, overlay) = makeModel(index)

        model.moveProject(Fixture.key("/p/a"), before: Fixture.key("/p/b"))   // already directly above b
        model.moveProject(Fixture.key("/p/b"), after: Fixture.key("/p/a"))    // already directly below a
        model.moveProject(Fixture.key("/p/a"), before: Fixture.key("/p/zzz")) // unknown target

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertTrue(overlay.projectKeyOrder.map(\.path).isEmpty)
    }

    /// A project discovered after the user arranged the rail sorts ABOVE the
    /// placed block — otherwise the newest thing you started would land under
    /// the eight-project cap and look like it never happened.
    func testAnUnplacedProjectSortsAboveThePlacedBlock() {
        let index = [
            Fixture.row("a1", project: "/p/a", updated: 30),
            Fixture.row("b1", project: "/p/b", updated: 20),
        ]
        let (model, overlay) = makeModel(index)
        model.moveProject(Fixture.key("/p/b"), before: Fixture.key("/p/a"))

        overlay.join("n1", via: .created, agent: .claude, core: SessionCore(directory: "/p/new", title: "Title", lastActiveAt: Date(timeIntervalSince1970: 50)))


        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/new", "/p/b", "/p/a"])
    }
}
