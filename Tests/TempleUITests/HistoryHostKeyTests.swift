import XCTest
import AppKit
@testable import TempleUI
import TempleCore
import TempleTerminalAPI
import TempleTestSupport
@testable import TempleLocalHost

/// History across hosts and agents (Track B C9/C10/D3/E3): every row is
/// keyed by host, agent and session id; a member attaches only to the row
/// whose host and known agent match; the catalog is read from every host at
/// once, each host failing for itself.
@MainActor
final class HistoryHostKeyTests: XCTestCase {
    private let remote = HostID(rawValue: "build-box")
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: Fixtures

    private func summary(_ id: String, host: HostID = .local, agent: Agent = .claude,
                         title: String? = nil, secondsAgo: Double = 60) -> TranscriptSummary {
        TranscriptSummary(id: id, agent: agent,
            locator: TranscriptLocator(host: host, path: "/\(host.rawValue)/\(agent.rawValue)/\(id).jsonl"),
            modifiedAt: Date().addingTimeInterval(-secondsAgo), cwd: "/work/project",
            firstPrompt: title ?? "\(agent.rawValue) on \(host.displayName)")
    }

    private func events(_ batches: [(HostID, [TranscriptSummary])]) -> () -> AsyncStream<HostCatalogEvent> {
        { AsyncStream { continuation in
            for (host, rows) in batches {
                continuation.yield(.sessions(rows, read: rows.count, total: rows.count), host: host)
            }
            continuation.finish()
        } }
    }

    private func history(_ db: TempleDB, catalog: @escaping () -> AsyncStream<HostCatalogEvent>)
        -> (HistoryModel, SessionOverlayStore) {
        let overlay = SessionOverlayStore(db: db)
        let history = HistoryModel(overlay: overlay, catalog: catalog,
                                   directoryEvidence: { _ in .exists })
        return (history, overlay)
    }

    private func load(_ history: HistoryModel, file: StaticString = #filePath, line: UInt = #line) async {
        history.activate()
        await waitFor(file: file, line: line) { history.readState == .done }
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func row(_ history: HistoryModel, _ key: HistoryKey, file: StaticString = #filePath, line: UInt = #line) throws -> HistoryRow {
        try XCTUnwrap(history.allRows.first { $0.id == key }, "no row \(key)", file: file, line: line)
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-history-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func claudeData(_ id: String, prompt: String, cwd: String) -> Data {
        Data(#"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"#.utf8)
    }

    // MARK: Two hosts, one id

    func testTwoHostsListingOneIDAreTwoRowsAndOnlyTheMembersHostAttaches() async throws {
        let db = try TempleDB.inMemory()
        let local = summary("same", host: .local), box = summary("same", host: remote, secondsAgo: 30)
        let (history, overlay) = history(db, catalog: events([(.local, [local]), (remote, [box])]))
        await load(history)

        let localKey = HistoryKey(local), boxKey = HistoryKey(box)
        XCTAssertEqual(Set(history.allRows.map(\.id)), [localKey, boxKey], "one row per host, same id")
        history.click(boxKey)
        XCTAssertEqual(history.selection, [boxKey], "selecting one host's row selects only it")

        history.requestImport([try row(history, localKey)])
        await history.confirmImport(undoManager: nil)
        XCTAssertEqual(try db.sessionState("same")?.host, .local)
        XCTAssertEqual(history.justImported, [localKey], "the other host's row is not 'Imported'")

        let attached = try row(history, localKey)
        XCTAssertTrue(history.isInTemple(attached))
        let other = try row(history, boxKey)
        XCTAssertNil(other.member, "a member never attaches to another host's row")
        XCTAssertFalse(history.isInTemple(other))
        XCTAssertEqual(other.conflict, .host(.local))
        XCTAssertEqual(other.conflict?.message, "Already in Temple on this Mac.")
        XCTAssertFalse(other.canImport)
        XCTAssertFalse(other.canResume, "opening it would join it: not from here")
        XCTAssertEqual(history.inTempleCount, 1)

        history.requestImport([other])
        XCTAssertNil(history.pendingImport, "a conflicting row is never offered for import")
        history.selectAll()
        XCTAssertTrue(history.selectedOutsideRows.isEmpty)
        history.requestImport([box])
        XCTAssertNil(history.pendingImport, "nor by its summary")
        XCTAssertEqual(overlay.rows["same"]?.host, .local)
    }

    // MARK: Agent conflicts

    /// Claude and Codex both claim one id on one host. Whichever batch comes
    /// first, the member's agent attaches and the other is a conflict.
    func testAnAgentConflictIsItsOwnRowInEitherArrivalOrder() async throws {
        let claude = summary("dual", agent: .claude, secondsAgo: 30), codex = summary("dual", agent: .codex, secondsAgo: 60)
        for order in [[claude, codex], [codex, claude]] {
            let db = try TempleDB.inMemory()
            try db.join(sessionID: "dual", via: .opened, agent: .claude, core: SessionCore(directory: "/work/project"))
            let (history, _) = history(db, catalog: events(order.map { (.local, [$0]) }))
            await load(history)

            XCTAssertEqual(history.allRows.count, 2, "\(order.map(\.agent))")
            let attached = try row(history, HistoryKey(claude))
            XCTAssertEqual(attached.member?.id, "dual")
            let conflict = try row(history, HistoryKey(codex))
            XCTAssertNil(conflict.member)
            XCTAssertEqual(conflict.conflict, .agent(.claude))
            XCTAssertEqual(conflict.conflict?.message, "Already in Temple as a Claude Code session.")
            XCTAssertEqual(history.inTempleCount, 1)
            history.requestImport([conflict])
            XCTAssertNil(history.pendingImport)
        }
    }

    /// The other arrival: both rows are outside until one is imported; then
    /// the other becomes the conflict.
    func testImportingOneAgentsRowTurnsTheOtherIntoAConflict() async throws {
        let db = try TempleDB.inMemory()
        let claude = summary("dual", agent: .claude, secondsAgo: 30), codex = summary("dual", agent: .codex, secondsAgo: 60)
        let (history, _) = history(db, catalog: events([(.local, [claude, codex])]))
        await load(history)
        XCTAssertTrue(history.allRows.allSatisfy(\.canImport))

        history.requestImport([try row(history, HistoryKey(codex))])
        await history.confirmImport(undoManager: nil)

        XCTAssertEqual(try db.sessionState("dual")?.agent, .codex)
        XCTAssertEqual(try row(history, HistoryKey(codex)).member?.id, "dual")
        XCTAssertEqual(try row(history, HistoryKey(claude)).conflict, .agent(.codex))
    }

    /// A legacy member that never recorded its agent attaches to the one
    /// agent listing its id on its host; when both agents list it, which one
    /// it is cannot be told, so it stands alone and both are conflicts. Once
    /// the row learns its agent, that agent's row attaches.
    func testAnAgentlessMemberAttachesOnlyWhenOneAgentListsIt() async throws {
        let claude = summary("legacy", agent: .claude, secondsAgo: 30), codex = summary("legacy", agent: .codex, secondsAgo: 60)

        let single = try TempleDB.inMemory()
        try single.join(sessionID: "legacy", via: .opened)
        let (one, _) = history(single, catalog: events([(.local, [claude])]))
        await load(one)
        XCTAssertEqual(one.allRows.map(\.id), [HistoryKey(claude)])
        XCTAssertEqual(one.allRows.first?.member?.id, "legacy")

        let db = try TempleDB.inMemory()
        try db.join(sessionID: "legacy", via: .opened)
        let (both, overlay) = history(db, catalog: events([(.local, [claude, codex])]))
        await load(both)
        let memberKey = HistoryKey(host: .local, agent: nil, sessionID: "legacy")
        XCTAssertEqual(Set(both.allRows.map(\.id)), [memberKey, HistoryKey(claude), HistoryKey(codex)])
        XCTAssertNotNil(try row(both, memberKey).member)
        XCTAssertEqual(try row(both, HistoryKey(claude)).conflict, .host(.local))
        XCTAssertEqual(try row(both, HistoryKey(codex)).conflict, .host(.local))
        XCTAssertEqual(both.inTempleCount, 1)

        XCTAssertTrue(overlay.join("legacy", via: .opened, agent: .claude).isJoined, "an agentless row takes the incoming agent")
        both.rebuild()
        XCTAssertEqual(Set(both.allRows.map(\.id)), [HistoryKey(claude), HistoryKey(codex)])
        XCTAssertEqual(try row(both, HistoryKey(claude)).member?.id, "legacy")
        XCTAssertEqual(try row(both, HistoryKey(codex)).conflict, .agent(.claude))
    }

    // MARK: Bulk import of rows sharing an id

    /// Two outside rows share an id — two hosts, or two agents on one host.
    /// A bulk import joins the first and refuses the second with its reason:
    /// one imported, one failure, one key marked and one key undoable.
    func testABulkImportOfRowsSharingAnIDImportsOneAndRefusesTheOther() async throws {
        let cases: [(first: TranscriptSummary, second: TranscriptSummary, reason: String)] = [
            (summary("pair", host: .local, secondsAgo: 30), summary("pair", host: remote, secondsAgo: 60),
             "Already in Temple on this Mac."),
            (summary("pair", agent: .codex, secondsAgo: 30), summary("pair", agent: .claude, secondsAgo: 60),
             "Already in Temple as a Codex session."),
        ]
        for (first, second, reason) in cases {
            let db = try TempleDB.inMemory()
            let (history, overlay) = history(db, catalog: events([(first.locator.host, [first]), (second.locator.host, [second])]))
            await load(history)
            history.selectAll()
            history.requestImport()
            let request = try XCTUnwrap(history.pendingImport)
            XCTAssertEqual(request.sessions.map(HistoryKey.init), [HistoryKey(first), HistoryKey(second)])
            let manager = undoManager()
            manager.beginUndoGrouping()
            await history.confirmImport(request, undoManager: manager)
            manager.endUndoGrouping()

            XCTAssertEqual(history.notice?.text, "1 session imported")
            XCTAssertEqual(history.justImported, [HistoryKey(first)])
            let failure = try XCTUnwrap(history.importFailure, reason)
            XCTAssertEqual(failure.title, "Couldn't import 1 of 2 sessions")
            XCTAssertTrue(failure.message.contains(reason), failure.message)
            XCTAssertTrue(failure.message.contains("The other one was imported."))
            XCTAssertEqual(history.inTempleCount, 1)
            XCTAssertNotNil(try row(history, HistoryKey(first)).member)
            XCTAssertNotNil(try row(history, HistoryKey(second)).conflict)

            manager.undo()
            XCTAssertNil(try db.sessionState("pair"))
            XCTAssertEqual(history.notice?.text, "Import undone", "the undo held only the one key that joined")
            manager.redo()
            XCTAssertEqual(try db.sessionState("pair")?.host, first.locator.host)
            XCTAssertEqual(try db.sessionState("pair")?.agent, first.agent)
            XCTAssertTrue(overlay.isTempleSession("pair"))
        }
    }

    // MARK: Undo carries the host

    /// An import from this Mac is undone after the same id joined from
    /// another host: the undo's leave names this Mac, so the other host's
    /// row stays, and stays marked as it was.
    func testUndoAfterASameIDImportOnAnotherHostLeavesTheOtherRowAlone() async throws {
        let db = try TempleDB.inMemory()
        let local = summary("moved", host: .local), box = summary("moved", host: remote, secondsAgo: 30)
        let (history, overlay) = history(db, catalog: events([(.local, [local]), (remote, [box])]))
        await load(history)
        let first = undoManager()

        first.beginUndoGrouping()
        await history.confirmImport(HistoryModel.importRequest(for: [local]), undoManager: first)
        first.endUndoGrouping()
        XCTAssertEqual(try db.sessionState("moved")?.host, .local)

        // This Mac's row goes another way; the id then joins from the box.
        XCTAssertEqual(overlay.leave([SessionKey(id: "moved", host: .local)]), ["moved"])
        history.rebuild()
        XCTAssertTrue(try row(history, HistoryKey(box)).canImport)
        let second = undoManager()
        second.beginUndoGrouping()
        await history.confirmImport(HistoryModel.importRequest(for: [box]), undoManager: second)
        second.endUndoGrouping()
        XCTAssertEqual(try db.sessionState("moved")?.host, remote)
        XCTAssertTrue(history.justImported.contains(HistoryKey(box)))

        first.undo()

        XCTAssertEqual(try db.sessionState("moved")?.host, remote, "the box's row is not this Mac's to undo")
        XCTAssertTrue(overlay.isTempleSession("moved"))
        XCTAssertTrue(history.justImported.contains(HistoryKey(box)))
        XCTAssertEqual(history.notice?.text, "Import not undone · changed since")
        XCTAssertNotNil(try row(history, HistoryKey(box)).member)
    }

    /// An undo names the membership its import made. After the Claude row
    /// left and the id joined again — as Codex's file, or the same Claude
    /// file re-imported — undoing the original import leaves the new
    /// membership alone, though it is an equally untouched import on the
    /// same host.
    func testUndoLeavesAMembershipThatReplacedTheImportedOne() async throws {
        let claude = summary("replaced", agent: .claude, secondsAgo: 30), codex = summary("replaced", agent: .codex, secondsAgo: 60)
        for replacement in [codex, claude] {
            let db = try TempleDB.inMemory()
            let (history, overlay) = history(db, catalog: events([(.local, [claude, codex])]))
            await load(history)
            let original = undoManager()
            original.beginUndoGrouping()
            await history.confirmImport(HistoryModel.importRequest(for: [claude]), undoManager: original)
            original.endUndoGrouping()
            let first = try XCTUnwrap(db.sessionState("replaced")?.incarnation)

            XCTAssertEqual(overlay.leave([SessionKey(id: "replaced", host: .local)]), ["replaced"])
            history.rebuild()
            let again = undoManager()
            again.beginUndoGrouping()
            await history.confirmImport(HistoryModel.importRequest(for: [replacement]), undoManager: again)
            again.endUndoGrouping()
            XCTAssertEqual(try db.sessionState("replaced")?.agent, replacement.agent)
            XCTAssertNotEqual(try db.sessionState("replaced")?.incarnation, first, "a rejoin is a new membership")

            original.undo()

            XCTAssertEqual(try db.sessionState("replaced")?.agent, replacement.agent, "\(replacement.agent): kept")
            XCTAssertTrue(overlay.isTempleSession("replaced"))
            XCTAssertEqual(history.notice?.text, "Import not undone · changed since")
            again.undo()
            XCTAssertNil(try db.sessionState("replaced"), "its own undo still takes it out")
        }
    }

    /// A tab on another host holding the same id does not keep this host's
    /// import from being undone.
    func testAnOpenTabCountsOnlyOnItsOwnHost() async throws {
        let db = try TempleDB.inMemory()
        let local = summary("tabbed", host: .local)
        let (history, _) = history(db, catalog: events([(.local, [local])]))
        history.hasOpenTab = { [remote] in $0.host == remote && $0.sessionID == "tabbed" }
        await load(history)
        let manager = undoManager()
        manager.beginUndoGrouping()
        await history.confirmImport(HistoryModel.importRequest(for: [local]), undoManager: manager)
        manager.endUndoGrouping()
        manager.undo()
        XCTAssertNil(try db.sessionState("tabbed"))
    }

    // MARK: Concurrent, host-tagged catalog

    private func registry(_ sources: [any HostSessionSource]) -> HostRegistry {
        HostRegistry(entries: sources.map { HostRegistry.Entry(source: $0, launcher: NoLauncher()) })
    }

    private func localSource(claude: [(id: String, prompt: String)]) throws -> LocalSessionSource {
        let root = try tempRoot()
        let project = root.appendingPathComponent("claude/-work-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for item in claude {
            try claudeData(item.id, prompt: item.prompt, cwd: root.path)
                .write(to: project.appendingPathComponent("\(item.id).jsonl"))
        }
        return LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude")),
                                           CodexSessionStore(root: root.appendingPathComponent("codex"))],
                                  monitorChanges: false)
    }

    func testAFailingHostReportsItselfWhileAnotherLists() async throws {
        let local = try localSource(claude: [("listed", "Here")])
        let box = FakeHostSource(host: remote)
        box.breakTransport()
        let hosts = registry([box, local])

        var events: [HostCatalogEvent] = []
        for await event in hosts.catalog() { events.append(event) }
        XCTAssertEqual(events.filter { $0.host == remote }.map(\.batch),
                       [.storeFailed(agent: nil, message: LocateError.transport("fake transport broken").localizedDescription)])
        let listed = events.filter { $0.host == .local }.flatMap { event -> [String] in
            if case .sessions(let rows, _, _) = event.batch { return rows.map(\.id) }
            return []
        }
        XCTAssertEqual(listed, ["listed"])

        let db = try TempleDB.inMemory()
        let (history, _) = history(db, catalog: { hosts.catalog() })
        await load(history)
        XCTAssertEqual(history.allRows.map(\.id), [HistoryKey(host: .local, agent: .claude, sessionID: "listed")])
        XCTAssertEqual(Set(history.storeFailures.map(\.host)), [remote], "only the box failed")
        XCTAssertEqual(Set(history.storeFailures.map(\.agent)), Set(Agent.allCases), "a whole host fails for every agent")
    }

    /// Hosts are read at once: a host that has not answered holds up no other.
    func testASlowHostHoldsUpNoOther() async throws {
        let gate = FakeGate()
        let slow = SlowCatalogSource(host: remote, gate: gate)
        let local = try localSource(claude: [("prompt", "Quick")])
        let hosts = registry([slow, local])
        let db = try TempleDB.inMemory()
        let (history, _) = history(db, catalog: { hosts.catalog() })

        history.activate()
        await waitFor { history.allRows.count == 1 }
        XCTAssertEqual(history.allRows.first?.host, .local)
        XCTAssertTrue(history.isReading, "the slow host has not finished")
        gate.open()
        await waitFor { history.readState == .done }
        XCTAssertEqual(Set(history.allRows.map(\.host)), [.local, remote])
    }

    /// A host whose folder checks stall holds up only its own rows: the
    /// local host's batches keep landing meanwhile. Ending the read cancels
    /// the stalled check, and nothing after it is asked or shown.
    func testAStalledFolderCheckHoldsUpNoOtherHostAndEndsWithTheRead() async throws {
        let box = FakeHostSource(host: remote)
        let gate = FakeGate()
        box.evidenceGate = gate
        let db = try TempleDB.inMemory()
        var continuation: AsyncStream<HostCatalogEvent>.Continuation!
        let stream = AsyncStream<HostCatalogEvent> { continuation = $0 }
        let remote = remote
        let history = HistoryModel(overlay: SessionOverlayStore(db: db), catalog: { stream },
            directoryEvidence: { key in key.host == remote ? await box.directoryEvidence(key.path) : .exists })
        history.activate()
        func onBox(_ id: String, _ folder: String) -> TranscriptSummary {
            TranscriptSummary(id: id, agent: .claude, locator: TranscriptLocator(host: remote, path: "/box/\(id).jsonl"),
                              modifiedAt: Date(), cwd: folder, firstPrompt: "On the box")
        }

        continuation.yield(.sessions([onBox("x", "/one"), onBox("y", "/two")], read: 2, total: 2), host: remote)
        await waitFor { box.counters.evidenceChecks == 1 }
        continuation.yield(.sessions([summary("a")], read: 1, total: 2), host: .local)
        await waitFor { history.allRows.map(\.sessionID) == ["a"] }
        continuation.yield(.sessions([summary("b", secondsAgo: 120)], read: 2, total: 2), host: .local)
        await waitFor { history.allRows.map(\.sessionID) == ["a", "b"] }
        XCTAssertTrue(history.isReading)

        history.deactivate()
        await waitFor { box.counters.evidenceCancelled == 1 }
        gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.counters.evidenceChecks, 1, "the second folder was asked after the read ended")
        XCTAssertFalse(history.allRows.contains { $0.host == remote })
    }

    /// Progress is the sum over the hosts heard from; a host still listing
    /// leaves the total open.
    func testReadProgressSumsTheHostsHeardFrom() async throws {
        let db = try TempleDB.inMemory()
        var continuation: AsyncStream<HostCatalogEvent>.Continuation!
        let stream = AsyncStream<HostCatalogEvent> { continuation = $0 }
        let (history, _) = history(db, catalog: { stream })
        history.activate()

        continuation.yield(.listed(total: 3), host: .local)
        await waitFor { history.readState == .reading(read: 0, total: 3) }
        continuation.yield(.sessions([summary("b", host: remote)], read: 1, total: 2), host: remote)
        await waitFor { history.readState == .reading(read: 1, total: 5) }
        continuation.yield(.sessions([summary("a")], read: 3, total: 3), host: .local)
        await waitFor { history.readState == .reading(read: 4, total: 5) }
        continuation.yield(.storeFailed(agent: nil, message: "gone"), host: remote)
        await waitFor { history.readState == .reading(read: 4, total: 4) }
        continuation.finish()
        await waitFor { history.readState == .done }
    }

    // MARK: Selection before emission, end to end

    /// A Claude transcript named for one session that records another is
    /// not that session's, end to end: History never lists it under the
    /// file's name, so importing everything it shows cannot store the other
    /// session's folder and title under that id — fills the engine makes
    /// later only ever fill NULLs, so nothing would have repaired them.
    func testAClaudeFileRecordingAnotherSessionIsNeitherListedNorImported() async throws {
        let root = try tempRoot()
        let project = root.appendingPathComponent("claude/-work-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let named = UUID().uuidString.lowercased(), recorded = UUID().uuidString.lowercased()
        let good = UUID().uuidString.lowercased()
        try claudeData(recorded, prompt: "Someone else's", cwd: "/elsewhere")
            .write(to: project.appendingPathComponent("\(named).jsonl"))
        try claudeData(good, prompt: "Mine", cwd: root.path).write(to: project.appendingPathComponent("\(good).jsonl"))
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        monitorChanges: false)
        let hosts = registry([source])
        let db = try TempleDB.inMemory()
        let (history, _) = history(db, catalog: { hosts.catalog() })
        await load(history)

        XCTAssertEqual(history.allRows.map(\.sessionID), [good])
        history.requestImport(history.allRows)
        await history.confirmImport(undoManager: nil)
        XCTAssertNil(try db.sessionState(named), "imported under the file's name")
        XCTAssertNil(try db.sessionState(recorded))
        XCTAssertEqual(try db.sessionState(good)?.title, "Mine")
        XCTAssertFalse(try db.sessionStates().contains { $0.directory == "/elsewhere" })
    }

    /// Import while the catalog is still streaming: the row History shows
    /// and imports for a Codex thread is the revert the CLI would resume,
    /// even though the older canonical rollout was modified more recently,
    /// and no later batch brings the older file back as a second row.
    func testImportDuringStreamingTakesTheSelectedRollout() async throws {
        let root = try tempRoot()
        let day = root.appendingPathComponent("codex/sessions/2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        func rollout(_ id: String, stamp: String, rollout: String? = nil, prompt: String, age: TimeInterval) throws -> URL {
            let url = day.appendingPathComponent("rollout-\(stamp)-\(id)\(rollout.map { "_" + $0 } ?? "").jsonl")
            try (#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(root.path)","timestamp":"2026-10-01T10:00:00Z"}}"#
                + "\n" + #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#)
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        _ = try rollout(thread, stamp: "2026-10-01T10-00-00", prompt: "Canonical", age: 10)
        let revert = try rollout(thread, stamp: "2026-10-01T11-00-00", rollout: UUID().uuidString.lowercased(), prompt: "Revert", age: 100)
        _ = try rollout(other, stamp: "2026-09-01T10-00-00", prompt: "Older thread", age: 1000)
        let source = LocalSessionSource(stores: [CodexSessionStore(root: root.appendingPathComponent("codex"))], monitorChanges: false)

        let gate = FakeGate()
        let catalog: () -> AsyncStream<HostCatalogEvent> = {
            AsyncStream { continuation in
                let task = Task {
                    var batches = 0
                    for try await batch in source.catalog(CatalogQuery(batchSize: 1)) {
                        continuation.yield(batch)
                        if case .sessions = batch { batches += 1; if batches == 1 { await gate.wait() } }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let db = try TempleDB.inMemory()
        let (history, _) = history(db, catalog: catalog)
        history.activate()
        let key = HistoryKey(host: .local, agent: .codex, sessionID: thread)
        await waitFor { history.allRows.contains { $0.id == key } }
        XCTAssertTrue(history.isReading)
        let shown = try row(history, key)
        XCTAssertEqual(shown.catalog?.locator.path.split(separator: "/").last.map(String.init), revert.lastPathComponent)

        history.requestImport([shown])
        await history.confirmImport(undoManager: nil)
        XCTAssertEqual(try db.sessionState(thread)?.transcriptPath.map { URL(fileURLWithPath: $0).lastPathComponent }, revert.lastPathComponent)
        XCTAssertEqual(try db.sessionState(thread)?.title, "Revert")

        gate.open()
        await waitFor { history.readState == .done }
        XCTAssertEqual(history.allRows.filter { $0.sessionID == thread }.count, 1)
        XCTAssertEqual(try row(history, key).catalog?.locator.path.split(separator: "/").last.map(String.init), revert.lastPathComponent)
        XCTAssertNotNil(try row(history, key).member)
        XCTAssertEqual(history.allRows.count, 2)
    }
}

@MainActor
private final class NoLauncher: HostLauncher {
    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch { throw CancellationError() }
    func availability(_ agent: Agent) -> LaunchAvailability { .unavailable(reason: "test host") }
}

/// A host whose catalog answers only once its gate opens.
private final class SlowCatalogSource: HostSessionSource, @unchecked Sendable {
    let host: HostID
    let capabilities: Set<HostCapability> = [.catalog]
    private let gate: FakeGate
    init(host: HostID, gate: FakeGate) { self.host = host; self.gate = gate }

    func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        LocateResult(coverage: 1, candidates: [:], complete: [], sharedRevision: [:])
    }
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        throw TranscriptReadError.missing
    }
    func directoryEvidence(_ path: String) async -> DirectoryEvidence { .unknown }
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .incomplete }
    func changes() -> AsyncThrowingStream<SourceChange, Error> { AsyncThrowingStream { _ in } }
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        let host = host, gate = gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                await gate.wait()
                let row = TranscriptSummary(id: "late", agent: .claude,
                    locator: TranscriptLocator(host: host, path: "opaque:late"), modifiedAt: Date(),
                    cwd: "/remote", firstPrompt: "Late")
                continuation.yield(.listed(total: 1))
                continuation.yield(.sessions([row], read: 1, total: 1))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
