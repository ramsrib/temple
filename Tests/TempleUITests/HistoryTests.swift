import XCTest
import AppKit
import Combine
@testable import TempleUI
import TempleCore
@testable import TempleLocalHost

/// The History tab's model: a snapshot of the whole disk joined with Temple's
/// membership, the page's search and filters over it, native-style
/// selection, and import with its undo.
/// The tests below each use one host and one agent per id, so a session id
/// names its row.
@MainActor
private extension HistoryModel {
    var selectedIDs: Set<String> { Set(selection.map(\.sessionID)) }
    var cursorSessionID: String? { cursorID?.sessionID }
    var justImportedIDs: Set<String> { Set(justImported.map(\.sessionID)) }
    func row(_ id: String) -> HistoryRow { allRows.first { $0.sessionID == id }! }
    func click(_ id: String, modifier: ClickModifier = .none) { click(row(id).id, modifier: modifier) }
    func isInTemple(_ id: String) -> Bool { isInTemple(row(id)) }
}

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
                         preview: String? = nil) -> TranscriptSummary {
        catalogFixture(id: id, agent: agent, projectPath: project, title: title ?? "Title \(id)",
                     createdAt: nil, updatedAt: now.addingTimeInterval(-hoursAgo * 3600),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
                     lastMessagePreview: preview, gitBranch: branch)
    }

    private static func stream(_ events: [CatalogBatch]) -> AsyncStream<HostCatalogEvent> {
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
    private func harness(_ rows: [TranscriptSummary], members: [String] = [],
                         missing: Set<String> = []) -> Harness {
        let database = try! TempleDB.inMemory()
        for id in members {
            if let disk = rows.first(where: { $0.id == id }) {
                let row = Fixture.row(id, agent: disk.agent, project: disk.projectPath,
                    title: disk.title, updated: disk.updatedAt.timeIntervalSince1970)
                try! database.join(sessionID: id, via: .opened, agent: row.agent,
                    core: SessionCore(directory: row.directory, directorySource: .tab, title: row.state.title, lastActiveAt: row.sortDate))
            } else { try! database.join(sessionID: id, via: .opened) }
        }
        let overlay = SessionOverlayStore(db: database)
        let history = HistoryModel(
            overlay: overlay,
            catalog: { Self.stream([.listed(total: rows.count),
                                    .sessions(rows, read: rows.count, total: rows.count)]) },
            pathExists: { !missing.contains($0) },
            now: { [now] in now })
        var opened: [String] = []
        history.openSession = { opened.append($0.id) }
        history.openMember = { opened.append($0.id) }
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

    private func ids(_ rows: [TranscriptSummary]) -> [String] { rows.map(\.id) }
    private func ids(_ rows: [HistoryRow]) -> [String] { rows.map(\.sessionID) }

    /// The catalog row's facts are committed at join; the engine verifies
    /// the member afterwards like any other. There is no second parse that
    /// serialized behind member resolution and dropped the row's facts when
    /// it came back empty.
    func testImportCommitsTheCatalogRowsFactsWithoutReparsing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let row = catalogFixture(id: "catalog-facts", agent: .codex, projectPath: "/recorded",
            title: "Recorded prompt", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 100), filePath: missing)
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)
        XCTAssertEqual(overlay.import([row]).map(\.label), ["joined"])
        let state = try XCTUnwrap(db.sessionState(row.id))
        XCTAssertEqual(state.directory, "/recorded")
        XCTAssertEqual(state.directorySource, .transcript)
        XCTAssertEqual(state.title, "Recorded prompt")
        XCTAssertEqual(state.lastActiveAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(state.transcriptPath, missing.path)
        XCTAssertEqual(state.joinedVia, .imported)
    }

    func testCodexHistoryPromptFillsBothImportPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("sessions/rollout-history-only.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"type":"session_meta","payload":{"id":"history-only","cwd":"/recorded"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        try #"{"session_id":"history-only","ts":10,"text":"A recorded human prompt"}"#
            .write(to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        let store = CodexSessionStore(root: root)
        let legacy = try XCTUnwrap(store.loadSummary(at: file))
        let summary = try XCTUnwrap(store.loadSummaries().first)
        XCTAssertNil(summary.firstPrompt)
        XCTAssertEqual(summary.historyPrompt, "A recorded human prompt")
        for imported in [summary, legacy] {
            let db = try TempleDB.inMemory()
            let overlay = SessionOverlayStore(db: db)
            XCTAssertEqual(overlay.import([imported]).map(\.label), ["joined"])
            let row = try XCTUnwrap(db.sessionState(summary.id))
            XCTAssertEqual(row.title, "A recorded human prompt")
            XCTAssertEqual(row.directory, "/recorded")
            XCTAssertNil(row.generatedTitle, "A prompt fill is not an OSC title override")
            XCTAssertEqual(overlay.displayTitle(for: legacy), legacy.title)
        }
    }

    func testImportCopiesTitleDirectoryAndTimeOnce() throws {
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)
        let date = Date(timeIntervalSince1970: 100)
        let summary = TranscriptSummary(id: "a", agent: .claude,
            locator: TranscriptLocator(host: .local, path: "/tmp/a.jsonl"),
            modifiedAt: date, cwd: "/cwd", firstPrompt: "First prompt", recordedTitle: "Different title")
        XCTAssertEqual(overlay.import([summary]).map(\.label), ["joined"])
        let row = try XCTUnwrap(db.sessionState("a"))
        XCTAssertEqual(row.title, "Different title", "Claude's recorded summary is a title fact")
        XCTAssertNil(row.generatedTitle)
        XCTAssertEqual(row.directory, "/cwd")
        XCTAssertEqual(row.directorySource, .transcript)
        XCTAssertEqual(row.lastActiveAt, date)
        XCTAssertEqual(row.agent, .claude)
        XCTAssertEqual(row.transcriptPath, "/tmp/a.jsonl")
        let changed = TranscriptSummary(id: "a", agent: .claude,
            locator: summary.locator, modifiedAt: date.addingTimeInterval(100),
            cwd: "/changed", firstPrompt: "Changed")
        XCTAssertEqual(overlay.import([changed]).map(\.label), ["skipped"], "already Temple's: left as it is")
        XCTAssertEqual(try db.sessionState("a"), row)
        XCTAssertEqual(overlay.leave([SessionKey(id: "a", host: .local)]), ["a"], "fact fills remain undoable")
    }

    func testImportNeverPersistsPlaceholders() throws {
        let db = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: db)
        for agent in Agent.allCases {
            let summary = TranscriptSummary(id: agent.rawValue, agent: agent,
                locator: TranscriptLocator(host: .local, path: "/tmp/absent.jsonl"),
                modifiedAt: Date(timeIntervalSince1970: 100), directoryHint: "/lossy",
                laterPromptHint: "Later prompt", legacyTitleHint: "Legacy")
            XCTAssertEqual(overlay.import([summary]).map(\.label), ["joined"])
            let row = try XCTUnwrap(db.sessionState(summary.id))
            XCTAssertNil(row.title)
            XCTAssertNil(row.directory)
            XCTAssertNil(row.directorySource)
        }
    }

    func testHistoryImportAdapterUsesParserFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("history-facts.jsonl")
        try """
        {"type":"user","sessionId":"history-facts","cwd":"/fact-cwd","message":{"content":"First fact"}}
        {"type":"summary","summary":"Display summary"}
        """.write(to: file, atomically: true, encoding: .utf8)
        let store = ClaudeSessionStore(root: root)
        let summary = try XCTUnwrap(store.loadSummary(at: file))
        let legacy = try XCTUnwrap(store.loadSummary(at: file))
        XCTAssertEqual(legacy.title, "Display summary")
        let h = harness([legacy])
        await load(h.history)
        h.history.selectAll()
        h.history.requestImport()
        await h.history.confirmImport(undoManager: nil)
        let row = try XCTUnwrap(h.database.sessionState(summary.id))
        XCTAssertEqual(row.title, "Display summary", "the row takes the title History showed")
        XCTAssertEqual(row.directory, summary.cwd)
        XCTAssertEqual(try XCTUnwrap(row.lastActiveAt).timeIntervalSince1970,
                       summary.modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

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

    /// A pre-v8 row made by a setter has no joined_at, and with no open and
    /// no transcript to fill last_active_at it has no date at all. It sorts
    /// last and is grouped as undated, never "Jan 1, 0001".
    func testRowsWithNoDateAtAllGroupUnderUnknownDate() {
        func undated(_ id: String) -> HistoryRow {
            HistoryRow(member: Session(state: SessionState(id: id, pinned: false, archived: false, customName: nil,
                color: nil, generatedTitle: nil, lastOpenedAt: nil, joinedVia: nil, joinedAt: nil,
                agent: .claude, host: .local, directory: nil, directorySource: nil, title: "Legacy \(id)",
                lastActiveAt: nil), resolution: .confirmedAbsent))
        }
        let rows = [HistoryRow(catalog: session("dated", hoursAgo: 1)), undated("a"), undated("b")]
        XCTAssertEqual(rows[1].updatedAt, .distantPast)

        let groups = HistoryRowGrouping.groups(rows, calendar: calendar, now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Unknown date"])
        XCTAssertEqual(groups[1].sessions.map(\.sessionID), ["a", "b"])
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

    func testTempleRowsUseRowTitleAndCatalogTime() async {
        let disk = session("mine", title: "First prompt", hoursAgo: 5)
        let h = harness([disk], members: ["mine"])
        h.overlay.recordGeneratedTitle("Fresher title", for: "mine")
        h.overlay.flushPendingTitles()

        await load(h.history)

        XCTAssertEqual(h.history.allRows.map(\.title), ["Fresher title"])
        XCTAssertEqual(h.history.allRows.first?.updatedAt, disk.updatedAt)
    }

    /// The header counts the union the page lists. A member whose transcript
    /// the engine proved gone is one of those rows, but not a file on disk:
    /// the line names it instead of calling every row "on disk".
    func testHeaderCountsTheListedRowsAndNamesTheOnesWithoutATranscript() async {
        let rows = [session("on-disk", hoursAgo: 1), session("outside", hoursAgo: 2)]
        let h = harness(rows, members: ["on-disk", "pruned", "still-resolving"])
        let states = h.overlay.rows
        var resolutions: [String: MemberResolution] = [
            "on-disk": .loaded(URL(fileURLWithPath: "/tmp/on-disk.jsonl")),
            "pruned": .confirmedAbsent, "still-resolving": .resolving]
        h.history.memberRows = { states.values.map { Session(state: $0, resolution: resolutions[$0.id]) } }
        await load(h.history)

        XCTAssertEqual(h.history.allRows.count, 4)
        XCTAssertEqual(h.history.transcriptMissingCount, 1, "only a proven absence; resolving is not missing")
        XCTAssertEqual(h.history.countsLine, "4 sessions · 3 in Temple · 1 without a transcript")

        resolutions["pruned"] = .resolving
        h.history.rowsChanged()
        await waitFor { h.history.transcriptMissingCount == 0 }
        XCTAssertEqual(h.history.countsLine, "4 sessions · 3 in Temple", "no gap, no clause")
    }

    func testArchivedTempleRowsAreShownTaggedUnderInTemple() async {
        let rows = [session("put-away", hoursAgo: 1), session("project-away", project: "/p/b", hoursAgo: 2),
                    session("outside", hoursAgo: 3)]
        let h = harness(rows, members: ["put-away", "project-away"])
        h.overlay.setArchived(true, sessionID: "put-away")
        h.overlay.setProjectArchived(true, key: Fixture.key("/p/b"))

        await load(h.history)
        h.history.scope = .inTemple

        XCTAssertEqual(ids(h.history.visibleRows), ["put-away", "project-away"])
        XCTAssertTrue(h.history.isArchived(h.history.allRows[0]))
        XCTAssertTrue(h.history.isArchived(h.history.allRows[1]))
        XCTAssertFalse(h.history.isArchived(h.history.allRows[2]), "an outside row is never 'archived'")
    }

    func testStreamingShowsRowsBeforeTheReadEndsAndRecordsStoreFailures() async {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        var continuation: AsyncStream<HostCatalogEvent>.Continuation!
        let stream = AsyncStream<HostCatalogEvent> { continuation = $0 }
        let history = HistoryModel(overlay: overlay, catalog: { stream },
                                   pathExists: { _ in true }, now: { [now] in now })

        history.activate()
        XCTAssertEqual(history.readState, .reading(read: 0, total: nil))
        continuation.yield(.listed(total: 3))
        continuation.yield(.storeFailed(agent: .codex, message: "permission denied"))
        continuation.yield(.sessions([session("a", hoursAgo: 1)], read: 1, total: 3))
        await waitFor { history.allRows.count == 1 }
        XCTAssertEqual(history.readState, .reading(read: 1, total: 3))
        XCTAssertEqual(history.storeFailures, [.init(host: .local, agent: .codex, message: "permission denied")])
        XCTAssertEqual(history.selectedIDs, ["a"], "the first row is selected as soon as there is one")

        // A later batch can hold rows NEWER than the selected one (stores are
        // read one after another): they land above it, and the selection stays.
        continuation.yield(.sessions([session("newer", hoursAgo: 0.5), session("b", hoursAgo: 2)],
                                     read: 3, total: 3))
        continuation.finish()
        await waitFor { history.readState == .done }
        XCTAssertEqual(ids(history.allRows), ["newer", "a", "b"])
        XCTAssertEqual(history.selectedIDs, ["a"], "later batches never move the selection")
        XCTAssertEqual(history.cursorSessionID, "a")
    }

    /// The noise check stats a project directory per read: off the main
    /// actor, and once per project however many sessions it holds.
    func testTheNoiseCheckRunsOffTheMainThreadOncePerProject() async {
        let probe = PathProbe()
        let rows = [session("a", hoursAgo: 1), session("b", hoursAgo: 2),
                    session("c", project: "/gone", hoursAgo: 3)]
        let database = try! TempleDB.inMemory()
        let history = HistoryModel(
            overlay: SessionOverlayStore(db: database),
            catalog: { Self.stream([.sessions(Array(rows.prefix(2)), read: 2, total: 3),
                                    .sessions([rows[2]], read: 3, total: 3)]) },
            pathExists: { path in probe.record(path); return path != "/gone" },
            now: { [now] in now })

        await load(history)

        XCTAssertEqual(ids(history.allRows), ["a", "b"])
        XCTAssertEqual(probe.paths, ["/p/a", "/gone"])
        XCTAssertFalse(probe.sawMainThread, "no stat on the main thread")
    }

    /// The tab leaving the screen cancels its read; a later refresh replaces
    /// the snapshot whole, dropping sessions gone from disk.
    func testDeactivateCancelsAndARefreshPrunesVanishedRows() async {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        var reads: [[TranscriptSummary]] = [[session("a", hoursAgo: 1), session("gone", hoursAgo: 2)],
                                       [session("a", hoursAgo: 1)]]
        var pending: AsyncStream<HostCatalogEvent>.Continuation?
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
        XCTAssertEqual(h.history.groups[0].sessions.map(\.sessionID), ["t1", "t2", "t3"])
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
        h.history.projectKeyFilter = Fixture.key("/p/a")
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
        XCTAssertEqual(h.history.selectedIDs, ["a", "b", "c"])

        h.history.projectKeyFilter = Fixture.key("/p/b")
        XCTAssertEqual(h.history.selectedIDs, ["c"])

        h.history.projectKeyFilter = nil
        h.history.click("b")
        h.history.click("c", modifier: .command)
        h.history.query = "Title"
        XCTAssertEqual(h.history.selectedIDs, ["a"])
    }

    // MARK: Selection

    func testClickCommandClickShiftClickAndArrowExtension() async {
        let rows = (0..<6).map { session("r\($0)", hoursAgo: Double($0) + 1) }
        let h = harness(rows)
        await load(h.history)

        h.history.click("r1")
        XCTAssertEqual(h.history.selectedIDs, ["r1"])
        h.history.click("r3", modifier: .command)
        XCTAssertEqual(h.history.selectedIDs, ["r1", "r3"])
        h.history.click("r3", modifier: .command)
        XCTAssertEqual(h.history.selectedIDs, ["r1"])
        h.history.click("r1")
        h.history.click("r4", modifier: .shift)
        XCTAssertEqual(h.history.selectedIDs, ["r1", "r2", "r3", "r4"])

        h.history.click("r2")
        h.history.moveCursor(by: 1, extend: true)
        h.history.moveCursor(by: 1, extend: true)
        XCTAssertEqual(h.history.selectedIDs, ["r2", "r3", "r4"])
        h.history.moveCursor(by: 1)
        XCTAssertEqual(h.history.selectedIDs, ["r5"])
        h.history.moveCursor(by: 5)
        XCTAssertEqual(h.history.cursorSessionID, "r5", "the cursor stops at the end")
        h.history.moveCursorToEnd(top: true)
        XCTAssertEqual(h.history.selectedIDs, ["r0"])
    }

    func testOptionArrowsJumpByDay() async {
        let rows = [session("t1", hoursAgo: 1), session("t2", hoursAgo: 2),
                    session("y1", hoursAgo: 30), session("y2", hoursAgo: 31),
                    session("o1", hoursAgo: 80)]
        let h = harness(rows)
        await load(h.history)
        h.history.click("t2")

        h.history.moveCursorByDay(forward: true)
        XCTAssertEqual(h.history.cursorSessionID, "y1")
        h.history.moveCursorByDay(forward: true)
        XCTAssertEqual(h.history.cursorSessionID, "o1")
        h.history.click("y2")
        h.history.moveCursorByDay(forward: false)
        XCTAssertEqual(h.history.cursorSessionID, "y1", "up first lands on the day's own first row")
        h.history.moveCursorByDay(forward: false)
        XCTAssertEqual(h.history.cursorSessionID, "t1")
    }

    func testSelectAllTakesOnlyTheCurrentView() async {
        let rows = [session("a", hoursAgo: 1), session("b", project: "/p/b", hoursAgo: 2),
                    session("c", project: "/p/b", hoursAgo: 3)]
        let h = harness(rows)
        await load(h.history)
        h.history.showOnly(project: Fixture.key("/p/b"))

        h.history.selectAll()

        XCTAssertEqual(h.history.selectedIDs, ["b", "c"])
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

    /// The field debounces into the query; Esc and Return act on what is
    /// typed, not on what the list caught up to.
    func testEscapeAndReturnFlushTheSearchDebounce() async {
        let rows = [session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)]
        let h = harness(rows)
        h.history.queryDebounce = 10   // never fires on its own in this test
        await load(h.history)
        XCTAssertEqual(h.history.selectedIDs, ["a"])

        h.history.draft = "Bet"
        XCTAssertEqual(h.history.query, "", "still debouncing")
        XCTAssertEqual(h.history.escape(), .clearedSearch, "Esc within the debounce clears the search…")
        XCTAssertEqual(h.history.draft, "")
        XCTAssertEqual(h.history.query, "")
        XCTAssertEqual(h.history.selectedIDs, ["a"], "…and does not clear the selection")

        h.history.draft = "Bet"
        h.history.openSelected()
        XCTAssertEqual(h.opened(), ["b"], "Return opens the first match of what was typed")
    }

    func testTheDebounceAppliesTheDraftOnItsOwn() async {
        let h = harness([session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)])
        h.history.queryDebounce = 0.01
        await load(h.history)

        h.history.draft = "Beta"
        await waitFor { h.history.query == "Beta" }
        XCTAssertEqual(ids(h.history.visibleRows), ["b"])

        // Setting the query from outside (the ⌘K bridge) brings the field along.
        h.history.query = "Alpha"
        XCTAssertEqual(h.history.draft, "Alpha")
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

    /// An archived project lists its sessions in the archive, so the copy
    /// must not promise a sidebar row.
    func testImportCopyForAnArchivedProjectSaysTheArchive() {
        let archived: (ProjectKey) -> Bool = { $0 == Fixture.key("/x/raven") }
        let one = HistoryModel.importRequest(
            for: [session("a", project: "/x/raven", title: "Fix flaky test", hoursAgo: 1)],
            isProjectArchived: archived)
        XCTAssertEqual(one.message, "It will appear in the archive under raven, which is archived. Nothing runs until you open it, and the session file on disk is not changed.")

        let mixed = HistoryModel.importRequest(
            for: [session("a", project: "/x/raven", hoursAgo: 1), session("b", project: "/x/raven", hoursAgo: 2),
                  session("c", project: "/x/dotfiles", hoursAgo: 3)],
            isProjectArchived: archived)
        XCTAssertEqual(mixed.message, "They will appear in the sidebar under dotfiles, and in the archive under raven, which is archived. Nothing runs until you open one, and the session files on disk are not changed.")
    }

    /// The sheet names a session the way its row does: custom name, then the
    /// agent's own title, then the parsed one.
    func testImportCopyUsesTheDisplayedTitle() async throws {
        let rows = [session("a", project: "/p/raven", title: "first prompt", hoursAgo: 1)]
        let h = harness(rows)
        // An outside session has no row, so nothing Temple holds retitles it:
        // a stray retitle is not kept, and the row shows the parsed title.
        h.overlay.recordGeneratedTitle("Agent's title", for: "a")
        h.overlay.flushPendingTitles()
        h.overlay.setProjectArchived(true, key: Fixture.key("/p/raven"))
        await load(h.history)

        h.history.requestImport(rows)

        let request = try XCTUnwrap(h.history.pendingImport)
        XCTAssertEqual(h.history.allRows.map(\.title), ["first prompt"])
        XCTAssertEqual(request.title, "Import “first prompt” into Temple?")
        XCTAssertTrue(request.message.hasPrefix("It will appear in the archive under raven"))
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

        await h.history.confirmImport(request, undoManager: nil)

        XCTAssertNil(h.history.pendingImport)
        XCTAssertEqual(try h.database.sessionState("o1")?.joinedVia, .imported)
        XCTAssertEqual(try h.database.sessionState("o2")?.transcriptPath, "/tmp/o2.jsonl")
        XCTAssertEqual(try h.database.sessionState("in")?.joinedVia, .opened, "an existing row keeps its join")
        XCTAssertTrue(h.overlay.isTempleSession("o1"))
        XCTAssertTrue(h.history.selection.isEmpty)
        XCTAssertEqual(h.history.justImportedIDs, ["o1", "o2"])
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

        // A retitle for a session with no row is not kept anywhere: the
        // title is the row's, and an outside session has none.
        overlay.recordGeneratedTitle("Renamed by the agent", for: "b")
        overlay.flushPendingTitles()
        await history.confirmImport(HistoryModel.importRequest(for: rows), undoManager: nil)

        let failure = try XCTUnwrap(history.importFailure)
        XCTAssertEqual(failure.title, "Couldn't import 2 sessions")
        XCTAssertEqual(history.allRows.map(\.title), ["First", "Second"])
        XCTAssertTrue(failure.message.contains("First · Second"), "display titles, as the rows show")
        XCTAssertFalse(overlay.isTempleSession("a"))
    }

    func testImportFailureTitleNamesTheOneSessionAndCountsAWholeBatch() {
        XCTAssertEqual(HistoryModel.importFailureTitle(failed: 1, attempted: 1, onlyTitle: "Fix auth"),
                       "Couldn't import “Fix auth”")
        XCTAssertEqual(HistoryModel.importFailureTitle(failed: 3, attempted: 3, onlyTitle: "Fix auth"),
                       "Couldn't import 3 sessions")
        XCTAssertEqual(HistoryModel.importFailureTitle(failed: 1, attempted: 4, onlyTitle: "Fix auth"),
                       "Couldn't import 1 of 4 sessions")
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
        h.history.hasOpenTab = { $0.sessionID == "in-tab" }
        await load(h.history)
        let manager = undoManager()

        manager.beginUndoGrouping()
        await h.history.confirmImport(HistoryModel.importRequest(for: rows), undoManager: manager)
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
        XCTAssertEqual(h.history.notice?.text, "1 of 3 imports undone · 1 open in a tab, 1 changed since, kept",
                       "each kept row for its own reason")

        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(try h.database.sessionState("plain")?.joinedVia, .imported)
        XCTAssertTrue(h.overlay.isTempleSession("plain"))
    }

    func testUndoNoticeGivesEachReason() {
        XCTAssertEqual(HistoryModel.undoNotice(total: 1, left: 1, open: 0, changed: 0), "Import undone")
        XCTAssertEqual(HistoryModel.undoNotice(total: 4, left: 4, open: 0, changed: 0), "4 imports undone")
        XCTAssertEqual(HistoryModel.undoNotice(total: 1, left: 0, open: 1, changed: 0), "Import not undone · open in a tab")
        XCTAssertEqual(HistoryModel.undoNotice(total: 1, left: 0, open: 0, changed: 1), "Import not undone · changed since")
        XCTAssertEqual(HistoryModel.undoNotice(total: 3, left: 1, open: 2, changed: 0), "1 of 3 imports undone · 2 open in a tab, kept")
        XCTAssertEqual(HistoryModel.undoNotice(total: 2, left: 0, open: 1, changed: 1), "No imports undone · 1 open in a tab, 1 changed since, kept")
    }

    // MARK: Bottom bar

    /// Importing everything "Not in Temple" shows empties the view the import
    /// was made from; the notice and its Undo must outlive the rows.
    func testTheImportNoticeOutlivesAViewTheImportEmptied() async {
        let rows = [session("o1", hoursAgo: 1), session("o2", hoursAgo: 2)]
        let h = harness(rows)
        await load(h.history)
        h.history.scope = .notInTemple
        h.history.selectAll()
        XCTAssertEqual(h.history.bottomBar, .selection(count: 2))
        let manager = undoManager()

        manager.beginUndoGrouping()
        await h.history.confirmImport(h.history.makeImportRequest(for: rows), undoManager: manager)
        manager.endUndoGrouping()

        XCTAssertTrue(h.history.visibleRows.isEmpty, "everything left the Not in Temple view")
        XCTAssertEqual(h.history.bottomBar, .notice(.init(text: "2 sessions imported", offersUndo: true)))
    }

    // MARK: Rebuild cost

    /// Off screen, membership and live-index changes only mark the page
    /// dirty; it catches up when it is shown again.
    func testAnInactivePageDefersItsRebuildToActivation() async {
        let rows = [session("a", title: "Disk title", hoursAgo: 1)]
        let h = harness(rows)
        await load(h.history)
        h.history.deactivate()

        _ = h.overlay.join("a", via: .opened)
        h.overlay.recordGeneratedTitle("Live title", for: "a")
        h.overlay.flushPendingTitles()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(h.history.inTempleCount, 0, "nothing rebuilt off screen")
        XCTAssertEqual(h.history.allRows.map(\.title), ["Disk title"])

        h.history.activate()
        XCTAssertEqual(h.history.inTempleCount, 1, "caught up on activation, before the read")
        XCTAssertEqual(h.history.allRows.map(\.title), ["Live title"])
    }

    /// A rebuild that changes nothing publishes nothing: an unrelated overlay
    /// write must not re-render the page.
    func testARebuildThatChangesNothingPublishesNothing() async {
        let h = harness([session("a", hoursAgo: 1), session("b", hoursAgo: 2)])
        await load(h.history)
        var published = 0
        let subscription = h.history.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        h.history.rebuild()
        h.history.rebuild()

        XCTAssertEqual(published, 0)
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
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
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
        XCTAssertEqual(model.openSessions.activeProjectKey?.path, "/p/a", "History is project-agnostic")
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

    /// ⌘Y over ⌘K or the archive, with History under it: the panel goes and
    /// History stays — it does not also jump back to the previous tab.
    func testCommandYOverAPanelOnHistoryClosesThePanelAndStays() {
        let model = makeModel()
        model.openSessions.openSession(Fixture.session("a", project: "/p/a"))
        model.toggleHistory()

        model.toggleCommandPalette()
        model.toggleHistory()
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive, "the palette went; History stayed")

        model.toggleArchive()
        model.toggleHistory()
        XCTAssertFalse(model.archivePresented)
        XCTAssertTrue(model.historyActive, "the archive went; History stayed")

        model.toggleHistory()
        XCTAssertFalse(model.historyActive, "with nothing over it, ⌘Y still goes back")
    }

    func testShowInSidebarHighlightsTheRowAndAsksTheRailToScroll() {
        let model = makeModel()
        model.showInSidebar("a")
        XCTAssertEqual(model.highlightedID, "a")
        let first = try? XCTUnwrap(model.sidebarReveal)
        XCTAssertEqual(first?.sessionID, "a")

        model.showInSidebar("a")
        XCTAssertNotEqual(model.sidebarReveal, first, "asking again scrolls again")
    }

    /// Import → open → close the tab (before any title arrives) → Undo: the
    /// session was used, so it stays. The open is recorded in the database,
    /// not inferred from a tab that is no longer there.
    func testUndoKeepsAnImportThatWasOpenedSinceEvenOnceItsTabIsClosed() async throws {
        let database = try TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay)
        let row = catalogFixture(id: "imp", agent: .claude, projectPath: NSTemporaryDirectory(),
                               title: "Imported", createdAt: nil, updatedAt: Date(),
                               filePath: URL(fileURLWithPath: "/tmp/imp.jsonl"))
        model.history.catalog = { AsyncStream { $0.yield(.sessions([row], read: 1, total: 1)); $0.finish() } }
        model.history.activate()
        try await waitFor { model.history.readState == .done }
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        await model.history.confirmImport(model.history.makeImportRequest(for: [row]), undoManager: manager)
        manager.endUndoGrouping()
        model.history.open(row)
        XCTAssertNotNil(model.openSessions.openTab(forSessionID: "imp"))
        XCTAssertNotNil(try database.sessionState("imp")?.lastOpenedAt, "the open is recorded")
        model.openSessions.closeActiveTab()
        try await waitFor { model.openSessions.openTab(forSessionID: "imp") == nil }

        manager.undo()

        XCTAssertTrue(model.overlay.isTempleSession("imp"))
        XCTAssertEqual(try database.sessionState("imp")?.joinedVia, .imported)
        XCTAssertEqual(model.history.notice?.text, "Import not undone · changed since")
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
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

/// Which project paths the noise check stats, and from which thread.
private final class PathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var onMain = false
    func record(_ path: String) {
        lock.lock(); recorded.append(path); if Thread.isMainThread { onMain = true }; lock.unlock()
    }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var sawMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
}

/// Undo Import, end to end through the real engine: the committed leave
/// takes the session out of the live index, with no filesystem event.
@MainActor
final class HistoryUndoEngineTests: XCTestCase {
    func testUndoImportTakesTheSessionOutOfTheLiveIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-history-undo-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("imp.jsonl")
        try #"{"type":"user","sessionId":"imp","cwd":"/tmp/project","message":{"content":"from another terminal"}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let database = try TempleDB.inMemory()
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02), database: database)
        let model = AppModel(surfaceFactory: FakeTerminalSurfaceFactory(), engines: [watcher],
                             database: database, settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
                             overlay: SessionOverlayStore(db: database))
        model.start()
        try await waitFor { !model.isLoading }
        let row = catalogFixture(id: "imp", agent: .claude, projectPath: NSTemporaryDirectory(),
                               title: "from another terminal", createdAt: nil, updatedAt: Date(),
                               filePath: file)
        model.history.catalog = { AsyncStream { $0.yield(.sessions([row], read: 1, total: 1)); $0.finish() } }
        model.history.activate()
        try await waitFor { model.history.readState == .done }
        XCTAssertFalse(model.sessions.contains { $0.id == "imp" })
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        await model.history.confirmImport(model.history.makeImportRequest(for: [row]), undoManager: manager)
        manager.endUndoGrouping()
        try await waitFor { model.sessions.contains { $0.id == "imp" } }

        manager.undo()

        try await waitFor { !model.sessions.contains { $0.id == "imp" } }
        XCTAssertFalse(model.overlay.isTempleSession("imp"))
        XCTAssertNil(try database.sessionState("imp"))
        await watcher.stop()
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }
}

/// History's key map (RootView asks it on every keyDown while the tab is
/// active): what it takes, and what it leaves to another field or a sheet.
final class HistoryKeysTests: XCTestCase {
    private func route(_ keyCode: UInt16, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                       focus: HistoryKeyFocus = .none, sheet: Bool = false,
                       searchSelection: Bool = false) -> HistoryKeyRoute {
        HistoryKeys.route(keyCode: keyCode, characters: characters, modifiers: modifiers,
                          focus: focus, sheetAttached: sheet, searchHasSelection: searchSelection)
    }

    private enum Key {
        static let down: UInt16 = 125, up: UInt16 = 126, ret: UInt16 = 36, enter: UInt16 = 76, esc: UInt16 = 53
        static let a: UInt16 = 0, c: UInt16 = 8, f: UInt16 = 3, i: UInt16 = 34, r: UInt16 = 15
        static let k: UInt16 = 40, w: UInt16 = 13, y: UInt16 = 16
    }

    func testTheListTakesItsKeysWithNoFieldOrHistorysOwnSearchFocused() {
        for focus in [HistoryKeyFocus.none, .historySearch] {
            XCTAssertEqual(route(Key.down, focus: focus), .history(.moveCursor(by: 1, extend: false)))
            XCTAssertEqual(route(Key.up, "", [.shift], focus: focus), .history(.moveCursor(by: -1, extend: true)))
            XCTAssertEqual(route(Key.down, "", [.option], focus: focus), .history(.moveByDay(forward: true, extend: false)))
            XCTAssertEqual(route(Key.up, "", [.command, .shift], focus: focus), .history(.moveToEnd(top: true, extend: true)))
            XCTAssertEqual(route(Key.ret, focus: focus), .history(.open))
            XCTAssertEqual(route(Key.enter, focus: focus), .history(.open))
            XCTAssertEqual(route(Key.esc, focus: focus), .history(.escape))
            XCTAssertEqual(route(Key.a, "a", [.command], focus: focus), .history(.selectAll))
            XCTAssertEqual(route(Key.c, "c", [.command], focus: focus), .history(.copyResumeCommands))
            XCTAssertEqual(route(Key.i, "i", [.command], focus: focus), .history(.importSelection))
            XCTAssertEqual(route(Key.r, "r", [.command], focus: focus), .history(.refresh))
            XCTAssertEqual(route(Key.f, "f", [.command], focus: focus), .history(.focusSearch))
        }
    }

    /// Sidebar search, a chip rename: Return commits the field, Esc ends it,
    /// arrows and ⌘A/⌘C edit it. None of it may open, select or leave.
    func testAnotherFieldKeepsEveryKey() {
        for (keyCode, characters, modifiers) in [
            (Key.down, "", NSEvent.ModifierFlags()), (Key.up, "", [.shift]), (Key.ret, "", []),
            (Key.enter, "", []), (Key.esc, "", []), (Key.a, "a", [.command]), (Key.c, "c", [.command]),
            (Key.i, "i", [.command]), (Key.r, "r", [.command]), (Key.f, "f", [.command]),
        ] {
            XCTAssertEqual(route(keyCode, characters, modifiers, focus: .foreignField), .general,
                           "key \(keyCode) \(modifiers)")
        }
    }

    /// The import sheet and its failure alert: everything goes to the sheet,
    /// including the ⌘ keys that would otherwise close or leave the page.
    func testASheetTakesEverything() {
        for focus in [HistoryKeyFocus.none, .historySearch, .foreignField] {
            XCTAssertEqual(route(Key.ret, focus: focus, sheet: true), .toSheet)
            XCTAssertEqual(route(Key.esc, focus: focus, sheet: true), .toSheet)
            XCTAssertEqual(route(Key.w, "w", [.command], focus: focus, sheet: true), .toSheet)
            XCTAssertEqual(route(Key.y, "y", [.command], focus: focus, sheet: true), .toSheet)
            XCTAssertEqual(route(Key.k, "k", [.command], focus: focus, sheet: true), .toSheet)
        }
    }

    func testTextSelectedInHistorysSearchCopiesAsText() {
        XCTAssertEqual(route(Key.c, "c", [.command], focus: .historySearch, searchSelection: true), .general)
        XCTAssertEqual(route(Key.a, "a", [.command], focus: .historySearch, searchSelection: true), .history(.selectAll))
    }

    func testOtherChordsAreNotHistorys() {
        XCTAssertEqual(route(Key.down, "", [.control]), .general, "⌃ chords belong elsewhere")
        XCTAssertEqual(route(Key.ret, "", [.command]), .general)
        XCTAssertEqual(route(Key.a, "a", [.command, .option]), .general)
        XCTAssertEqual(route(Key.a, "a"), .general, "plain typing")
        XCTAssertEqual(route(Key.w, "w", [.command]), .general, "⌘W closes the tab")
        XCTAssertEqual(route(Key.y, "y", [.command]), .general, "⌘Y goes back")
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}


extension SessionOverlayStore.ImportOutcome {
    /// The outcome's case, for assertions (the error is checked separately).
    var label: String {
        switch self {
        case .joined: "joined"
        case .skipped: "skipped"
        case .failed(let error): "failed: \(error)"
        }
    }
}
