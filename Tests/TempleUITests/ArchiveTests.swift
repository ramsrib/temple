import XCTest
@testable import TempleUI
import TempleCore

private struct ArchiveNoNoiseFilter: NoiseFilter {
    func isNoise(_ session: AgentSession) -> Bool { false }
}

@MainActor
final class ArchiveTests: XCTestCase {
    private func makeModel(_ index: SessionIndex,
                           database: TempleDB? = nil) -> (AppModel, SessionOverlayStore) {
        let database = database ?? (try! TempleDB.inMemory())
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(index),
            noiseFilter: ArchiveNoNoiseFilter(),
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay
        )
        model.index = index
        return (model, overlay)
    }

    private func twoProjects() -> SessionIndex {
        SessionIndex(projects: [
            Project(path: "/p/a", sessions: [
                Fixture.session("a1", project: "/p/a", title: "Alpha one", updated: 40),
                Fixture.session("a2", project: "/p/a", title: "Alpha two", updated: 30),
            ]),
            Project(path: "/p/b", sessions: [
                Fixture.session("b1", project: "/p/b", title: "Beta one", updated: 20),
            ]),
        ])
    }

    // MARK: Sessions

    func testArchivingASessionHidesItFromEveryBrowseSurface() {
        let (model, overlay) = makeModel(twoProjects())
        overlay.togglePin("a1")
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["a1"])

        overlay.setArchived(true, sessionID: "a1")

        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a2", "b1"])
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        XCTAssertFalse(model.historyResults("").contains { $0.id == "a1" })
        XCTAssertFalse(model.paletteResults("").contains { $0.id == "a1" })
        XCTAssertFalse(model.paletteResults("alpha").contains { $0.id == "a1" })
        XCTAssertFalse(model.historyResults("alpha").contains { $0.id == "a1" })
        XCTAssertEqual(model.archivedSessionResults("").map(\.id), ["a1"])
        XCTAssertEqual(model.archivedSessionResults("alpha").map(\.id), ["a1"])

        overlay.setArchived(false, sessionID: "a1")
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a1", "a2", "b1"])
        XCTAssertTrue(model.archivedSessionResults("").isEmpty)
    }

    /// Pinned-and-archived is a contradiction: one says always in front of me,
    /// the other says put away. Unarchiving does not hand the pin back.
    func testArchivingClearsThePinAndUnarchivingDoesNotRestoreIt() {
        let (model, overlay) = makeModel(twoProjects())
        overlay.togglePin("a1")

        overlay.setArchived(true, sessionID: "a1")
        XCTAssertFalse(overlay.isPinned("a1"))

        overlay.setArchived(false, sessionID: "a1")
        XCTAssertFalse(overlay.isPinned("a1"))
        XCTAssertTrue(model.pinnedSessions.isEmpty)
    }

    /// One click archives; one keystroke takes it back. The pin the archive
    /// dropped returns with the session, and redo re-archives.
    func testArchivingFromTheSidebarIsUndoableAndRedoable() {
        let (model, overlay) = makeModel(twoProjects())
        let undo = UndoManager()
        undo.groupsByEvent = false
        overlay.togglePin("a1")

        undo.beginUndoGrouping()
        model.archiveSession("a1", undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertTrue(overlay.isArchived("a1"))
        XCTAssertFalse(overlay.isPinned("a1"))
        XCTAssertEqual(undo.undoActionName, "Archive Session")

        undo.undo()
        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertTrue(overlay.isPinned("a1"), "undo brings the dropped pin back")

        undo.redo()
        XCTAssertTrue(overlay.isArchived("a1"))

        undo.beginUndoGrouping()
        model.archiveProject("/p/b", undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Archive Project")
        undo.undo()
        XCTAssertFalse(overlay.isProjectArchived("/p/b"))
    }

    func testHomePageArchiveRowAppearsOnlyWhenSomethingIsArchived() {
        let (model, overlay) = makeModel(twoProjects())
        XCTAssertFalse(model.hasArchivedItems)
        overlay.setArchived(true, sessionID: "a1")
        XCTAssertTrue(model.hasArchivedItems)
        overlay.setArchived(false, sessionID: "a1")
        overlay.setProjectArchived(true, path: "/p/b")
        XCTAssertTrue(model.hasArchivedItems)
        overlay.setProjectArchived(false, path: "/p/b")
        XCTAssertFalse(model.hasArchivedItems)
    }

    // MARK: Projects

    func testArchivingAProjectHidesItAndItsSessions() {
        let (model, overlay) = makeModel(twoProjects())

        overlay.setProjectArchived(true, path: "/p/a")

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b"])
        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/b"])
        XCTAssertFalse(model.historyResults("").contains { $0.id == "a1" })
        XCTAssertEqual(model.archivedProjects.map(\.path), ["/p/a"])
        XCTAssertEqual(model.archivedProjectResults("/p/a").map(\.path), ["/p/a"])
        XCTAssertTrue(model.archivedProjectResults("beta").isEmpty)
        // The project row stands in for its sessions, so it must answer to what
        // you remember about them — the task, not just the folder.
        XCTAssertEqual(model.archivedProjectResults("alpha two").map(\.path), ["/p/a"])
        overlay.rename("a2", to: "Needle work")
        XCTAssertEqual(model.archivedProjectResults("needle").map(\.path), ["/p/a"])
        XCTAssertTrue(model.archivedProjectResults("zzz").isEmpty)

        // A session inside an archived project is represented by the project
        // row, so it must not also appear as a session result.
        overlay.setArchived(true, sessionID: "a1")
        XCTAssertTrue(model.archivedSessionResults("").isEmpty)

        overlay.setProjectArchived(false, path: "/p/a")
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertEqual(model.archivedSessionResults("").map(\.id), ["a1"])
    }

    // MARK: Persistence

    func testArchiveStateAndProjectOrderSurviveANewOverlayOnTheSameDatabase() {
        let database = try! TempleDB.inMemory()
        let (model, overlay) = makeModel(twoProjects(), database: database)
        // Reorder while both projects are visible, so the move is a real one.
        model.moveProject("/p/a", after: "/p/b")
        XCTAssertEqual(overlay.projectOrder, ["/p/b", "/p/a"])
        overlay.setArchived(true, sessionID: "a2")
        overlay.setProjectArchived(true, path: "/p/b")

        let reloaded = SessionOverlayStore(db: database)

        XCTAssertEqual(reloaded.archivedSessions, ["a2"])
        XCTAssertEqual(reloaded.archivedProjects, ["/p/b"])
        XCTAssertEqual(reloaded.projectOrder, ["/p/b", "/p/a"])
        XCTAssertTrue(reloaded.isArchived("a2"))
        XCTAssertTrue(reloaded.isProjectArchived("/p/b"))
    }

    /// Archived (or noise-hidden) projects are absent from the list a move acts
    /// on, but they were placed too. A move must rewrite the visible slots and
    /// leave theirs alone — otherwise archiving C and nudging B would silently
    /// un-place C, and it would resurface "new", on top.
    func testMovingWhileAProjectIsArchivedKeepsItsSlot() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("a1", project: "/p/a", updated: 30)]),
            Project(path: "/p/b", sessions: [Fixture.session("b1", project: "/p/b", updated: 20)]),
            Project(path: "/p/c", sessions: [Fixture.session("c1", project: "/p/c", updated: 10)]),
        ])
        let (model, overlay) = makeModel(index)
        model.moveProject("/p/c", before: "/p/b")               // A, C, B
        XCTAssertEqual(overlay.projectOrder, ["/p/a", "/p/c", "/p/b"])

        overlay.setProjectArchived(true, path: "/p/c")
        model.moveProject("/p/b", before: "/p/a")               // visible: B, A
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a"])
        XCTAssertEqual(overlay.projectOrder, ["/p/b", "/p/c", "/p/a"])

        overlay.setProjectArchived(false, path: "/p/c")
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
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("a1", project: "/p/a", updated: 30)]),
            Project(path: "/p/b", sessions: [Fixture.session("b1", project: "/p/b", updated: 20)]),
            Project(path: "/p/c", sessions: [Fixture.session("c1", project: "/p/c", updated: 10)]),
        ])
        let (model, overlay) = makeModel(index)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b", "/p/c"])

        model.moveProject("/p/c", before: "/p/b")
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/c", "/p/b"])
        XCTAssertEqual(overlay.projectOrder, ["/p/a", "/p/c", "/p/b"])

        model.moveProject("/p/b", before: "/p/a")               // to the top
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b", "/p/a", "/p/c"])

        model.moveProject("/p/b", after: "/p/c")                // to the bottom, dragging down
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/c", "/p/b"])

        model.moveProject("/p/a", after: "/p/c")                // down past one
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/c", "/p/a", "/p/b"])
        XCTAssertEqual(model.orderedVisibleProjectPaths, ["/p/c", "/p/a", "/p/b"])
    }

    /// A drag that ends off any target (released over the terminal, cancelled
    /// with Escape) has no drop callback; `endProjectDrag` is the one exit
    /// every path takes, and nothing survives it.
    func testEndingAProjectDragClearsEveryPieceOfDragState() {
        let (model, _) = makeModel(twoProjects())

        model.beginProjectDrag("/p/a")
        model.projectDropSlot = .init(path: "/p/b", edge: .top)
        model.projectDropOwner = "/p/b#header"
        XCTAssertEqual(model.draggedProjectPath, "/p/a")

        model.endProjectDrag()

        XCTAssertNil(model.draggedProjectPath)
        XCTAssertNil(model.projectDropSlot)
        XCTAssertNil(model.projectDropOwner)
    }

    func testDroppingAProjectWhereItAlreadySitsIsANoOp() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("a1", project: "/p/a", updated: 30)]),
            Project(path: "/p/b", sessions: [Fixture.session("b1", project: "/p/b", updated: 20)]),
        ])
        let (model, overlay) = makeModel(index)

        model.moveProject("/p/a", before: "/p/b")   // already directly above b
        model.moveProject("/p/b", after: "/p/a")    // already directly below a
        model.moveProject("/p/a", before: "/p/zzz") // unknown target

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertTrue(overlay.projectOrder.isEmpty)
    }

    /// A project discovered after the user arranged the rail sorts ABOVE the
    /// placed block — otherwise the newest thing you started would land under
    /// the eight-project cap and look like it never happened.
    func testAnUnplacedProjectSortsAboveThePlacedBlock() {
        let index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [Fixture.session("a1", project: "/p/a", updated: 30)]),
            Project(path: "/p/b", sessions: [Fixture.session("b1", project: "/p/b", updated: 20)]),
        ])
        let (model, _) = makeModel(index)
        model.moveProject("/p/b", before: "/p/a")

        model.index = SessionIndex(projects: index.projects + [
            Project(path: "/p/new", sessions: [Fixture.session("n1", project: "/p/new", updated: 50)]),
        ])

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/new", "/p/b", "/p/a"])
    }

    // MARK: Opening unarchives

    func testOpeningAnArchivedSessionUnarchivesItAndItsProject() {
        let index = twoProjects()
        let (model, overlay) = makeModel(index)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, path: "/p/a")

        let session = index.projects[0].sessions[0]
        model.openSessions.openSession(session)

        // The unarchive rides the activeTabID sink, which lands on RunLoop.main.
        let settled = expectation(description: "active tab sink")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertFalse(overlay.isProjectArchived("/p/a"))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
    }

    /// The sink lands a run-loop turn late. Open archived A and land on B
    /// inside one turn, and a sink that read "the active tab" would see B
    /// twice: A stays put away despite being opened.
    func testOpeningThenSwitchingWithinOneTurnStillUnarchivesTheOpenedSession() {
        let index = twoProjects()
        let (model, overlay) = makeModel(index)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, path: "/p/a")

        model.openSessions.openSession(index.projects[0].sessions[0])   // a1
        model.openSessions.openSession(index.projects[1].sessions[0])   // b1, now active

        let settled = expectation(description: "active tab sink")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "b1")
        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertFalse(overlay.isProjectArchived("/p/a"))
    }

    /// Index churn is not a decision: a session resumed in some other terminal
    /// updates its file, and must stay archived.
    func testDiskActivityDoesNotUnarchive() {
        let index = twoProjects()
        let (model, overlay) = makeModel(index)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, path: "/p/b")

        model.index = SessionIndex(projects: [
            Project(path: "/p/a", sessions: [
                Fixture.session("a1", project: "/p/a", title: "Alpha one", updated: 400),
                index.projects[0].sessions[1],
            ]),
            Project(path: "/p/b", sessions: [
                Fixture.session("b1", project: "/p/b", title: "Beta one", updated: 500),
            ]),
        ])

        XCTAssertTrue(overlay.isArchived("a1"))
        XCTAssertTrue(overlay.isProjectArchived("/p/b"))
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a2"])
    }

    // MARK: Panel exclusivity

    /// Every presenter dismisses the archive browser, and the archive browser
    /// dismisses every other panel and both HUD switchers.
    func testArchiveIsMutuallyExclusiveWithEveryOtherPanel() {
        let (model, _) = makeModel(SessionIndex(projects: []))
        let others: [(String, KeyPath<AppModel, Bool>, () -> Void)] = [
            ("palette", \.commandPalettePresented, { model.toggleCommandPalette() }),
            ("history", \.historyPresented, { model.toggleHistory() }),
            ("new session picker", \.newSessionPickerPresented, { model.toggleNewSessionPicker() }),
            ("shortcuts", \.shortcutsPresented, { model.toggleShortcuts() }),
        ]

        for (name, presented, present) in others {
            model.archivePresented = false
            model.toggleArchive()
            XCTAssertTrue(model.archivePresented, name)
            present()
            XCTAssertTrue(model[keyPath: presented], "\(name) should present")
            XCTAssertFalse(model.archivePresented, "\(name) should dismiss the archive")

            model.toggleArchive()
            XCTAssertTrue(model.archivePresented, name)
            XCTAssertFalse(model[keyPath: presented], "the archive should dismiss \(name)")
        }

        model.projectSwitcherPresented = true
        model.tabSwitcherPresented = true
        model.toggleArchive()   // was up from the loop's last pass: this dismisses it
        model.toggleArchive()
        XCTAssertTrue(model.archivePresented)
        XCTAssertFalse(model.projectSwitcherPresented, "the archive should cancel the ⌘P switcher")
        XCTAssertFalse(model.tabSwitcherPresented, "the archive should cancel the ⌃⇥ switcher")
    }
}
