import XCTest
@testable import TempleUI
import TempleCore

/// The History tab's model: a snapshot of the whole disk joined with Temple's
/// membership, the page's search and filters over it, native-style
/// selection, and import with its undo.
@MainActor
final class HistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }()

    /// Noon today: rows are placed by hours before it.
    private lazy var now: Date = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    private func session(_ id: String, project: String = "/p/a", agent: Agent = .claude,
                         title: String? = nil, hoursAgo: Double, branch: String? = nil,
                         preview: String? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, projectPath: project, title: title ?? "Title \(id)",
                     createdAt: nil, updatedAt: now.addingTimeInterval(-hoursAgo * 3600),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                     lastMessagePreview: preview, gitBranch: branch)
    }

    private static func stream(_ events: [SessionCatalog.Event]) -> AsyncStream<SessionCatalog.Event> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private struct Harness {
        let history: HistoryModel
        let overlay: SessionOverlayStore
        let database: TempleDB
        let opened: () -> [String]
    }

    /// `members` are already Temple's; `rows` is the disk, newest first.
    private func harness(_ rows: [AgentSession], members: [String] = [],
                         missing: Set<String> = []) -> Harness {
        let database = try! TempleDB.inMemory()
        for id in members { try! database.join(sessionID: id, via: .opened) }
        let overlay = SessionOverlayStore(db: database)
        let history = HistoryModel(
            overlay: overlay,
            catalog: { Self.stream([.listed(total: rows.count),
                                    .sessions(rows, read: rows.count, total: rows.count)]) },
            pathExists: { !missing.contains($0) },
            now: { [now] in now })
        history.memberStates = { (try? database.sessionStates()) ?? [] }
        var opened: [String] = []
        history.openSession = { opened.append($0.id) }
        return Harness(history: history, overlay: overlay, database: database, opened: { opened })
    }

    private func load(_ history: HistoryModel, file: StaticString = #filePath, line: UInt = #line) async {
        history.activate()
        await waitFor(file: file, line: line) { history.readState == .done }
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func ids(_ rows: [AgentSession]) -> [String] { rows.map(\.id) }

    // MARK: Grouping

    func testHistoryGroupingTitlesAndPreservesInputOrderWithinDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 7, 22, 18)
        let sessions = [
            Fixture.session("today-newer", project: "/p", updated: date(2026, 7, 22, 16).timeIntervalSince1970),
            Fixture.session("today-older", project: "/p", updated: date(2026, 7, 22, 9).timeIntervalSince1970),
            Fixture.session("yesterday", project: "/p", updated: date(2026, 7, 21).timeIntervalSince1970),
            Fixture.session("this-year", project: "/p", updated: date(2026, 7, 10).timeIntervalSince1970),
            Fixture.session("older-year", project: "/p", updated: date(2025, 12, 31).timeIntervalSince1970),
        ]

        let groups = HistoryGrouping.groups(sessions, calendar: calendar, now: now)

        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map(\.title),
                       ["Today", "Yesterday", "Friday, Jul 10", "Dec 31, 2025"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["today-newer", "today-older"])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.id), sessions.map(\.id))
    }

    // MARK: Snapshot

    func testTheSnapshotListsEveryNonNoiseSessionNewestFirstAndMarksMembership() async {
        let rows = [
            session("new", hoursAgo: 1),
            session("orphan", project: "/gone", hoursAgo: 2),
            session("root", project: "/", hoursAgo: 3),
            session("mine", hoursAgo: 30),
            session("old", project: "/p/b", hoursAgo: 60),
        ]
        let h = harness(rows, members: ["mine"], missing: ["/gone"])

        await load(h.history)

        XCTAssertEqual(ids(h.history.allRows), ["new", "mine", "old"], "noise stays hidden")
        XCTAssertEqual(h.history.inTempleCount, 1)
        XCTAssertTrue(h.history.isInTemple("mine"))
        XCTAssertFalse(h.history.isInTemple("new"))
        XCTAssertEqual(h.history.groups.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(h.history.agentCounts[.claude], 3)
        XCTAssertEqual(h.history.projects.first?.path, "/p/a")
        XCTAssertNotNil(h.history.lastUpdated)
    }

    func testDuplicateIDsAreDedupedFirstFileWins() async {
        let first = session("dup", title: "Newest copy", hoursAgo: 1)
        let second = session("dup", project: "/p/b", title: "Older copy", hoursAgo: 5)
        let h = harness([first, second])

        await load(h.history)

        XCTAssertEqual(h.history.allRows.map(\.title), ["Newest copy"])
    }

    func testTempleRowsPreferTheLiveIndexCopy() async {
        let disk = session("mine", title: "First prompt", hoursAgo: 5)
        let live = session("mine", title: "Fresher title", hoursAgo: 1)
        let h = harness([disk], members: ["mine"])
        h.history.liveIndexChanged(SessionIndex(projects: [Project(path: "/p/a", sessions: [live])]))

        await load(h.history)

        XCTAssertEqual(h.history.allRows.map(\.title), ["Fresher title"])
    }

    func testArchivedTempleRowsAreShownTaggedUnderInTemple() async {
        let rows = [session("put-away", hoursAgo: 1), session("project-away", project: "/p/b", hoursAgo: 2),
                    session("outside", hoursAgo: 3)]
        let h = harness(rows, members: ["put-away", "project-away"])
        h.overlay.setArchived(true, sessionID: "put-away")
        h.overlay.setProjectArchived(true, path: "/p/b")

        await load(h.history)
        h.history.scope = .inTemple

        XCTAssertEqual(ids(h.history.visibleRows), ["put-away", "project-away"])
        XCTAssertTrue(h.history.isArchived(rows[0]))
        XCTAssertTrue(h.history.isArchived(rows[1]))
        XCTAssertFalse(h.history.isArchived(rows[2]), "an outside row is never 'archived'")
    }

    func testStreamingShowsRowsBeforeTheReadEndsAndRecordsStoreFailures() async {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        var continuation: AsyncStream<SessionCatalog.Event>.Continuation!
        let stream = AsyncStream<SessionCatalog.Event> { continuation = $0 }
        let history = HistoryModel(overlay: overlay, catalog: { stream },
                                   pathExists: { _ in true }, now: { [now] in now })

        history.activate()
        XCTAssertEqual(history.readState, .reading(read: 0, total: nil))
        continuation.yield(.listed(total: 3))
        continuation.yield(.storeFailed(.codex, message: "permission denied"))
        continuation.yield(.sessions([session("a", hoursAgo: 1)], read: 1, total: 3))
        await waitFor { history.allRows.count == 1 }
        XCTAssertEqual(history.readState, .reading(read: 1, total: 3))
        XCTAssertEqual(history.storeFailures, [.init(agent: .codex, message: "permission denied")])
        XCTAssertEqual(history.selection, ["a"], "the first row is selected as soon as there is one")

        continuation.yield(.sessions([session("b", hoursAgo: 2)], read: 3, total: 3))
        continuation.finish()
        await waitFor { history.readState == .done }
        XCTAssertEqual(ids(history.allRows), ["a", "b"])
        XCTAssertEqual(history.selection, ["a"], "later batches never move the selection")
    }

    /// The tab leaving the screen cancels its read; a later refresh replaces
    /// the snapshot whole, dropping sessions gone from disk.
    func testDeactivateCancelsAndARefreshPrunesVanishedRows() async {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        var reads: [[AgentSession]] = [[session("a", hoursAgo: 1), session("gone", hoursAgo: 2)],
                                       [session("a", hoursAgo: 1)]]
        var pending: AsyncStream<SessionCatalog.Event>.Continuation?
        let cancelled = CancelFlag()
        let history = HistoryModel(overlay: overlay, catalog: {
            AsyncStream { continuation in
                pending = continuation
                continuation.onTermination = { reason in
                    if case .cancelled = reason { cancelled.set() }
                }
            }
        }, pathExists: { _ in true }, now: { [now] in now })

        history.activate()
        history.deactivate()
        await waitFor { cancelled.isSet }
        XCTAssertEqual(history.readState, .idle)

        for rows in [reads.removeFirst(), reads.removeFirst()] {
            history.refresh()
            pending?.yield(.listed(total: rows.count))
            pending?.yield(.sessions(rows, read: rows.count, total: rows.count))
            pending?.finish()
            await waitFor { history.readState == .done }
        }
        XCTAssertEqual(ids(history.allRows), ["a"])
    }

    // MARK: Search and filters

    func testSearchNarrowsWithinDayGroupsAndMatchesEveryField() async {
        let rows = [
            session("t1", title: "Fix watcher", hoursAgo: 1),
            session("t2", title: "Unrelated", hoursAgo: 2, branch: "fix/watcher"),
            session("t3", title: "Other", hoursAgo: 3),
            session("y1", project: "/p/watchtower", title: "Yesterday's", hoursAgo: 30),
            session("y2", title: "Quiet", hoursAgo: 31, preview: "the WATCHER fired twice"),
            session("abc123-def", title: "By id", hoursAgo: 32),
        ]
        let h = harness(rows, members: ["t3"])
        h.overlay.rename("t3", to: "Renamed watcher work")
        await load(h.history)

        h.history.query = "watch"
        XCTAssertEqual(ids(h.history.visibleRows), ["t1", "t2", "t3", "y1", "y2"])
        XCTAssertEqual(h.history.groups.map(\.title), ["Today", "Yesterday"], "day grouping survives search")
        XCTAssertEqual(h.history.groups[0].sessions.map(\.id), ["t1", "t2", "t3"])
        XCTAssertTrue(h.history.isNarrowed)

        h.history.query = "ABC1"
        XCTAssertEqual(ids(h.history.visibleRows), ["abc123-def"], "a pasted id prefix finds its row")
    }

    func testFiltersComposeWithEachOtherAndWithSearch() async {
        let rows = [
            session("c-in", agent: .claude, title: "Alpha", hoursAgo: 1),
            session("c-out", agent: .claude, title: "Alpha", hoursAgo: 2),
            session("x-out", agent: .codex, title: "Alpha", hoursAgo: 3),
            session("x-out-b", project: "/p/b", agent: .codex, title: "Alpha", hoursAgo: 4),
            session("x-beta", agent: .codex, title: "Beta", hoursAgo: 5),
        ]
        let h = harness(rows, members: ["c-in"])
        await load(h.history)
        XCTAssertFalse(h.history.isNarrowed)

        h.history.scope = .notInTemple
        XCTAssertEqual(ids(h.history.visibleRows), ["c-out", "x-out", "x-out-b", "x-beta"])
        h.history.agentFilter = .codex
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-out-b", "x-beta"])
        h.history.projectFilter = "/p/a"
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-beta"])
        h.history.query = "alpha"
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out"])

        h.history.query = ""
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-beta"], "clearing search keeps the filters")
        h.history.scope = .inTemple
        XCTAssertEqual(ids(h.history.visibleRows), [])
        // Counts are over the whole disk, not the view.
        XCTAssertEqual(h.history.agentCounts[.codex], 3)
    }

    /// Hidden selected rows are how someone imports things they cannot see.
    func testSelectionClearsOnEveryFilterChangeAndTheCursorReturnsToTheTop() async {
        let rows = [session("a", hoursAgo: 1), session("b", hoursAgo: 2), session("c", project: "/p/b", hoursAgo: 3)]
        let h = harness(rows)
        await load(h.history)
        h.history.selectAll()
        XCTAssertEqual(h.history.selection, ["a", "b", "c"])

        h.history.projectFilter = "/p/b"
        XCTAssertEqual(h.history.selection, ["c"])

        h.history.projectFilter = nil
        h.history.click("b")
        h.history.click("c", modifier: .command)
        h.history.query = "Title"
        XCTAssertEqual(h.history.selection, ["a"])
    }

    // MARK: Selection

    func testClickCommandClickShiftClickAndArrowExtension() async {
        let rows = (0..<6).map { session("r\($0)", hoursAgo: Double($0) + 1) }
        let h = harness(rows)
        await load(h.history)

        h.history.click("r1")
        XCTAssertEqual(h.history.selection, ["r1"])
        h.history.click("r3", modifier: .command)
        XCTAssertEqual(h.history.selection, ["r1", "r3"])
        h.history.click("r3", modifier: .command)
        XCTAssertEqual(h.history.selection, ["r1"])
        h.history.click("r1")
        h.history.click("r4", modifier: .shift)
        XCTAssertEqual(h.history.selection, ["r1", "r2", "r3", "r4"])

        h.history.click("r2")
        h.history.moveCursor(by: 1, extend: true)
        h.history.moveCursor(by: 1, extend: true)
        XCTAssertEqual(h.history.selection, ["r2", "r3", "r4"])
        h.history.moveCursor(by: 1)
        XCTAssertEqual(h.history.selection, ["r5"])
        h.history.moveCursor(by: 5)
        XCTAssertEqual(h.history.cursorID, "r5", "the cursor stops at the end")
        h.history.moveCursorToEnd(top: true)
        XCTAssertEqual(h.history.selection, ["r0"])
    }

    func testOptionArrowsJumpByDay() async {
        let rows = [session("t1", hoursAgo: 1), session("t2", hoursAgo: 2),
                    session("y1", hoursAgo: 30), session("y2", hoursAgo: 31),
                    session("o1", hoursAgo: 80)]
        let h = harness(rows)
        await load(h.history)
        h.history.click("t2")

        h.history.moveCursorByDay(forward: true)
        XCTAssertEqual(h.history.cursorID, "y1")
        h.history.moveCursorByDay(forward: true)
        XCTAssertEqual(h.history.cursorID, "o1")
        h.history.click("y2")
        h.history.moveCursorByDay(forward: false)
        XCTAssertEqual(h.history.cursorID, "y1", "up first lands on the day's own first row")
        h.history.moveCursorByDay(forward: false)
        XCTAssertEqual(h.history.cursorID, "t1")
    }

    func testSelectAllTakesOnlyTheCurrentView() async {
        let rows = [session("a", hoursAgo: 1), session("b", project: "/p/b", hoursAgo: 2),
                    session("c", project: "/p/b", hoursAgo: 3)]
        let h = harness(rows)
        await load(h.history)
        h.history.showOnly(project: "/p/b")

        h.history.selectAll()

        XCTAssertEqual(h.history.selection, ["b", "c"])
    }

    func testReturnOpensOneRowAndNothingForSeveral() async {
        let rows = [session("a", hoursAgo: 1), session("b", hoursAgo: 2)]
        let h = harness(rows)
        await load(h.history)

        h.history.openSelected()
        XCTAssertEqual(h.opened(), ["a"])

        h.history.selectAll()
        h.history.openSelected()
        XCTAssertEqual(h.opened(), ["a"], "a tab is a process: no bulk open")
    }

    func testEscapeLadderClearsSearchThenSelectionThenLeaves() async {
        let h = harness([session("a", hoursAgo: 1)])
        await load(h.history)
        h.history.query = "Title"

        XCTAssertEqual(h.history.escape(), .clearedSearch)
        XCTAssertEqual(h.history.query, "")
        XCTAssertEqual(h.history.escape(), .clearedSelection)
        XCTAssertTrue(h.history.selection.isEmpty)
        XCTAssertEqual(h.history.escape(), .leave)
    }

    // MARK: Import

    func testImportCopyNamesWhereRowsWillAppear() {
        let one = HistoryModel.importRequest(for: [session("a", project: "/x/raven", title: "Fix flaky test", hoursAgo: 1)])
        XCTAssertEqual(one.title, "Import “Fix flaky test” into Temple?")
        XCTAssertEqual(one.message, "It will appear in the sidebar under raven. Nothing runs until you open it, and the session file on disk is not changed.")
        XCTAssertEqual(one.confirmLabel, "Import")

        let several = HistoryModel.importRequest(for: [
            session("a", project: "/x/raven", hoursAgo: 1), session("b", project: "/x/raven", hoursAgo: 2),
            session("c", project: "/x/dotfiles", hoursAgo: 3), session("d", project: "/x/mentes-ai", hoursAgo: 4),
        ])
        XCTAssertEqual(several.title, "Import 4 sessions into Temple?")
        XCTAssertEqual(several.message, "They will appear in the sidebar under raven, dotfiles and mentes-ai. Nothing runs until you open one, and the session files on disk are not changed.")
        XCTAssertEqual(several.confirmLabel, "Import 4")

        XCTAssertEqual(HistoryModel.projectList(["a", "b"]), "a and b")
        XCTAssertEqual(HistoryModel.projectList(["a", "b", "c", "d", "e"]), "a, b and 3 more projects")
    }

    func testBulkImportSkipsTempleRowsJoinsTheRestAsImportedAndClearsSelection() async throws {
        let rows = [session("in", hoursAgo: 1), session("o1", hoursAgo: 2), session("o2", project: "/p/b", hoursAgo: 3)]
        let h = harness(rows, members: ["in"])
        await load(h.history)
        h.history.selectAll()
        XCTAssertEqual(ids(h.history.selectedOutsideRows), ["o1", "o2"])

        h.history.requestImport()
        let request = try XCTUnwrap(h.history.pendingImport)
        XCTAssertEqual(ids(request.sessions), ["o1", "o2"], "already-in-Temple rows are not imported again")
        XCTAssertEqual(request.confirmLabel, "Import 2")

        h.history.confirmImport(request, undoManager: nil)

        XCTAssertNil(h.history.pendingImport)
        XCTAssertEqual(try h.database.sessionState("o1")?.joinedVia, .imported)
        XCTAssertEqual(try h.database.sessionState("o2")?.transcriptPath, "/tmp/o2.jsonl")
        XCTAssertEqual(try h.database.sessionState("in")?.joinedVia, .opened, "an existing row keeps its join")
        XCTAssertTrue(h.overlay.isTempleSession("o1"))
        XCTAssertTrue(h.history.selection.isEmpty)
        XCTAssertEqual(h.history.justImported, ["o1", "o2"])
        XCTAssertEqual(h.history.notice?.text, "2 sessions imported")
        XCTAssertEqual(h.history.inTempleCount, 3)
    }

    func testNothingToImportAsksNothing() async {
        let h = harness([session("in", hoursAgo: 1)], members: ["in"])
        await load(h.history)
        h.history.selectAll()
        h.history.requestImport()
        XCTAssertNil(h.history.pendingImport)
    }

    func testAFailedImportIsReportedAndTheRestStayJoined() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-history-ro-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("temple.sqlite")
        _ = try TempleDB(path: path)
        let readOnly = try TempleDB(readOnlyPath: path)
        let overlay = SessionOverlayStore(db: readOnly)
        let rows = [session("a", title: "First", hoursAgo: 1), session("b", title: "Second", hoursAgo: 2)]
        let history = HistoryModel(overlay: overlay,
                                   catalog: { Self.stream([.sessions(rows, read: 2, total: 2)]) },
                                   pathExists: { _ in true }, now: { [now] in now })
        await load(history)

        history.confirmImport(HistoryModel.importRequest(for: rows), undoManager: nil)

        let failure = try XCTUnwrap(history.importFailure)
        XCTAssertEqual(failure.title, "Couldn't import 2 of 2 sessions")
        XCTAssertTrue(failure.message.contains("First · Second"))
        XCTAssertFalse(overlay.isTempleSession("a"))
    }

    // MARK: Undo

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    func testUndoRemovesExactlyTheUntouchedImportsAndRedoBringsThemBack() async throws {
        let rows = [session("keep-named", hoursAgo: 1), session("plain", hoursAgo: 2),
                    session("in-tab", hoursAgo: 3), session("was-in", hoursAgo: 4)]
        let h = harness(rows, members: ["was-in"])
        var shrunk = 0
        h.history.onMembershipShrunk = { shrunk += 1 }
        h.history.hasOpenTab = { $0 == "in-tab" }
        await load(h.history)
        let manager = undoManager()

        manager.beginUndoGrouping()
        h.history.confirmImport(HistoryModel.importRequest(for: rows), undoManager: manager)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoActionName, "Import")
        // Something is decided about one of them before the undo.
        h.overlay.rename("keep-named", to: "Mine now")

        manager.undo()

        XCTAssertNil(try h.database.sessionState("plain"), "an untouched import leaves")
        XCTAssertFalse(h.overlay.isTempleSession("plain"))
        XCTAssertNotNil(try h.database.sessionState("keep-named"), "a renamed row is kept")
        XCTAssertNotNil(try h.database.sessionState("in-tab"), "a row running in a tab is kept")
        XCTAssertEqual(try h.database.sessionState("was-in")?.joinedVia, .opened, "never imported, never undone")
        XCTAssertEqual(shrunk, 1, "the engine re-reads membership once")
        XCTAssertEqual(h.history.notice?.text, "1 of 3 imports undone · 2 changed since, kept")

        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(try h.database.sessionState("plain")?.joinedVia, .imported)
        XCTAssertTrue(h.overlay.isTempleSession("plain"))
    }

    // MARK: Tab lifecycle

    func testClosingTheTabResetsItsViewState() async {
        let h = harness([session("a", hoursAgo: 1)])
        await load(h.history)
        h.history.scope = .notInTemple
        h.history.query = "x"

        h.history.reset()

        XCTAssertEqual(h.history.scope, .all)
        XCTAssertEqual(h.history.query, "")
        XCTAssertTrue(h.history.allRows.isEmpty)
        XCTAssertNil(h.history.lastUpdated)
        XCTAssertEqual(h.history.readState, .idle)
    }
}

/// ⌘Y, the tab, and the ⌘K bridge, through the real AppModel.
@MainActor
final class HistoryTabTests: XCTestCase {
    private func makeModel() -> AppModel {
        let database = try! TempleDB.inMemory()
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            indexSource: FakeIndexSource(SessionIndex(projects: [])),
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: SessionOverlayStore(db: database))
        model.history.catalog = { AsyncStream { $0.finish() } }
        return model
    }

    func testCommandYOpensFocusesAndThenGoesBackLeavingHistoryOpen() {
        let model = makeModel()
        model.openSessions.openSession(Fixture.session("a", project: "/p/a"))
        let sessionTab = model.openSessions.activeTabID

        model.toggleHistory()
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.openSessions.tabs.filter { $0.kind == .history }.count, 1)
        XCTAssertEqual(model.openSessions.activeProjectPath, "/p/a", "History is project-agnostic")
        XCTAssertTrue(model.openSessions.visibleTabs.contains { $0.kind == .history })

        model.toggleHistory()
        XCTAssertEqual(model.openSessions.activeTabID, sessionTab, "⌘Y on History goes back")
        XCTAssertNotNil(model.openSessions.historyTab, "…and leaves it open")

        model.toggleHistory()
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.openSessions.tabs.filter { $0.kind == .history }.count, 1, "a singleton")
    }

    func testCommandYOnHistoryWithNothingBehindItGoesHome() {
        let model = makeModel()
        model.toggleHistory()
        model.toggleHistory()
        XCTAssertNil(model.openSessions.activeTabID)
        XCTAssertNotNil(model.openSessions.historyTab)
    }

    func testCommandYPutsAFloatingPanelAway() {
        let model = makeModel()
        model.commandPalettePresented = true
        model.toggleHistory()
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive)
    }

    func testPaletteBridgeOpensHistoryWithTheQuery() {
        let model = makeModel()
        model.commandPalettePresented = true

        model.searchHistory("  fsevents ")

        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.history.query, "fsevents")
    }

    func testFindOnHistoryFocusesItsSearch() {
        let model = makeModel()
        model.toggleHistory()
        let before = model.history.focusSearchRequest
        model.findInActiveTerminal()
        XCTAssertEqual(model.history.focusSearchRequest, before + 1)
    }

    func testClosingTheTabResetsTheModel() async {
        let model = makeModel()
        model.toggleHistory()
        model.history.scope = .inTemple
        model.openSessions.closeActiveTab()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(model.openSessions.historyTab)
        XCTAssertEqual(model.history.scope, .all)
    }

    func testUtilityChipsKeepTheirDraggedPlaces() {
        let model = makeModel()
        model.openSessions.openSession(Fixture.session("a", project: "/p/a"))
        model.openSessions.openSession(Fixture.session("b", project: "/p/a"))
        model.openSessions.openSettings()
        model.toggleHistory()
        XCTAssertEqual(model.openSessions.visibleTabs.map(\.kind), [.session, .session, .settings, .history])

        // Drag History to the front.
        model.openSessions.moveTab(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(model.openSessions.visibleTabs.map(\.kind), [.history, .session, .session, .settings])
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
