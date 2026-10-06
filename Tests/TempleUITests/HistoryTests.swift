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
        await history.settle()
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

        let groups = HistoryRowGrouping.groups(sessions.map { HistoryRow(catalog: $0) }, calendar: calendar, now: now)

        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map(\.title),
                       ["Today", "Yesterday", "Friday, Jul 10", "Dec 31, 2025"])
        XCTAssertEqual(groups[0].sessions.map(\.sessionID), ["today-newer", "today-older"])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.sessionID), sessions.map(\.id))
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

    /// The header counts the union the page lists, by the three scopes that
    /// partition it. A member whose transcript the engine proved gone is one
    /// of those rows; its condition is its tag's, not the header's.
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
        XCTAssertEqual(h.history.countsLine, "4 sessions · 3 in Temple · 0 archived")

        resolutions["pruned"] = .resolving
        h.history.rowsChanged()
        await waitFor { h.history.transcriptMissingCount == 0 }
        XCTAssertEqual(h.history.countsLine, "4 sessions · 3 in Temple · 0 archived")
    }

    /// Archived is a scope of History (ADR-031): In Temple is what the
    /// sidebar shows, Archived is in Temple and put away, and the three
    /// narrow scopes partition All.
    func testTheNarrowScopesPartitionAllAndArchivedRowsLeaveInTemple() async {
        let rows = [session("put-away", hoursAgo: 1), session("project-away", project: "/p/b", hoursAgo: 2),
                    session("in-play", hoursAgo: 3), session("outside", hoursAgo: 4)]
        let h = harness(rows, members: ["put-away", "project-away", "in-play"])
        h.overlay.setArchived(true, sessionID: "put-away")
        h.overlay.setProjectArchived(true, key: Fixture.key("/p/b"))

        await load(h.history)
        XCTAssertEqual(h.history.countsLine, "4 sessions · 1 in Temple · 2 archived")
        var partition: [String] = []
        for scope in [HistoryScope.inTemple, .archived, .notInTemple] {
            h.history.scope = scope
            await h.history.settle()
            partition += ids(h.history.visibleRows)
            if scope == .inTemple { XCTAssertEqual(ids(h.history.visibleRows), ["in-play"]) }
            if scope == .archived { XCTAssertEqual(ids(h.history.visibleRows), ["put-away", "project-away"]) }
        }
        XCTAssertEqual(Set(partition), Set(ids(h.history.allRows)))
        XCTAssertEqual(partition.count, h.history.allRows.count)

        h.history.scope = .all
        await h.history.settle()
        XCTAssertTrue(h.history.isArchived(h.history.row("put-away")))
        XCTAssertEqual(h.history.row("put-away").standing, .archived(.byUser(at: h.history.row("put-away").member?.state.archivedAt)))
        XCTAssertEqual(h.history.row("project-away").standing, .archived(.withProject(Fixture.key("/p/b"))))
        XCTAssertFalse(h.history.isArchived(h.history.row("outside")), "an outside row is never 'archived'")
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
        await waitFor { history.readState == .reading(read: 1, total: 3) }
        XCTAssertEqual(history.storeFailures, [.init(host: .local, agent: .codex, message: "permission denied")])
        XCTAssertEqual(history.selectedIDs, ["a"], "the first row is selected as soon as there is one")

        // A later batch can hold rows NEWER than the selected one (stores are
        // read one after another): they land above it, and the selection stays.
        continuation.yield(.sessions([session("newer", hoursAgo: 0.5), session("b", hoursAgo: 2)],
                                     read: 3, total: 3))
        continuation.finish()
        await waitFor { history.readState == .done }
        await history.settle()
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
    /// the snapshot whole, dropping sessions gone from disk — where the host
    /// says the agent's listing completed.
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
            pending?.yield(.completed(candidates: [.claude: []]))
            pending?.finish()
            await waitFor { history.readState == .done }
        }
        await history.settle()
        XCTAssertEqual(ids(history.allRows), ["a"])
    }

    /// A row missing from a read proves it gone only within the coverage the
    /// read completed. A read with no completion (a dropped transport, a
    /// store root that is not there), or one that completed only another
    /// agent, keeps the rows it did not see; the same read with the agent's
    /// listing completed drops them.
    func testARowIsDroppedOnlyWithinCompletedCoverage() async {
        let database = try! TempleDB.inMemory()
        let overlay = SessionOverlayStore(db: database)
        var reads: [[CatalogBatch]] = []
        let history = HistoryModel(overlay: overlay, catalog: { Self.stream(reads.removeFirst()) },
                                   pathExists: { _ in true }, now: { [now] in now })
        let a = session("a", hoursAgo: 1), gone = session("gone", hoursAgo: 2), codex = session("x", agent: .codex, hoursAgo: 3)
        func read(_ events: [CatalogBatch]) async {
            reads.append(events)
            history.refresh()
            await waitFor { history.readState == .done }
        }
        await read([.listed(total: 3), .sessions([a, gone, codex], read: 3, total: 3), .completed(candidates: [.claude: [], .codex: []])])
        XCTAssertEqual(ids(history.allRows), ["a", "gone", "x"])
        await read([.listed(total: 1), .sessions([a], read: 1, total: 1)])
        XCTAssertEqual(ids(history.allRows), ["a", "gone", "x"], "no completion: nothing proven gone")
        await read([.listed(total: 1), .storeFailed(agent: .codex, message: "denied"), .sessions([a], read: 1, total: 1),
                    .completed(candidates: [.claude: []])])
        XCTAssertEqual(ids(history.allRows), ["a", "x"], "Claude's listing completed; Codex's failed and keeps its row")
        await read([.listed(total: 1), .sessions([a], read: 1, total: 1), .completed(candidates: [.claude: [], .codex: []])])
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
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["t1", "t2", "t3", "y1", "y2"])
        XCTAssertEqual(h.history.groups.map(\.title), ["Today", "Yesterday"], "day grouping survives search")
        XCTAssertEqual(h.history.groups[0].sessions.map(\.sessionID), ["t1", "t2", "t3"])
        XCTAssertTrue(h.history.isNarrowed)

        h.history.query = "ABC1"
        await h.history.settle()
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
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["c-out", "x-out", "x-out-b", "x-beta"])
        h.history.agentFilter = .codex
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-out-b", "x-beta"])
        h.history.projectKeyFilter = Fixture.key("/p/a")
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-beta"])
        h.history.query = "alpha"
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out"])

        h.history.query = ""
        await h.history.settle()
        XCTAssertEqual(ids(h.history.visibleRows), ["x-out", "x-beta"], "clearing search keeps the filters")
        h.history.scope = .inTemple
        await h.history.settle()
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
        await h.history.settle()
        XCTAssertEqual(h.history.selectedIDs, ["c"])

        h.history.projectKeyFilter = nil
        await h.history.settle()
        h.history.click("b")
        h.history.click("c", modifier: .command)
        h.history.query = "Title"
        await h.history.settle()
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
        await h.history.settle()

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
        await h.history.settle()

        XCTAssertEqual(h.history.escape(), .clearedSearch)
        XCTAssertEqual(h.history.query, "")
        await h.history.settle()
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
        await h.history.settle()
        XCTAssertEqual(h.history.selectedIDs, ["a"], "…and does not clear the selection")

        h.history.draft = "Bet"
        h.history.openSelected()
        await h.history.settle()
        XCTAssertEqual(h.opened(), ["b"], "Return opens the first match of what was typed")
    }

    func testTheDebounceAppliesTheDraftOnItsOwn() async {
        let h = harness([session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)])
        h.history.queryDebounce = 0.01
        await load(h.history)

        h.history.draft = "Beta"
        await waitFor { h.history.query == "Beta" }
        await h.history.settle()
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

    /// An archived project lists its sessions in History under Archived, so
    /// the copy must not promise a sidebar row.
    func testImportCopyForAnArchivedProjectSaysTheArchive() {
        let archived: (ProjectKey) -> Bool = { $0 == Fixture.key("/x/raven") }
        let one = HistoryModel.importRequest(
            for: [session("a", project: "/x/raven", title: "Fix flaky test", hoursAgo: 1)],
            isProjectArchived: archived)
        XCTAssertEqual(one.message, "It will appear in History under Archived, because raven is archived. Nothing runs until you open it, and the session file on disk is not changed.")

        let mixed = HistoryModel.importRequest(
            for: [session("a", project: "/x/raven", hoursAgo: 1), session("b", project: "/x/raven", hoursAgo: 2),
                  session("c", project: "/x/dotfiles", hoursAgo: 3)],
            isProjectArchived: archived)
        XCTAssertEqual(mixed.message, "They will appear in the sidebar under dotfiles, and in History under Archived, because raven is archived. Nothing runs until you open one, and the session files on disk are not changed.")
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
        XCTAssertTrue(request.message.hasPrefix("It will appear in History under Archived, because raven is archived"))
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
        await h.history.settle()
        h.history.selectAll()
        XCTAssertEqual(h.history.bottomBar, .selection(count: 2))
        let manager = undoManager()

        manager.beginUndoGrouping()
        await h.history.confirmImport(h.history.makeImportRequest(for: rows), undoManager: manager)
        manager.endUndoGrouping()

        XCTAssertTrue(h.history.visibleRows.isEmpty, "everything left the Not in Temple view")
        XCTAssertEqual(h.history.bottomBar, .notice(.init(text: "2 sessions imported", offersUndo: true)))
    }

    // MARK: Commands while a projection is in flight

    /// Holds every projection between its return and its install until
    /// released; `held` is set once one is waiting.
    private final class InstallGate {
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        func release() { holding = false; held?.resume(); held = nil }
    }

    private func gate(_ history: HistoryModel) -> InstallGate {
        let gate = InstallGate()
        history.beforeInstall = { [gate] in
            guard gate.holding else { return }
            await withCheckedContinuation { gate.held = $0 }
        }
        return gate
    }

    private func waitHeld(_ gate: InstallGate) async {
        await waitFor { gate.held != nil }
    }

    /// The page's layout follows the pane's width (what the split view
    /// offers, not what the page would like): one toolbar row from 1000 pt,
    /// search on its own row below that, one Filter menu under 692 pt; the
    /// project column a fixed width, hidden under 600 pt.
    func testTheToolbarAndRowsFollowThePanesWidth() {
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 1200), .wide)
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 1000), .wide)
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 999), .compact)
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 700), .compact)
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 692), .compact)
        XCTAssertEqual(HistoryTabView.tier(paneWidth: 691), .narrow)
        XCTAssertEqual(HistoryTabView.metaWidth(paneWidth: 1100), 180)
        XCTAssertEqual(HistoryTabView.metaWidth(paneWidth: 700), 120)
        XCTAssertNil(HistoryTabView.metaWidth(paneWidth: 599))
        XCTAssertEqual(HistoryTabView.filterLabel(agent: nil, project: nil), "Filter")
        XCTAssertEqual(HistoryTabView.filterLabel(agent: .claude, project: Fixture.key("/x/raven")),
                       "\(Agent.claude.displayName) · raven")
    }

    /// A key, through the router's real dispatch (`HistoryKeys.route` then
    /// `HistoryKeys.perform`), as RootView sends it.
    @discardableResult
    private func press(_ history: HistoryModel, _ keyCode: UInt16, _ characters: String = "",
                       _ modifiers: NSEvent.ModifierFlags = [], focus: HistoryKeyFocus = .none) -> HistoryKeys.Effect? {
        guard case .history(let command) = HistoryKeys.route(keyCode: keyCode, characters: characters, modifiers: modifiers,
                                                             focus: focus, sheetAttached: false) else { return nil }
        return HistoryKeys.perform(command, on: history, undoManager: nil)
    }

    /// Through the keyboard: a filter, then ⌘A and ⌘⌫ before its page lands.
    /// The router checks nothing; ⌘⌫ is recorded behind ⌘A and archives
    /// exactly what the new filter shows.
    func testKeyboardSelectAllThenCommandDeleteAfterAFilter() async {
        let h = harness([session("a", hoursAgo: 1), session("b", project: "/p/b", hoursAgo: 2),
                         session("c", project: "/p/b", hoursAgo: 3)], members: ["a", "b", "c"])
        var archived: [String] = []
        h.history.archiveMembers = { ids, _, _ in archived += ids }
        await load(h.history)
        let gate = gate(h.history)

        h.history.projectKeyFilter = Fixture.key("/p/b")
        await waitHeld(gate)
        XCTAssertEqual(press(h.history, 0, "a", [.command]), .handled)
        XCTAssertEqual(press(h.history, 51, "\u{7f}", [.command]), .handled, "the router does not judge it")
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(h.history.waitingCommandCount, 2)

        gate.release()
        await h.history.settle()
        XCTAssertEqual(Set(archived), ["b", "c"])
    }

    /// Type A, Return, type B: the keystroke cancels the Return; nothing
    /// opens, on A's page or on B's.
    func testTypingAfterReturnCancelsIt() async {
        let rows = [session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)]
        let h = harness(rows)
        h.history.queryDebounce = 10
        await load(h.history)
        let gate = gate(h.history)

        h.history.draft = "Alpha"
        press(h.history, 36, focus: .historySearch)
        await waitHeld(gate)
        XCTAssertEqual(h.history.waitingCommandCount, 1)
        h.history.draft = "Beta"
        XCTAssertEqual(h.history.waitingCommandCount, 0, "a keystroke is newer input")
        gate.release()
        await h.history.settle()
        XCTAssertTrue(h.opened().isEmpty)
        XCTAssertEqual(h.history.query, "Alpha", "B is still typing; nothing applied it")
    }

    /// A command that brings newer input while recorded commands are being
    /// run stops the rest: the arrow after it never runs, here or on the
    /// next page.
    func testNewerInputDuringReplayStopsTheRest() async {
        let rows = [session("m1", project: "/p/b", hoursAgo: 1), session("m2", project: "/p/b", hoursAgo: 2),
                    session("o1", project: "/p/b", hoursAgo: 3), session("o2", project: "/p/b", hoursAgo: 4)]
        let h = harness(rows, members: ["m1", "m2"])
        var archived: [String] = []
        h.history.archiveMembers = { [weak history = h.history] ids, _, _ in
            archived += ids
            history?.scope = .notInTemple   // newer input, arriving mid-replay
        }
        await load(h.history)
        h.history.scope = .inTemple
        await h.history.settle()
        let gate = gate(h.history)

        h.history.projectKeyFilter = Fixture.key("/p/b")
        await waitHeld(gate)
        press(h.history, 0, "a", [.command])
        press(h.history, 51, "\u{7f}", [.command])
        press(h.history, 125)
        XCTAssertEqual(h.history.waitingCommandCount, 3)
        gate.release()
        await h.history.settle()

        XCTAssertEqual(Set(archived), ["m1", "m2"])
        XCTAssertEqual(h.history.waitingCommandCount, 0)
        XCTAssertEqual(h.history.selectedIDs, ["o1"], "the new page's first row; the ↓ was dropped")
    }

    /// Return, ↓, Return, all recorded while the page is built: the first
    /// Return opens a tab and is terminal, so exactly one session opens.
    func testAReplayedReturnThatOpensATabEndsTheReplay() async {
        let rows = [session("r0", title: "Other", hoursAgo: 1), session("r1", title: "Match one", hoursAgo: 2),
                    session("r2", title: "Match two", hoursAgo: 3)]
        let h = harness(rows)
        await load(h.history)
        let gate = gate(h.history)

        h.history.query = "match"
        await waitHeld(gate)
        press(h.history, 36)
        press(h.history, 125)
        press(h.history, 36)
        XCTAssertEqual(h.history.waitingCommandCount, 3)
        gate.release()
        await h.history.settle()
        XCTAssertEqual(h.opened(), ["r1"], "one tab, from the first Return")
        XCTAssertEqual(h.history.waitingCommandCount, 0)
    }

    /// ⌘I then Return, recorded: the import's sheet goes up, and the Return
    /// behind it does nothing.
    func testAReplayedImportThatAsksEndsTheReplay() async {
        let rows = [session("o1", hoursAgo: 1), session("o2", project: "/p/b", hoursAgo: 2)]
        let h = harness(rows)
        await load(h.history)
        let gate = gate(h.history)

        h.history.projectKeyFilter = Fixture.key("/p/b")
        await waitHeld(gate)
        press(h.history, 34, "i", [.command])
        press(h.history, 36)
        gate.release()
        await h.history.settle()
        XCTAssertEqual(h.history.pendingImport?.sessions.map(\.id), ["o2"])
        XCTAssertTrue(h.opened().isEmpty, "nothing opened behind the sheet")
        XCTAssertEqual(h.history.waitingCommandCount, 0)
        // And with the sheet up, a command does nothing.
        h.history.openSelected()
        XCTAssertTrue(h.opened().isEmpty)
    }

    /// Return recorded, then Esc: withdrawn. Return recorded, then the tab
    /// leaves: withdrawn.
    func testEscapeAndLeavingWithdrawRecordedCommandsFromTheKeyboard() async {
        let rows = [session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)]
        let h = harness(rows)
        await load(h.history)
        let gate = gate(h.history)

        h.history.query = "Beta"
        await waitHeld(gate)
        press(h.history, 36)
        XCTAssertEqual(press(h.history, 53), .handled)
        XCTAssertEqual(h.history.waitingCommandCount, 0)
        gate.release()
        await h.history.settle()
        XCTAssertTrue(h.opened().isEmpty)

        let again = self.gate(h.history)
        h.history.query = "Beta"
        await waitHeld(again)
        press(h.history, 36)
        h.history.deactivate()
        XCTAssertEqual(h.history.waitingCommandCount, 0)
        again.release()
        await h.history.settle()
        XCTAssertTrue(h.opened().isEmpty)
    }

    /// ⌘A then ⌘⌫ straight after a filter change act on what the new filter
    /// shows, once it is shown, never on the old page.
    func testSelectAllThenArchiveWaitForTheFilteredPage() async {
        let h = harness([session("a", hoursAgo: 1), session("b", project: "/p/b", hoursAgo: 2)], members: ["a", "b"])
        var archived: [String] = []
        h.history.archiveMembers = { ids, _, _ in archived += ids }
        await load(h.history)
        let gate = gate(h.history)

        h.history.projectKeyFilter = Fixture.key("/p/b")
        await waitHeld(gate)
        h.history.selectAll()
        h.history.archiveSelected(undoManager: nil)
        XCTAssertTrue(h.history.selection.isEmpty, "nothing selected from the page being replaced")
        XCTAssertTrue(archived.isEmpty)
        XCTAssertEqual(h.history.waitingCommandCount, 2)

        gate.release()
        await h.history.settle()
        XCTAssertEqual(archived, ["b"], "only what the filter shows")
        XCTAssertEqual(h.history.notice?.text, "1 session archived")
    }

    /// An arrow pressed while the filtered page is built moves from that
    /// page's first row once it lands, and Return opens where it moved.
    func testArrowThenReturnAfterAFilterActOnTheNewPage() async {
        let rows = [session("r0", title: "Other", hoursAgo: 1), session("r1", title: "Match one", hoursAgo: 2),
                    session("r2", title: "Match two", hoursAgo: 3), session("r3", title: "Match three", hoursAgo: 4)]
        let h = harness(rows)
        await load(h.history)
        let gate = gate(h.history)

        h.history.query = "match"
        await waitHeld(gate)
        h.history.moveCursor(by: 1)
        h.history.openSelected()
        XCTAssertTrue(h.opened().isEmpty)

        gate.release()
        await h.history.settle()
        XCTAssertEqual(h.history.selectedIDs, ["r2"])
        XCTAssertEqual(h.opened(), ["r2"])
    }

    /// Typing, then Return while its page is built, then Esc: the Return is
    /// withdrawn, and nothing opens on the cleared search.
    func testEscapeWithdrawsAReturnStillWaiting() async {
        let rows = [session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)]
        let h = harness(rows)
        h.history.queryDebounce = 10
        await load(h.history)
        let gate = gate(h.history)

        h.history.draft = "Beta"
        h.history.openSelected()
        await waitHeld(gate)
        XCTAssertEqual(h.history.waitingCommandCount, 1)
        XCTAssertEqual(h.history.escape(), .clearedSearch)
        XCTAssertEqual(h.history.waitingCommandCount, 0)

        gate.release()
        await h.history.settle()
        XCTAssertTrue(h.opened().isEmpty)
        XCTAssertEqual(h.history.selectedIDs, ["a"])
    }

    /// A later filter change, or the tab leaving the screen, cancels what
    /// was waiting rather than running it on a page nobody saw.
    func testALaterFilterOrLeavingCancelsWaitingCommands() async {
        let rows = [session("a", hoursAgo: 1), session("b", project: "/p/b", hoursAgo: 2)]
        let h = harness(rows)
        await load(h.history)
        let gate = gate(h.history)

        h.history.projectKeyFilter = Fixture.key("/p/b")
        await waitHeld(gate)
        h.history.selectAll()
        h.history.projectKeyFilter = nil
        XCTAssertEqual(h.history.waitingCommandCount, 0, "superseded by the newer question")
        h.history.selectAll()
        h.history.deactivate()
        XCTAssertEqual(h.history.waitingCommandCount, 0, "the tab left")
        gate.release()
        await h.history.settle()
        XCTAssertLessThanOrEqual(h.history.selection.count, 1, "no ⌘A ran")
    }

    /// A bridge that sets the query while typing is still debouncing ends
    /// the debounce: the old typing does not land on the new page.
    func testSettingTheQueryInsideTheDebounceWindowEndsIt() async {
        let h = harness([session("a", title: "Alpha", hoursAgo: 1), session("b", title: "Beta", hoursAgo: 2)])
        h.history.queryDebounce = 0.05
        await load(h.history)

        h.history.draft = "Beta"
        h.history.query = ""   // unchanged: a bridge clearing the search
        XCTAssertEqual(h.history.draft, "")
        try? await Task.sleep(nanoseconds: 150_000_000)
        await h.history.settle()
        XCTAssertEqual(h.history.query, "")
        XCTAssertEqual(ids(h.history.visibleRows), ["a", "b"])
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
        await h.history.settle()
        XCTAssertEqual(h.history.inTempleCount, 1, "caught up on activation")
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

        let installs = h.history.rebuildCount
        await h.history.rebuild()
        await h.history.rebuild()

        XCTAssertEqual(published, 0)
        XCTAssertEqual(h.history.rebuildCount, installs, "nothing changed, nothing installed")
    }

    // MARK: Tab lifecycle

    /// Closing the tab clears what the tab asked (filters, selection,
    /// notices) and keeps what it learned: the rows are on the page the
    /// moment it opens again, before any read.
    func testClosingTheTabResetsItsViewStateAndKeepsItsRows() async {
        let h = harness([session("a", hoursAgo: 1), session("b", hoursAgo: 2)])
        await load(h.history)
        h.history.scope = .notInTemple
        h.history.query = "x"
        h.history.justArchivedChip = .init(memberships: [])

        h.history.reset()
        XCTAssertTrue(h.history.selection.isEmpty)
        await h.history.settle()

        XCTAssertEqual(h.history.scope, .all)
        XCTAssertEqual(h.history.query, "")
        XCTAssertNil(h.history.justArchivedChip)
        XCTAssertEqual(ids(h.history.allRows), ["a", "b"], "the rows stay")
        XCTAssertEqual(ids(h.history.visibleRows), ["a", "b"], "answering the cleared question")

        // Reopened with a read that never answers: the rows are there at once.
        h.history.catalog = { AsyncStream { _ in } }
        h.history.activate()
        XCTAssertEqual(ids(h.history.visibleRows), ["a", "b"])
        XCTAssertEqual(h.history.selectedIDs, ["a"], "the first row is selected straight away")
        h.history.deactivate()
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

    /// ⌘Y over ⌘K, with History under it: the panel goes and History stays
    /// — it does not also jump back to the previous tab.
    func testCommandYOverAPanelOnHistoryClosesThePanelAndStays() {
        let model = makeModel()
        model.openSessions.openSession(Fixture.session("a", project: "/p/a"))
        model.toggleHistory()

        model.toggleCommandPalette()
        model.toggleHistory()
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive, "the palette went; History stayed")

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
                       searchSelection: Bool = false, searchText: Bool = false) -> HistoryKeyRoute {
        HistoryKeys.route(keyCode: keyCode, characters: characters, modifiers: modifiers,
                          focus: focus, sheetAttached: sheet, searchHasSelection: searchSelection,
                          searchHasText: searchText)
    }

    private enum Key {
        static let down: UInt16 = 125, up: UInt16 = 126, ret: UInt16 = 36, enter: UInt16 = 76, esc: UInt16 = 53
        static let a: UInt16 = 0, c: UInt16 = 8, f: UInt16 = 3, i: UInt16 = 34, r: UInt16 = 15
        static let k: UInt16 = 40, w: UInt16 = 13, y: UInt16 = 16, delete: UInt16 = 51
    }

    /// ⌘⌫ archives the selection, from the list or an empty search field;
    /// with text in the field it deletes text, as in any field, and another
    /// field keeps it.
    func testCommandDeleteArchivesTheSelectionUnlessTheSearchHasText() {
        XCTAssertEqual(route(Key.delete, "\u{7f}", [.command]), .history(.archiveSelection))
        XCTAssertEqual(route(Key.delete, "\u{7f}", [.command], focus: .historySearch), .history(.archiveSelection))
        XCTAssertEqual(route(Key.delete, "\u{7f}", [.command], focus: .historySearch, searchText: true), .general)
        XCTAssertEqual(route(Key.delete, "\u{7f}", [.command], focus: .foreignField), .general)
        XCTAssertEqual(route(Key.delete, "\u{7f}"), .general, "plain delete is not History's")
        XCTAssertEqual(route(Key.delete, "\u{7f}", [.command, .option]), .general)
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

/// Archive lives in History (ADR-031): archiving from the sidebar, finding
/// archived sessions in History's Archived scope, and bringing them back one
/// at a time. Ported from the retired ⌘⇧Y browser's model cases, with the
/// one-session restore that replaced "opening restores the project".
@MainActor
final class HistoryArchiveTests: XCTestCase {
    private func makeModel(_ rows: [Session], database: TempleDB? = nil,
                           resolutions: MemberResolution = .confirmedAbsent) -> (AppModel, SessionOverlayStore, TempleDB) {
        let database = database ?? (try! TempleDB.inMemory())
        Fixture.join(rows, to: database)
        let overlay = SessionOverlayStore(db: database)
        let model = AppModel(
            surfaceFactory: FakeTerminalSurfaceFactory(),
            engines: [FakeEngine(CatalogFixtureIndex(projects: []))],
            database: database,
            settings: SettingsStore(defaults: Fixture.uniqueDefaults()),
            overlay: overlay)
        model.history.catalog = { AsyncStream { $0.finish() } }
        model.receiveEngineSnapshot(EngineSnapshot(generation: 1, resolutions: Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, resolutions) })))
        return (model, overlay, database)
    }

    private func twoProjects() -> [Session] {
        [Fixture.row("a1", project: "/p/a", title: "Alpha one", updated: 40),
         Fixture.row("a2", project: "/p/a", title: "Alpha two", updated: 30),
         Fixture.row("b1", project: "/p/b", title: "Beta one", updated: 20)]
    }

    /// The page as it stands, in `scope`, searched for `query`.
    private func page(_ model: AppModel, _ scope: HistoryScope = .archived, query: String = "") async -> [String] {
        let history = model.history
        history.activate()
        history.scope = scope
        history.query = query
        await history.settle()
        return history.visibleRows.map(\.sessionID)
    }

    private func row(_ model: AppModel, _ id: String) -> HistoryRow? {
        model.history.allRows.first { $0.sessionID == id }
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func settleSink() async {
        // The active-tab sink lands on RunLoop.main.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    // MARK: Archiving a session

    func testArchivingASessionMovesItFromEveryBrowseSurfaceToHistorysArchivedScope() async {
        let (model, overlay, _) = makeModel(twoProjects())
        overlay.togglePin("a1")
        XCTAssertEqual(model.pinnedSessions.map(\.id), ["a1"])

        overlay.setArchived(true, sessionID: "a1")

        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a2", "b1"])
        XCTAssertTrue(model.pinnedSessions.isEmpty)
        XCTAssertFalse(model.paletteResults("").contains { $0.id == "a1" })
        XCTAssertFalse(model.paletteResults("alpha").contains { $0.id == "a1" }, "not in ⌘K")
        let archived = await page(model)
        XCTAssertEqual(archived, ["a1"])
        let searched = await page(model, query: "alpha")
        XCTAssertEqual(searched, ["a1"])
        let inTemple = await page(model, .inTemple)
        XCTAssertEqual(inTemple, ["a2", "b1"], "In Temple is what the sidebar shows")
        let all = await page(model, .all)
        XCTAssertEqual(all, ["a1", "a2", "b1"], "All still lists it, tagged")
        XCTAssertEqual(row(model, "a1")?.isArchived, true)

        overlay.setArchived(false, sessionID: "a1")
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a1", "a2", "b1"])
        let after = await page(model)
        XCTAssertTrue(after.isEmpty)
    }

    /// Pinned-and-archived is a contradiction: one says always in front of me,
    /// the other says put away. Unarchiving does not hand the pin back.
    func testArchivingClearsThePinAndUnarchivingDoesNotRestoreIt() {
        let (model, overlay, _) = makeModel(twoProjects())
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
        let (model, overlay, _) = makeModel(twoProjects())
        let undo = undoManager()
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
        model.archiveProject(Fixture.key("/p/b"), undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Archive Project")
        undo.undo()
        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/b")))
    }

    // MARK: Restore

    /// Follow-up 1 of the auto-archive approval: Undo of a Restore puts the
    /// row back exactly. A Temple archive stays Temple's, reason and date
    /// included; it does not turn into the user's.
    func testUndoingARestoreOfATempleArchiveKeepsItTemplesWithItsDate() async throws {
        let (model, overlay, database) = makeModel([Fixture.row("gone", project: "/p/a")])
        let ref = MembershipRef(id: "gone", host: .local, incarnation: try XCTUnwrap(database.sessionState("gone")?.incarnation))
        let archivedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try database.autoArchive([AutoArchiveEntry(ref: ref, reason: .transcriptMissing)],
                                                idleBefore: .distantFuture, at: archivedAt), ["gone"])
        _ = await page(model)
        let undo = undoManager()

        undo.beginUndoGrouping()
        model.history.restore([try XCTUnwrap(row(model, "gone"))], undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertFalse(overlay.isArchived("gone"))
        XCTAssertNotNil(try database.sessionState("gone")?.keptAt, "a person's restore is kept")
        XCTAssertEqual(undo.undoActionName, "Restore Session")
        XCTAssertEqual(model.history.notice, .init(text: "1 session restored", offersUndo: true))

        undo.undo()
        let state = try XCTUnwrap(database.sessionState("gone"))
        XCTAssertTrue(state.archived)
        XCTAssertEqual(state.archiveReason, .transcriptMissing, "still Temple's archive")
        XCTAssertEqual(state.archivedAt, archivedAt, "with its own date")
        XCTAssertNil(state.keptAt)
        XCTAssertEqual(model.history.notice?.text, "Restore undone")

        undo.redo()
        XCTAssertFalse(overlay.isArchived("gone"))
        undo.undo()
        XCTAssertEqual(try database.sessionState("gone")?.archiveReason, .transcriptMissing, "and again after a redo")
    }

    /// Restore on a session whose project is archived brings back that
    /// session only: the mask is taken apart into the other sessions' own
    /// flags (pins untouched), the mask comes off, and one Undo reverses
    /// all of it.
    func testRestoringOneSessionOfAnArchivedProjectBringsBackOnlyThatSession() async throws {
        let rows = [Fixture.row("a1", project: "/p/a", title: "Alpha one", updated: 40),
                    Fixture.row("a2", project: "/p/a", title: "Alpha two", updated: 30),
                    Fixture.row("a3", project: "/p/a", title: "Alpha three", updated: 20),
                    Fixture.row("b1", project: "/p/b", title: "Beta one", updated: 10)]
        let (model, overlay, database) = makeModel(rows)
        overlay.togglePin("a2")
        overlay.setArchived(true, sessionID: "a3")
        let a3Before = try XCTUnwrap(database.sessionState("a3"))
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        let archived = await page(model)
        XCTAssertEqual(archived, ["a1", "a2", "a3"])
        XCTAssertEqual(row(model, "a1")?.archiveStatus, .withProject(Fixture.key("/p/a")))
        XCTAssertEqual(row(model, "a1")?.statusTooltip,
                       "Its project a is archived. Restore brings back this session; the rest of a stays archived.")
        let undo = undoManager()

        undo.beginUndoGrouping()
        model.history.restore([try XCTUnwrap(row(model, "a1"))], undoManager: undo)
        undo.endUndoGrouping()

        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/a")), "the mask is off")
        XCTAssertFalse(try XCTUnwrap(database.sessionState("a1")).archived)
        let a2 = try XCTUnwrap(database.sessionState("a2"))
        XCTAssertTrue(a2.archived, "the rest of the project stays away, now by its own flag")
        XCTAssertNil(a2.archiveReason)
        XCTAssertTrue(a2.pinned, "pins untouched: restoring it later returns its pin, as the project's restore would")
        XCTAssertEqual(try database.sessionState("a3"), a3Before, "already archived on its own: untouched")
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["a1"])
        let stillArchived = await page(model)
        XCTAssertEqual(stillArchived, ["a2", "a3"])
        XCTAssertEqual(row(model, "a2")?.archiveStatus, .byUser(at: nil))

        undo.undo()
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/a")), "the mask is back")
        XCTAssertFalse(try XCTUnwrap(database.sessionState("a2")).archived)
        XCTAssertTrue(try XCTUnwrap(database.sessionState("a2")).pinned)
        XCTAssertNil(try XCTUnwrap(database.sessionState("a1")).keptAt)
        XCTAssertEqual(try database.sessionState("a3"), a3Before)
        XCTAssertFalse(undo.canUndo, "one undo step")
        XCTAssertTrue(model.displayProjects.allSatisfy { $0.path != "/p/a" })
    }

    /// Restore project lifts the mask and leaves every row's own flag as it
    /// is: a session archived on its own (by Temple or the user) stays away.
    func testRestoreProjectLeavesRowFlagsAlone() async throws {
        let (model, overlay, _) = makeModel(twoProjects())
        overlay.setArchived(true, sessionID: "a2")
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        model.history.projectKeyFilter = Fixture.key("/p/a")
        _ = await page(model, .all)
        XCTAssertTrue(model.history.filteredProjectIsArchived, "the page offers Restore project")
        let undo = undoManager()

        undo.beginUndoGrouping()
        model.history.restoreProject(Fixture.key("/p/a"), undoManager: undo)
        undo.endUndoGrouping()

        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/a")))
        XCTAssertTrue(overlay.isArchived("a2"))
        XCTAssertEqual(model.displayProjects.first { $0.path == "/p/a" }?.sessions.map(\.id), ["a1"])
        XCTAssertEqual(model.history.notice?.text, "a restored")
        XCTAssertEqual(undo.undoActionName, "Restore Project")
        await model.history.settle()
        XCTAssertFalse(model.history.filteredProjectIsArchived)
    }

    /// Return on an archived row that cannot resume restores it and opens
    /// nothing; Return on an all-archived selection restores every one.
    func testReturnRestoresWhatCannotOpenAndAWholeArchivedSelection() async throws {
        let (model, overlay, _) = makeModel([Fixture.row("no-folder", title: "No folder"),
                                             Fixture.row("x", project: "/p", updated: 20),
                                             Fixture.row("y", project: "/p", updated: 10),
                                             Fixture.row("live", project: "/p", updated: 5)])
        for id in ["no-folder", "x", "y"] { overlay.setArchived(true, sessionID: id) }
        _ = await page(model)
        model.history.click(try XCTUnwrap(row(model, "no-folder")).id)
        let undo = undoManager()

        undo.beginUndoGrouping()
        model.history.openSelected(undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertFalse(overlay.isArchived("no-folder"))
        XCTAssertTrue(model.openSessions.tabs.isEmpty, "a Restore starts nothing")
        undo.undo()
        XCTAssertTrue(overlay.isArchived("no-folder"))

        await model.history.settle()
        model.history.selectAll()
        XCTAssertTrue(model.history.selectionSummary.allArchived)
        undo.beginUndoGrouping()
        model.history.openSelected(undoManager: undo)
        undo.endUndoGrouping()
        let stillArchived = ["no-folder", "x", "y"].filter { overlay.isArchived($0) }
        XCTAssertEqual(stillArchived, [])
        XCTAssertEqual(model.history.notice?.text, "3 sessions restored")
        XCTAssertTrue(model.openSessions.tabs.isEmpty)

        // A mixed selection: Return opens nothing and restores nothing.
        overlay.setArchived(true, sessionID: "x")
        _ = await page(model, .all)
        model.history.selectAll()
        XCTAssertEqual(model.history.selectionSummary.archived, 1)
        model.history.openSelected(undoManager: nil)
        XCTAssertTrue(overlay.isArchived("x"))
        XCTAssertTrue(model.openSessions.tabs.isEmpty)
    }

    /// ⌘⌫ archives the selection only when every row of it can be archived.
    func testCommandDeleteArchivesOnlyAWhollyArchivableSelection() async {
        let (model, overlay, _) = makeModel(twoProjects())
        overlay.setArchived(true, sessionID: "b1")
        _ = await page(model, .all)
        model.history.selectAll()
        XCTAssertFalse(model.history.selectionSummary.archivable, "one is archived already")
        XCTAssertFalse(model.history.canArchiveSelection)
        model.history.archiveSelected(undoManager: nil)
        XCTAssertFalse(overlay.isArchived("a1"))

        _ = await page(model, .inTemple)
        model.history.selectAll()
        XCTAssertTrue(model.history.selectionSummary.archivable)
        model.history.archiveSelected(undoManager: nil)
        XCTAssertTrue(overlay.isArchived("a1") && overlay.isArchived("a2"))
        XCTAssertEqual(model.history.notice?.text, "2 sessions archived")
    }

    // MARK: Projects

    func testAnArchivedProjectsSessionsAreListedUnderArchived() async {
        let (model, overlay, _) = makeModel(twoProjects())

        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))

        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/b"])
        XCTAssertEqual(model.projectPickerResults("").map(\.path), ["/p/b"])
        let archived = await page(model)
        XCTAssertEqual(archived, ["a1", "a2"])
        let searched = await page(model, query: "alpha two")
        XCTAssertEqual(searched, ["a2"], "found by what you remember about it")
        model.history.showOnly(project: Fixture.key("/p/a"))
        await model.history.settle()
        XCTAssertTrue(model.history.filteredProjectIsArchived)

        overlay.setProjectArchived(false, key: Fixture.key("/p/a"))
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
    }

    /// The index can list one session id under two projects; History's rows
    /// are keyed by host, agent and id, so each session appears once.
    func testHistoryListsEachArchivedSessionOnce() async {
        let (model, overlay, _) = makeModel([Fixture.row("dup", project: "/p/a", title: "Shared", updated: 10),
                                             Fixture.row("dup", project: "/p/b", title: "Shared", updated: 10)])
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        overlay.setProjectArchived(true, key: Fixture.key("/p/b"))
        let all = await page(model, .all)
        XCTAssertEqual(all, ["dup"])
    }

    // MARK: Opening

    /// Opening is the one implicit unarchive, and it brings back that one
    /// session: the rest of an archived project stays away (ADR-031).
    func testOpeningAnArchivedSessionInAnArchivedProjectBringsBackOnlyThatSession() async {
        let rows = twoProjects()
        let (model, overlay, database) = makeModel(rows)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))

        model.openSessions.openSession(rows[0])
        await settleSink()

        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/a")))
        XCTAssertTrue(overlay.isArchived("a2"), "the rest of the project stays archived")
        XCTAssertNil(try database.sessionState("a2")?.archiveReason)
        XCTAssertEqual(model.displayProjects.map(\.path), ["/p/a", "/p/b"])
        XCTAssertEqual(model.displayProjects.first?.sessions.map(\.id), ["a1"])
    }

    /// The sink lands a run-loop turn late. Open archived A and land on B
    /// inside one turn, and a sink that read "the active tab" would see B
    /// twice: A stays put away despite being opened.
    func testOpeningThenSwitchingWithinOneTurnStillUnarchivesTheOpenedSession() async {
        let rows = twoProjects()
        let (model, overlay, _) = makeModel(rows)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))

        model.openSessions.openSession(rows[0])   // a1
        model.openSessions.openSession(rows[2])   // b1, now active
        await settleSink()

        XCTAssertEqual(model.openSessions.activeTab?.sessionID, "b1")
        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/a")))
    }

    /// Index churn is not a decision: a session resumed in some other terminal
    /// updates its file, and must stay archived.
    func testDiskActivityDoesNotUnarchive() throws {
        let rows = twoProjects()
        let database = try TempleDB.inMemory()
        let (model, overlay, _) = makeModel(rows, database: database)
        overlay.setArchived(true, sessionID: "a1")
        overlay.setProjectArchived(true, key: Fixture.key("/p/b"))

        let summaries = ["a1", "b1"].map { id in
            TranscriptSummary(id: id, agent: .claude,
                locator: TranscriptLocator(host: .local, path: "/tmp/\(id).jsonl"),
                modifiedAt: Date(timeIntervalSince1970: 500), cwd: "/changed", firstPrompt: "Changed externally")
        }
        model.receiveEngineSnapshot(.authorized(generation: 2, resolutions: [:],
            summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) }), in: database))

        XCTAssertTrue(overlay.isArchived("a1"))
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/b")))
        XCTAssertEqual(model.displayProjects.flatMap(\.sessions).map(\.id), ["a2"])
    }

    // MARK: Navigation

    /// ⌘⇧Y is History in the Archived scope; it puts a floating panel away
    /// like ⌘Y, keeps search and filters, and pressed on History already
    /// showing Archived it goes back like ⌘Y.
    func testCommandShiftYOpensHistoryInTheArchivedScope() {
        let (model, _, _) = makeModel(twoProjects())
        model.openSessions.openSession(twoProjects()[2])
        let sessionTab = model.openSessions.activeTabID
        model.history.query = "alpha"
        model.history.agentFilter = .claude
        model.toggleCommandPalette()

        model.showArchived()
        XCTAssertFalse(model.commandPalettePresented)
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.history.scope, .archived)
        XCTAssertEqual(model.history.query, "alpha", "search is left as it is")
        XCTAssertEqual(model.history.agentFilter, .claude)

        model.showArchived()
        XCTAssertEqual(model.openSessions.activeTabID, sessionTab, "again on Archived: back, like ⌘Y")
        XCTAssertNotNil(model.openSessions.historyTab)

        model.toggleHistory()
        model.history.scope = .all
        model.showArchived()
        XCTAssertTrue(model.historyActive, "on History in another scope it switches scope and stays")
        XCTAssertEqual(model.history.scope, .archived)
    }

    /// The app's tab moving off History cancels what History recorded, in
    /// the same call.
    func testActivatingAnotherTabCancelsRecordedCommandsAtOnce() async throws {
        let (model, _, _) = makeModel(twoProjects())
        _ = await page(model, .all)
        model.openSessions.openHistory()
        var held: CheckedContinuation<Void, Never>?
        var holding = true
        model.history.beforeInstall = {
            guard holding else { return }
            await withCheckedContinuation { held = $0 }
        }
        model.history.query = "alpha"
        while held == nil { await Task.yield() }
        model.history.openSelected()
        XCTAssertEqual(model.history.waitingCommandCount, 1)

        model.openSessions.openSession(twoProjects()[2])
        XCTAssertEqual(model.history.waitingCommandCount, 0, "cancelled by the activation itself")

        holding = false
        held?.resume()
        await model.history.settle()
        XCTAssertEqual(model.openSessions.tabs.filter { $0.kind == .session }.compactMap(\.sessionID), ["b1"])
    }

    /// A Restore whose every membership changed since the page was drawn
    /// says so, offers no Undo, and leaves ⌘Z to the action before it.
    func testARestoreThatRestoresNothingSaysSoAndOffersNoUndo() async throws {
        let rows = [Fixture.row("a1", project: "/p/a", updated: 40), Fixture.row("z", project: "/p/z", updated: 10)]
        let (model, overlay, _) = makeModel(rows)
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        _ = await page(model)
        let shown = try XCTUnwrap(row(model, "a1"))
        let undo = undoManager()
        undo.beginUndoGrouping()
        model.archiveSession("z", undoManager: undo)
        undo.endUndoGrouping()

        XCTAssertEqual(overlay.leave([SessionKey(id: "a1", host: .local)]), ["a1"])
        _ = overlay.join("a1", via: .imported, agent: .claude, core: SessionCore(directory: "/p/y"))
        // As in the app: the event's group is only opened by a registration.
        let steps = model.history.undoStepCount
        model.history.restore([shown], undoManager: undo)

        XCTAssertEqual(model.history.notice,
                       HistoryModel.Notice(text: "Nothing to restore; it changed since the list loaded.", offersUndo: false))
        XCTAssertEqual(model.history.undoStepCount, steps, "nothing went on the stack: the field's own undo stays")
        XCTAssertEqual(undo.undoActionName, "Archive Session", "nothing of the restore's on the stack")
        undo.undo()
        XCTAssertFalse(overlay.isArchived("z"), "⌘Z undoes the action before it")
    }

    /// A Restore that restores some of what it was given announces the real
    /// count.
    func testAPartlySkippedRestoreAnnouncesTheRealCount() async throws {
        let rows = [Fixture.row("a1", project: "/p/a", updated: 40), Fixture.row("a2", project: "/p/a", updated: 30)]
        let (model, overlay, _) = makeModel(rows)
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        _ = await page(model)
        let shown = try ["a1", "a2"].map { try XCTUnwrap(row(model, $0)) }
        XCTAssertEqual(overlay.leave([SessionKey(id: "a2", host: .local)]), ["a2"])
        _ = overlay.join("a2", via: .imported, agent: .claude, core: SessionCore(directory: "/p/y"))
        let undo = undoManager()

        let steps = model.history.undoStepCount
        undo.beginUndoGrouping()
        model.history.restore(shown, undoManager: undo)
        undo.endUndoGrouping()

        XCTAssertEqual(model.history.notice, HistoryModel.Notice(text: "1 session restored", offersUndo: true))
        XCTAssertFalse(overlay.isArchived("a1"))
        XCTAssertEqual(undo.undoActionName, "Restore Session")
        // The page forgets its search field's text undo on each step, so
        // ⌘Z reaches this one (FieldEditorUndo).
        XCTAssertEqual(model.history.undoStepCount, steps + 1, "a step went on the stack")
        undo.undo()
        XCTAssertEqual(model.history.notice?.text, "Restore undone")
        XCTAssertEqual(model.history.undoStepCount, steps + 1, "an undo offers no Undo")
        undo.redo()
        XCTAssertEqual(model.history.notice, HistoryModel.Notice(text: "1 session restored", offersUndo: true))
        XCTAssertEqual(model.history.undoStepCount, steps + 2, "a redo is a step again")
    }

    /// Every bridge into History clears the "Archived just now" chip, and
    /// ⌘K's "Search history for…" asks in All with no leftover filters.
    func testBridgesIntoHistoryClearTheChipAndTheSearchBridgeAsksAll() {
        let (model, _, _) = makeModel(twoProjects())
        let chip = HistoryModel.JustArchivedChip(memberships: [MembershipRef(id: "a1", host: .local, incarnation: "i")])
        model.history.justArchivedChip = chip
        model.showInHistory(project: Fixture.key("/p/b"))
        XCTAssertNil(model.history.justArchivedChip)
        model.history.justArchivedChip = chip
        model.showInHistory(sessionID: "a1")
        XCTAssertNil(model.history.justArchivedChip)
        model.history.justArchivedChip = chip
        model.history.scope = .archived
        model.history.agentFilter = .codex
        model.history.projectKeyFilter = Fixture.key("/p/a")
        model.searchHistory("alpha")
        XCTAssertNil(model.history.justArchivedChip)
        XCTAssertEqual(model.history.scope, .all)
        XCTAssertNil(model.history.agentFilter)
        XCTAssertNil(model.history.projectKeyFilter)
        XCTAssertEqual(model.history.query, "alpha")
    }

    /// Navigating while the search is still debouncing: the typing does not
    /// land on the page the bridge opened.
    func testABridgeInsideTheDebounceWindowDropsThePendingTyping() async {
        let (model, _, _) = makeModel(twoProjects())
        model.history.queryDebounce = 0.05
        model.history.draft = "zzz"
        model.showInHistory(project: Fixture.key("/p/a"))
        XCTAssertEqual(model.history.draft, "")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.history.query, "")
    }

    /// Restore carries the membership the row showed: a session that left
    /// and joined again (into another archived project) after the page was
    /// drawn is not the one restored, and its new project is left alone.
    func testRestoreFromAStalePageSkipsAMembershipThatLeftAndJoinedAgain() async throws {
        let rows = [Fixture.row("a1", project: "/p/a", updated: 40), Fixture.row("x1", project: "/p/x", updated: 20)]
        let (model, overlay, database) = makeModel(rows)
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        _ = await page(model)
        let shown = try XCTUnwrap(row(model, "a1"))

        // Before the page catches up (no await in between).
        XCTAssertEqual(overlay.leave([SessionKey(id: "a1", host: .local)]), ["a1"])
        _ = overlay.join("a1", via: .imported, agent: .claude, core: SessionCore(directory: "/p/x"))
        overlay.setProjectArchived(true, key: Fixture.key("/p/x"))
        let rejoined = try XCTUnwrap(database.sessionState("a1"))
        model.history.restore([shown], undoManager: nil)

        XCTAssertEqual(try database.sessionState("a1"), rejoined, "the new membership is not the one shown")
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/x")))
        XCTAssertFalse(try XCTUnwrap(database.sessionState("x1")).archived, "its project is not taken apart")
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/a")))
    }

    /// Redo restores the memberships the Restore restored. One that left and
    /// joined again in between (here into another archived project) is not
    /// it: Redo leaves it, and that project's mask, alone.
    func testRedoSkipsAMembershipThatLeftAndJoinedAgainSinceTheUndo() async throws {
        let rows = [Fixture.row("a1", project: "/p/a", updated: 40), Fixture.row("a2", project: "/p/a", updated: 30),
                    Fixture.row("x1", project: "/p/x", updated: 20)]
        let (model, overlay, database) = makeModel(rows)
        overlay.setProjectArchived(true, key: Fixture.key("/p/a"))
        _ = await page(model)
        let undo = undoManager()
        undo.beginUndoGrouping()
        model.history.restore([try XCTUnwrap(row(model, "a1"))], undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertFalse(overlay.isProjectArchived(Fixture.key("/p/a")))
        undo.undo()
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/a")))

        XCTAssertEqual(overlay.leave([SessionKey(id: "a1", host: .local)]), ["a1"])
        _ = overlay.join("a1", via: .imported, agent: .claude, core: SessionCore(directory: "/p/x"))
        overlay.setProjectArchived(true, key: Fixture.key("/p/x"))
        let rejoined = try XCTUnwrap(database.sessionState("a1"))

        XCTAssertTrue(undo.canRedo)
        undo.redo()

        XCTAssertEqual(try database.sessionState("a1"), rejoined, "the new membership is not the one restored")
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/x")), "its project's mask is not taken apart")
        XCTAssertFalse(try XCTUnwrap(database.sessionState("x1")).archived)
        XCTAssertTrue(overlay.isProjectArchived(Fixture.key("/p/a")))
        XCTAssertFalse(try XCTUnwrap(database.sessionState("a2")).archived)
    }

    /// "Show in History" from a sidebar project header: every session of the
    /// project, archived ones one segment away.
    func testShowInHistoryForAProjectFiltersToIt() {
        let (model, _, _) = makeModel(twoProjects())
        model.history.query = "zzz"
        model.history.scope = .notInTemple
        model.showInHistory(project: Fixture.key("/p/a"))
        XCTAssertTrue(model.historyActive)
        XCTAssertEqual(model.history.projectKeyFilter, Fixture.key("/p/a"))
        XCTAssertEqual(model.history.scope, .all)
        XCTAssertEqual(model.history.query, "")
    }

    /// The chip filters exactly the given memberships, clears on any scope
    /// pick, and is Esc's second rung.
    func testTheArchivedJustNowChipFiltersExactlyItsMemberships() async throws {
        let (model, overlay, database) = makeModel(twoProjects())
        for id in ["a1", "a2", "b1"] { overlay.setArchived(true, sessionID: id) }
        let refs = try ["a1", "b1"].map { id in
            MembershipRef(id: id, host: .local, incarnation: try XCTUnwrap(database.sessionState(id)?.incarnation))
        }
        let history = model.history
        history.justArchivedChip = .init(memberships: Set(refs))
        let chipped = await page(model)
        XCTAssertEqual(chipped, ["a1", "b1"])
        XCTAssertTrue(history.isNarrowed)

        history.pickScope(.archived)
        XCTAssertNil(history.justArchivedChip, "picking any segment, the same one included, clears it")
        await history.settle()
        XCTAssertEqual(history.visibleRows.map(\.sessionID), ["a1", "a2", "b1"])

        history.justArchivedChip = .init(memberships: Set(refs))
        history.query = ""
        XCTAssertEqual(history.escape(), .clearedChip)
        XCTAssertNil(history.justArchivedChip)

        // A membership that left and joined again is not the one archived.
        history.justArchivedChip = .init(memberships: [MembershipRef(id: "a2", host: .local, incarnation: "another")])
        await history.settle()
        XCTAssertTrue(history.visibleRows.isEmpty)
    }

    // MARK: Rows

    /// Every status and condition a member can be in, with its words.
    func testStandingTagsAndTooltipsForEveryKindOfArchive() {
        let builder = HistoryRowBuilder()
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        func member(_ id: String, archived: Bool = false, reason: ArchiveReason? = nil, at: Date? = nil,
                    kept: Date? = nil, directory: String? = "/x/raven", resolution: MemberResolution? = nil,
                    agent: Agent? = .claude) -> Session {
            Session(state: SessionState(id: id, pinned: false, archived: archived, customName: nil, color: nil,
                generatedTitle: nil, lastOpenedAt: nil, joinedVia: .opened, joinedAt: day, agent: agent,
                directory: directory, title: id, incarnation: "i", archiveReason: reason, keptAt: kept,
                archivedAt: at), resolution: resolution)
        }
        var context = HistoryRowBuilder.Context()
        func build(_ session: Session) -> HistoryRow {
            builder.row(member: session, catalog: nil, conflict: nil, context: context)
        }

        let user = build(member("user", archived: true, at: day))
        XCTAssertEqual(user.standing, .archived(.byUser(at: day)))
        XCTAssertEqual(user.statusTooltip, "You archived it on Oct 2. Restore puts it back in the sidebar.")
        XCTAssertNil(user.conditionTag, "the user's own archive is not a condition")
        XCTAssertEqual(build(member("old", archived: true)).statusTooltip,
                       "You archived it. Restore puts it back in the sidebar.", "no date before v12")

        let transcript = build(member("t", archived: true, reason: .transcriptMissing))
        XCTAssertEqual(transcript.standing, .archived(.byTemple(.transcriptMissing)))
        XCTAssertEqual(transcript.conditionTag, .noTranscript)
        XCTAssertEqual(transcript.statusTooltip,
                       "No transcript on disk carries this session, so Temple archived it; it can't be resumed. Restore puts it back in the sidebar anyway.")
        XCTAssertEqual(transcript.tagTooltip, transcript.statusTooltip)
        XCTAssertFalse(transcript.canResume)

        let folder = build(member("f", archived: true, reason: .folderMissing))
        XCTAssertEqual(folder.conditionTag, .noFolder)
        XCTAssertEqual(folder.statusTooltip,
                       "The folder /x/raven no longer exists, so Temple archived it. Restore puts it back in the sidebar anyway.")
        XCTAssertFalse(folder.canResume)

        context.archivedProjects = [Fixture.key("/x/raven")]
        let masked = build(member("m"))
        XCTAssertEqual(masked.standing, .archived(.withProject(Fixture.key("/x/raven"))))
        XCTAssertTrue(masked.projectArchived)
        XCTAssertTrue(masked.canResume, "opening restores it on the way")
        context.archivedProjects = []

        let kept = build(member("k", kept: day, resolution: .confirmedAbsent))
        XCTAssertEqual(kept.standing, .inTemple)
        XCTAssertEqual(kept.conditionTag, .noTranscript)
        XCTAssertEqual(kept.tagTooltip,
                       "No transcript on disk carries this session, so it can't be resumed. You restored it, so it stays in the sidebar.")
        XCTAssertEqual(build(member("n", resolution: .confirmedAbsent)).tagTooltip,
                       "The session file is no longer on disk. Opening it will fail; archive it from here.")
        XCTAssertEqual(kept.statusTooltip, "In Temple · opened Oct 2")

        context.folders = [Fixture.key("/x/raven"): .missing]
        let noFolder = build(member("nf"))
        XCTAssertEqual(noFolder.conditionTag, .noFolder)
        XCTAssertEqual(noFolder.tagTooltip, "The folder /x/raven no longer exists. Opening it starts nothing.")
        context.folders = [Fixture.key("/x/raven"): .unknown]
        XCTAssertNil(build(member("unknown")).conditionTag, "unknown is not missing")

        // An unknown reason from a newer build still reads as Temple's.
        XCTAssertEqual(build(member("future", archived: true, reason: ArchiveReason(rawValue: "from_the_future"))).statusTooltip,
                       "Temple archived it. Restore puts it back in the sidebar.")
    }

    /// Follow-up 2, and the cross-branch rule: the engine does not watch
    /// archived rows, so a user's archived row has "No transcript" only when
    /// a listing proven complete for its agent found no file for it. A file
    /// that was found but did not read (unreadable, mismatched) is a
    /// candidate, not an absence; another agent's listing proves nothing.
    func testAnArchivedMembersTranscriptIsMissingOnlyWhenACompletedListingFoundNoFile() {
        let builder = HistoryRowBuilder()
        let member = Session(state: SessionState(id: "away", pinned: false, archived: true, customName: nil, color: nil,
            generatedTitle: nil, lastOpenedAt: nil, joinedVia: .opened, joinedAt: nil, agent: .claude,
            directory: "/p", title: "Away", incarnation: "i"))
        var context = HistoryRowBuilder.Context()
        func missing() -> Bool { builder.row(member: member, catalog: nil, conflict: nil, context: context).transcriptMissing }
        XCTAssertFalse(missing(), "no evidence today: nothing is proven")
        context.coverage = [.local: CatalogCoverage(candidates: [.codex: []])]
        XCTAssertFalse(missing(), "another agent's listing proves nothing about a Claude session")
        context.coverage = [.local: CatalogCoverage(candidates: [.claude: ["away"]])]
        XCTAssertFalse(missing(), "a candidate that did not read is not absence")
        context.coverage = [HostID(rawValue: "box"): CatalogCoverage(candidates: [.claude: []])]
        XCTAssertFalse(missing(), "another host's listing proves nothing")
        context.coverage = [.local: CatalogCoverage(candidates: [.claude: ["someone-else"], .codex: ["away"]])]
        let proven = builder.row(member: member, catalog: nil, conflict: nil, context: context)
        XCTAssertTrue(proven.transcriptMissing, "the Claude file was removed; a Codex file with its id hides nothing")
        XCTAssertEqual(proven.conditionTag, .noTranscript)
        XCTAssertFalse(proven.canResume)
        XCTAssertEqual(proven.tagTooltip,
                       "No transcript on disk carries this session, so it can't be resumed. Restore puts it back in the sidebar anyway.")
    }

    /// The same rule through a read's completion: unreadable and mismatched
    /// candidates are not absent, a removed file is; summaries the read did
    /// not deliver leave only inside the completed listing.
    func testACompletedReadsCandidatesDecideAbsenceNotItsSummaries() async {
        func member(_ id: String, agent: Agent = .claude) -> Session {
            Session(state: SessionState(id: id, pinned: false, archived: true, customName: nil, color: nil,
                generatedTitle: nil, lastOpenedAt: nil, joinedVia: .opened, joinedAt: nil, agent: agent,
                directory: "/p", title: id, incarnation: "i-\(id)"))
        }
        let outside = { (id: String, agent: Agent) in
            TranscriptSummary(id: id, agent: agent, locator: TranscriptLocator(host: .local, path: "/tmp/\(id)"),
                              modifiedAt: Date(timeIntervalSince1970: 100), cwd: "/p", firstPrompt: id)
        }
        let projector = HistoryProjector()
        _ = await projector.apply(HistoryProjectionInput(
            catalog: [.upsert([outside("stale", .claude), outside("codex-stale", .codex)], noise: [], folders: [:])],
            members: [member("unreadable"), member("mismatched"), member("removed"), member("codex", agent: .codex)]))
        let completion = CatalogCompletion(seen: [], coverage: [
            .local: CatalogCoverage(candidates: [.claude: ["unreadable", "mismatched", "stale"]])])
        let snapshot = await projector.apply(HistoryProjectionInput(catalog: [.complete(completion)]))
        let rows = Dictionary(uniqueKeysWithValues: (snapshot?.allRows ?? []).map { ($0.sessionID, $0) })
        XCTAssertEqual(rows["unreadable"]?.transcriptMissing, false)
        XCTAssertEqual(rows["mismatched"]?.transcriptMissing, false)
        XCTAssertEqual(rows["removed"]?.transcriptMissing, true)
        XCTAssertEqual(rows["codex"]?.transcriptMissing, false, "Codex's listing did not complete")
        XCTAssertNil(rows["stale"], "no usable summary this read: the outside row goes")
        XCTAssertNotNil(rows["codex-stale"], "outside the completed listing it stays")
    }

    /// Absence is the host side's own rule (`provesNoTranscript`), in its
    /// candidate spelling (`TranscriptFormat.candidateKey`): an id spelled
    /// differently that the agent reads as the same session is not absent.
    func testCandidateIDsFollowTheHostsSpelling() {
        let spell = { (agent: Agent, id: String) in TranscriptFormats.format(for: agent).candidateKey(id) }
        let coverage = CatalogCoverage(candidates: [.codex: [spell(.codex, "ABC-123")], .claude: [spell(.claude, "Mixed-Case")]])
        XCTAssertFalse(coverage.provesAbsent("abc-123", agent: .codex))
        XCTAssertFalse(coverage.provesAbsent("ABC-123", agent: .codex))
        XCTAssertFalse(coverage.provesAbsent("Mixed-Case", agent: .claude))
        XCTAssertTrue(coverage.provesAbsent("other", agent: .claude))
        XCTAssertEqual(coverage.completedAgents, [.codex, .claude])
    }
    /// Members, archived ones included, are on the page from SQLite before
    /// any disk read lands.
    func testMembersAreOnThePageBeforeAnyDiskRead() async {
        let (model, overlay, _) = makeModel(twoProjects())
        overlay.setArchived(true, sessionID: "a2")
        model.history.catalog = { AsyncStream { _ in } }   // never answers
        model.history.activate()
        await model.history.settle()
        XCTAssertTrue(model.history.isReading)
        XCTAssertEqual(model.history.allRows.map(\.sessionID), ["a1", "a2", "b1"])
        model.history.scope = .archived
        await model.history.settle()
        XCTAssertEqual(model.history.visibleRows.map(\.sessionID), ["a2"])
        model.history.deactivate()
    }

    /// The page draws from prepared rows: building every row's inputs and
    /// the bar's summary reads no overlay, and re-sending unchanged members
    /// installs nothing.
    func testThePageReadsNoOverlayAndAnUnchangedProjectionInstallsNothing() async {
        let (model, overlay, _) = makeModel(twoProjects())
        overlay.setArchived(true, sessionID: "b1")
        _ = await page(model, .all)
        let history = model.history
        history.selectAll()
        let lookups = history.overlayLookups
        let installs = history.rebuildCount
        var published = 0
        let subscription = history.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        for row in history.visibleRows { _ = history.rowInputs(row) }
        _ = history.selectionSummary
        _ = history.countsLine
        _ = history.filteredProjectIsArchived
        _ = history.bottomBar
        XCTAssertEqual(history.overlayLookups, lookups, "no overlay read while drawing")

        await history.rebuild()
        XCTAssertEqual(history.rebuildCount, installs)
        XCTAssertEqual(published, 0)
    }
}
