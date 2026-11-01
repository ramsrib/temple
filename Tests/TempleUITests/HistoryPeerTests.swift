import XCTest
import AppKit
@testable import TempleUI
import TempleCore
import TempleTerminalAPI
import TempleTestSupport

/// History's page for a host's own Temple (docs/designs/
/// open-existing-sessions.md sections 1, 3 and 4): This Mac's page as it
/// was, a host's page read only when chosen, the other Temple's rows beside
/// this Mac's members, failures that hide nothing, and imports that carry a
/// name and colour and still undo.
@MainActor
final class HistoryPeerTests: XCTestCase {
    private let box = HostID(rawValue: "mac-b")

    // MARK: Fixtures

    private final class Peer {
        var answer: PeerRead
        var reads = 0
        var configuration: Int? = 1
        var resumed: [ResumeRequest] = []
        init(_ answer: PeerRead) { self.answer = answer }
    }

    private func peerRow(_ id: String, agent: Agent = .claude, directory: String = "/work/app", name: String? = nil,
                         title: String? = "A title", color: String? = nil, tab: Bool = false, archived: Bool = false) -> PeerRow {
        PeerRow(host: box, id: id, agent: agent, directory: directory, transcriptPath: "/home/b/.claude/projects/-work-app/\(id).jsonl",
                customName: name, title: title, color: color, archivedThere: archived, tabThere: tab,
                lastActiveAt: Date().addingTimeInterval(-120))
    }

    private func local(_ id: String) -> TranscriptSummary {
        TranscriptSummary(id: id, agent: .claude, locator: TranscriptLocator(host: .local, path: "/local/\(id).jsonl"),
                          modifiedAt: Date().addingTimeInterval(-60), cwd: "/work/here", firstPrompt: "On this Mac")
    }

    private func history(_ db: TempleDB, peer: Peer, catalog: [TranscriptSummary] = []) -> HistoryModel {
        let overlay = SessionOverlayStore(db: db)
        let history = HistoryModel(overlay: overlay, catalog: {
            AsyncStream { continuation in
                continuation.yield(.sessions(catalog, read: catalog.count, total: catalog.count), host: .local)
                continuation.finish()
            }
        }, directoryEvidence: { _ in .exists })
        history.readPeer = { _ in peer.reads += 1; return peer.answer }
        history.hostConfiguration = { _ in peer.configuration }
        history.enabledHosts = { [box] in [box] }
        history.resumeSession = { peer.resumed.append($0); return true }
        return history
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func show(_ history: HistoryModel, page: HistoryPage, peer: Peer) async {
        let before = peer.reads
        history.page = page
        if page.host != nil { await waitFor { peer.reads > before && history.peerPages[box]?.reading == false } }
        await settle(history)
    }

    private func settle(_ history: HistoryModel) async {
        for _ in 0..<10 { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    // MARK: Pages

    func testThisMacPageIsTodaysHistoryAndReadsNoHost() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1")])))
        let history = history(db, peer: peer, catalog: [local("l1")])
        history.activate()
        await waitFor { history.readState == .done }
        XCTAssertEqual(history.allRows.map(\.sessionID), ["l1"])
        XCTAssertEqual(peer.reads, 0, "This Mac contacts no host")

        await show(history, page: .host(box), peer: peer)
        await show(history, page: .thisMac, peer: peer)
        XCTAssertEqual(history.allRows.map(\.sessionID), ["l1"], "another Temple's rows are only on its host's page")
        XCTAssertEqual(peer.reads, 1, "switching back reads nothing")
    }

    func testHostPageListsTheOtherTemplesSessionsBesideThisMacsMembers() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "m1", via: .opened, agent: .claude, core: SessionCore(host: box, directory: "/work/app"))
        try db.setCustomName("Mine here", sessionID: "m1")
        try db.join(sessionID: "elsewhere", via: .opened, agent: .claude, core: SessionCore(host: .local, directory: "/x"))
        let peer = Peer(.listed(PeerListing(sessions: [
            peerRow("m1", name: "Theirs"), peerRow("p1", name: "Fix login", color: "blue", tab: true),
            peerRow("elsewhere"),
        ], skipped: 2)))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)

        let rows = Dictionary(uniqueKeysWithValues: history.allRows.map { ($0.sessionID, $0) })
        XCTAssertEqual(Set(rows.keys), ["m1", "p1", "elsewhere"])
        XCTAssertEqual(rows["m1"]?.title, "Mine here", "a member keeps this Temple's title")
        XCTAssertNotNil(rows["m1"]?.peer)
        XCTAssertTrue(rows["m1"]?.isMember == true)
        XCTAssertEqual(rows["p1"]?.title, "Fix login")
        XCTAssertEqual(rows["p1"]?.standing, .outside)
        XCTAssertTrue(rows["p1"]?.canImport == true)
        XCTAssertTrue(rows["p1"]?.canResume == true)
        XCTAssertEqual(rows["elsewhere"]?.conflict, .host(.local), "Temple's on another host: a conflict, no actions")
        XCTAssertEqual(history.peerPages[box]?.listing?.skipped, 2)

        history.scope = .notInTemple
        await settle(history)
        XCTAssertEqual(Set(history.visibleRows.map(\.sessionID)), ["p1", "elsewhere"], "a conflict is not this Mac's member here either, as in Not in Temple")
        XCTAssertEqual(HistoryScope.notInTemple.label(on: .host(box)), "Only there")
        XCTAssertEqual(HistoryScope.inTemple.label(on: .host(box)), "In Temple here")
        XCTAssertEqual(HistoryScope.inTemple.label(on: .thisMac), "In Temple")
    }

    func testAFailedReadKeepsTheLastListingAndHidesNoMember() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "m1", via: .opened, agent: .claude, core: SessionCore(host: box, directory: "/work/app"))
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        XCTAssertEqual(Set(history.allRows.map(\.sessionID)), ["m1", "p1"])

        peer.answer = .unreachable("ssh: connect to host mac-b: Operation timed out")
        history.refresh()
        await waitFor { peer.reads == 2 && history.peerPages[box]?.reading == false }
        await settle(history)
        XCTAssertEqual(Set(history.allRows.map(\.sessionID)), ["m1", "p1"], "a failed Refresh replaces nothing")
        XCTAssertEqual(history.peerPages[box]?.problem, .unreachable("ssh: connect to host mac-b: Operation timed out"))

        peer.answer = .noTemple
        history.refresh()
        await waitFor { peer.reads == 3 && history.peerPages[box]?.reading == false }
        XCTAssertTrue(history.noTempleHosts.contains(box), "the menu mutes it")
    }

    func testAChangedHostDropsWhatWasReadFromIt() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        XCTAssertEqual(history.allRows.map(\.sessionID), ["p1"])

        peer.configuration = 2
        history.hostConfigurationChanged(box)
        await settle(history)
        XCTAssertEqual(history.allRows.map(\.sessionID), [], "rows read under the old configuration are not this host's")
        XCTAssertNil(history.peerPages[box])
    }

    // MARK: Import and Undo

    func testImportBringsTheNameAndColourAndUndoStillWorks() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1", name: "Fix login", color: "blue")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)

        let undo = undoManager()
        history.requestImport(history.allRows)
        let request = try XCTUnwrap(history.pendingImport)
        XCTAssertEqual(request.peers.map(\.id), ["p1"])
        XCTAssertTrue(request.message.contains("then it runs on mac-b. Nothing on mac-b changes."), request.message)
        undo.beginUndoGrouping()
        await history.confirmImport(undoManager: undo)
        undo.endUndoGrouping()
        let state = try XCTUnwrap(try db.sessionState("p1"))
        XCTAssertEqual(state.host, box)
        XCTAssertEqual(state.customName, "Fix login")
        XCTAssertEqual(state.color, "blue")
        XCTAssertNil(state.title, "no title from the other Temple")

        // Undo works after the host is removed: it is this Mac's rows.
        peer.configuration = nil
        history.hostConfigurationChanged(box)
        undo.undo()
        XCTAssertNil(try db.sessionState("p1"), "the import is undone")
        // Its Redo would import from a host that isn't the one it read.
        undo.redo()
        XCTAssertNil(try db.sessionState("p1"), "Redo is refused once the host changed")
    }

    func testUndoKeepsASessionRenamedHereAfterTheImport() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1", name: "Fix login", color: "blue")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        let undo = undoManager()
        history.requestImport(history.allRows)
        undo.beginUndoGrouping()
        await history.confirmImport(undoManager: undo)
        undo.endUndoGrouping()
        try db.setCustomName("Renamed here", sessionID: "p1")
        undo.undo()
        XCTAssertEqual(try db.sessionState("p1")?.customName, "Renamed here", "a rename here is a decision the undo keeps")
    }

    // MARK: Open

    func testOpenHandsTheOtherTemplesFolderNameAndTabNote() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1", directory: "/work/app", name: "Fix login", color: "blue", tab: true)])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)

        XCTAssertTrue(history.open(try XCTUnwrap(history.allRows.first)))
        let request = try XCTUnwrap(peer.resumed.first)
        XCTAssertEqual(request.host, box)
        XCTAssertEqual(request.id, "p1")
        XCTAssertEqual(request.launchDirectory, "/work/app")
        XCTAssertEqual(request.carried, CarriedMarks(name: "Fix login", color: "blue"))
        XCTAssertEqual(request.locator?.host, box)
        XCTAssertEqual(request.peerTabNote, "mac-b's Temple also has a tab for this session, so it may be running there too.")
    }

    func testAMemberWithNoFolderOpensInTheOtherTemplesFolder() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "m1", via: .imported, agent: .claude, core: SessionCore(host: box))
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("m1", directory: "/work/app")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)

        let row = try XCTUnwrap(history.allRows.first { $0.sessionID == "m1" })
        XCTAssertTrue(row.isMember)
        XCTAssertTrue(row.canResume, "the other Temple's folder is the launch hint")
        XCTAssertTrue(history.open(row))
        XCTAssertEqual(peer.resumed.first?.launchDirectory, "/work/app")
        XCTAssertNil(peer.resumed.first?.carried, "a member keeps its own marks")
    }

    /// An import asked for before the host was replaced is refused after the
    /// replacement has been read too: it names the old host's rows.
    func testACapturedImportIsRefusedAfterTheHostIsReplacedAndReadAgain() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        history.requestImport(history.allRows)
        let captured = try XCTUnwrap(history.pendingImport)

        peer.configuration = 2
        history.hostConfigurationChanged(box)
        history.refresh()
        await waitFor { peer.reads == 2 && history.peerPages[box]?.reading == false }
        XCTAssertEqual(history.allRows.map(\.sessionID), ["p1"], "the replacement lists it again")

        await history.confirmImport(captured, undoManager: nil)
        XCTAssertNil(try db.sessionState("p1"), "the captured rows were the old host's")
    }

    /// Reading another Temple changes nothing about This Mac's page: a
    /// member with no folder keeps no project and can't open there.
    func testThisMacsRowsAreTheSameAfterAHostWasRead() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "m1", via: .imported, agent: .claude, core: SessionCore(host: box))
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("m1", directory: "/work/app")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        let before = try XCTUnwrap(history.allRows.first { $0.sessionID == "m1" })

        await show(history, page: .host(box), peer: peer)
        XCTAssertNotNil(history.allRows.first { $0.sessionID == "m1" }?.peer)
        await show(history, page: .thisMac, peer: peer)
        let after = try XCTUnwrap(history.allRows.first { $0.sessionID == "m1" })
        XCTAssertNil(after.peer)
        XCTAssertEqual(after.project, before.project)
        XCTAssertEqual(after.canResume, before.canResume)
        XCTAssertEqual(after, before)
    }

    func testProjectNavigationLandsOnThisMac() async throws {
        let db = try TempleDB.inMemory()
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("p1")])))
        let history = history(db, peer: peer)
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        history.showOnly(project: ProjectKey(host: .local, path: "/work/here"))
        XCTAssertEqual(history.page, .thisMac)
        history.page = .host(box)
        history.showOnly(project: ProjectKey(host: box, path: "/work/app"))
        XCTAssertEqual(history.page, .host(box), "a host's own project narrows its page")
    }

    /// On the host's page too, a member with no folder recorded is not filed
    /// under the other Temple's folder: its archive standing is its own.
    func testAPeersFolderNeverFilesAMemberOnTheHostsPage() async throws {
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "m1", via: .imported, agent: .claude, core: SessionCore(host: box))
        let overlay = SessionOverlayStore(db: db)
        let peer = Peer(.listed(PeerListing(sessions: [peerRow("m1", directory: "/work/app")])))
        let history = HistoryModel(overlay: overlay, catalog: { AsyncStream { $0.finish() } }, directoryEvidence: { _ in .exists })
        history.readPeer = { _ in peer.reads += 1; return peer.answer }
        history.hostConfiguration = { _ in peer.configuration }
        history.enabledHosts = { [box] in [box] }
        overlay.setProjectArchived(true, key: ProjectKey(host: box, path: "/work/app"))
        history.activate()
        await waitFor { history.readState == .done }
        await show(history, page: .host(box), peer: peer)
        let row = try XCTUnwrap(history.allRows.first { $0.sessionID == "m1" })
        XCTAssertNotNil(row.peer)
        XCTAssertNil(row.project)
        XCTAssertEqual(row.standing, .inTemple, "another Temple's folder doesn't archive it here")
        XCTAssertTrue(row.canResume, "it still opens in that folder")
    }
}
