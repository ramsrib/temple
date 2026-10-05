import XCTest
import CoreServices
import GRDB
@testable import TempleCore
@testable import TempleLocalHost

@MainActor
final class SessionEngineTests: XCTestCase {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/temple-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func claude(_ root: URL, id: String, text: String = "hello") throws -> URL {
        let dir = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        try "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/private/tmp\",\"message\":{\"content\":\"\(text)\"}}".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    private func rollout(_ root: URL, id: String, at: Date, filenameID: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent("sessions/2026/10/02")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-10-02T00-00-00-\(filenameID ?? id).jsonl")
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try "{\"type\":\"session_meta\",\"timestamp\":\"\(format.string(from: at))\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/private/tmp\"}}".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private var started: [SessionEngine] = []
    private var adoptions: [Task<Void, Never>] = []

    override func tearDown() async throws {
        adoptions.forEach { $0.cancel() }; adoptions.removeAll()
        for engine in started { await engine.stop() }
        started.removeAll()
        try await super.tearDown()
    }

    /// Starts the engine and waits for a snapshot that has settled every
    /// member (no `.resolving` left).
    private func start(_ watcher: SessionEngine) async throws -> EngineRecorder {
        started.append(watcher)
        let recorder = EngineRecorder(watcher)
        await watcher.start()
        try await eventually {
            guard let last = recorder.indices.last else { return false }
            return !last.resolutions.values.contains(.resolving)
        }
        return recorder
    }

    /// An engine over bare member rows (no agent, hint or facts yet): the
    /// rows want every field, so the engine authorizes facts for each loaded
    /// member, and the test reads them from the snapshot (nothing persists
    /// them here).
    // Tests here inject every event they need (`reconcileEvent`), with no
    // FSEvents stream: a late live event for a fixture's own fresh file is a
    // member change, which revokes facts and reads again — real, but not
    // what these tests count. The `testLive…` ones use the real stream.
    private func memberEngine(_ source: LocalSessionSource, members: Set<String>) throws -> SessionEngine {
        let db = try TempleDB.inMemory()
        for id in members.sorted() { try db.join(sessionID: id, via: .imported) }
        return SessionEngine(source: source, database: db)
    }

    struct AdoptedRollout: Sendable { let sessionID: String; let filePath: URL }

    /// Adoption is the source's (`HostSessionSource.adopt`); the engine
    /// takes no part in it.
    private func adopt(_ watcher: SessionEngine, projectPath: String, startedAt: Date, window: TimeInterval,
                       completion: @escaping @Sendable (AdoptedRollout?) -> Void) {
        let source = watcher.source
        adoptions.append(Task {
            let result = try? await source.adopt(AdoptionRequest(directory: projectPath, startedAt: startedAt, window: window))
            if case .adopted(let id, let locator)? = result, let url = locator.localURL {
                completion(AdoptedRollout(sessionID: id, filePath: url))
            } else { completion(nil) }
        })
    }

    /// Live FSEvents tests share the machine with the rest of the suite.
    private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(6)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(predicate())
    }

    func testSnapshotsCarryResolutionsAndSummariesForLoadedMembers() async throws {
        let root = try root()
        let file = try claude(root, id: "loaded", text: "Recorded prompt")
        try claude(root, id: "outside")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], monitorChanges: false), members: ["loaded", "missing"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.indices.last?.facts["loaded"]?.summary != nil }
        let snapshot = try XCTUnwrap(watcher.latestSnapshot)
        XCTAssertGreaterThan(snapshot.generation, 0)
        XCTAssertEqual(snapshot.resolutions["loaded"], .loaded(file))
        XCTAssertEqual(snapshot.resolutions["missing"], .confirmedAbsent)
        XCTAssertEqual(Set(snapshot.facts.keys), ["loaded"])
        let facts = try XCTUnwrap(snapshot.facts["loaded"])
        XCTAssertEqual(facts.summary?.cwd, "/private/tmp")
        XCTAssertEqual(facts.summary?.firstPrompt, "Recorded prompt")
        XCTAssertEqual(facts.summary?.locator.localURL, file)
        XCTAssertEqual(facts.locator.localURL, file)
        XCTAssertEqual(facts.agent, .claude)
        XCTAssertNotNil(facts.authorization.incarnation)

        let replay = watcher.snapshots()
        var iterator = replay.makeAsyncIterator()
        let replayed = await iterator.next()
        XCTAssertEqual(replayed, snapshot)
        try FileManager.default.removeItem(at: file)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { recorder.indices.last?.resolutions["loaded"] == .confirmedAbsent }
        XCTAssertNil(recorder.indices.last?.facts["loaded"], "revoked with the file")
    }

    func testOnlyMembersAreParsedAndNonmemberWriteDoesNotPublish() async throws {
        let root = try root()
        let member = try claude(root, id: "member")
        let outside = try claude(root, id: "outside")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: ["member"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 1 }
        XCTAssertEqual(watcher.metrics.factReads, 1)
        let before = recorder.indices.count
        try claude(root, id: "outside", text: "changed")
        watcher.reconcileEvent(path: outside.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(watcher.metrics.factReads, 1)
        XCTAssertEqual(recorder.indices.count, before)
        try claude(root, id: "member", text: "new title")
        watcher.reconcileEvent(path: member.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "new title" }
        XCTAssertEqual(watcher.metrics.factReads, 2)
        XCTAssertEqual(recorder.latest.map(\.id), ["member"])
    }

    func testCommittedJoinLoadsWithoutAnEventAndRepeatedJoinDoesNotReparse() async throws {
        let root = try root()
        let file = try claude(root, id: "existing")
        let db = try TempleDB.inMemory()
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        // No FSEvents: the fixture's own fresh directories would arrive as
        // root events (a coverage reset re-arms enrichment, legitimately).
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.metrics.factReads, 0)
        try db.join(sessionID: "existing", via: .opened, agent: .claude, locator: TranscriptLocator(localURL: file))
        try await eventually { recorder.latest.count == 1 }
        XCTAssertEqual(try db.sessionState("existing")?.transcriptPath, file.path)
        try db.join(sessionID: "existing", via: .opened)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watcher.metrics.factReads, 1)
    }

    /// History's undo of an import: a committed leave takes the session out of
    /// the live index without a filesystem event, and a refused leave (the row
    /// was touched since) changes nothing.
    func testCommittedLeaveDropsTheSessionAndARefusedLeaveKeepsIt() async throws {
        let root = try root()
        let imported = try claude(root, id: "imported")
        let pinned = try claude(root, id: "pinned")
        let db = try TempleDB.inMemory()
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try db.join(sessionID: "imported", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: imported))
        try db.join(sessionID: "pinned", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: pinned))
        try db.setPinned(true, sessionID: "pinned")
        try await eventually { recorder.indices.last?.resolutions.count == 2 && recorder.latest.count == 2 }

        XCTAssertTrue(try db.leave(sessionID: "imported", host: .local))
        try await eventually { Set(recorder.latest.map(\.id)) == ["pinned"] }
        XCTAssertNil(watcher.resolution(for: "imported"))

        XCTAssertFalse(try db.leave(sessionID: "pinned", host: .local))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(recorder.latest.map(\.id)), ["pinned"])
        XCTAssertEqual(Set(watcher.latestSnapshot?.resolutions.keys ?? [:].keys), ["pinned"])
    }

    func testDelayedLeaveAfterReimportKeepsMembershipAndEventRouting() async throws {
        let root = try root()
        let file = try claude(root, id: "reimported")
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "reimported", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: file))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertTrue(try db.leave(sessionID: "reimported", host: .local))
        try db.join(sessionID: "reimported", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: file))
        // Force the callback order: resolution of the new commit, then the
        // delayed callback from the old leave, irrespective of DB delivery:
        // each re-reads the row, which is a member again.
        await watcher.requestResolution("reimported")
        await watcher.reconcileMembership("reimported")
        try claude(root, id: "reimported", text: "after reimport")
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "after reimport" }
        XCTAssertNotNil(try db.sessionState("reimported"))
        XCTAssertEqual(watcher.resolution(for: "reimported"), .loaded(file))
    }

    func testLeaveDatabaseReadFailureKeepsMember() async throws {
        let root = try root()
        let file = try claude(root, id: "kept")
        let queue = try DatabaseQueue()
        let db = try TempleDB(database: queue)
        try db.join(sessionID: "kept", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: file))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try queue.close()
        await watcher.reconcileMembership("kept")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(recorder.latest.map(\.id), ["kept"])
        XCTAssertEqual(watcher.resolution(for: "kept"), .loaded(file))
    }

    func testPrestartJoinWaitsForClaudeCreationAndDeletionKeepsMembership() async throws {
        let root = try root()
        let db = try TempleDB.inMemory()
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        try db.join(sessionID: "later", via: .created, agent: .claude)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "later"), .awaitingCreation)
        let file = try claude(root, id: "later")
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.count == 1 }
        try FileManager.default.removeItem(at: file)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { watcher.resolution(for: "later") == .confirmedAbsent && recorder.latest.isEmpty }
        XCTAssertTrue(recorder.latest.isEmpty)
        XCTAssertNotNil(try db.sessionState("later"))
    }

    func testAliasesAndCombinedFlagsReconcileTheCurrentFile() async throws {
        let root = try root()
        let file = try claude(root, id: "alias")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), members: ["alias"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try claude(root, id: "alias", text: "alias update")
        watcher.reconcileEvent(path: file.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"),
            flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "alias update" }
    }

    func testDirectoryMovedInAndMustScanSubDirsDiscoverMembers() async throws {
        let root = try root()
        let staging = try self.root()
        try claude(staging, id: "moved")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), members: ["moved"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let dir = root.appendingPathComponent("project")
        try FileManager.default.moveItem(at: staging.appendingPathComponent("project"), to: dir)
        watcher.reconcileEvent(path: dir.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { recorder.latest.first?.id == "moved" }
        try claude(root, id: "moved", text: "recovered")
        watcher.reconcileEvent(path: dir.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { recorder.latest.first?.title == "recovered" }
        try FileManager.default.removeItem(at: dir)
        watcher.reconcileEvent(path: dir.path, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved))
        try await eventually { recorder.latest.isEmpty }
    }

    /// ADR-032's one rule decides the engine's completeness too: a member
    /// whose transcript is behind a link where transcripts are listed (here
    /// a linked project folder) is not proven absent, nor is any other
    /// member of that agent. A link where no transcript is listed (Claude
    /// Code's own `subagents/` links) changes nothing.
    func testAnAgentWhoseListingIsNotExhaustiveProvesNoMemberAbsent() async throws {
        let store = try root()
        try claude(store, id: "present")
        let elsewhere = try root()
        try claude(elsewhere, id: "linked")
        let subagents = store.appendingPathComponent("project/present/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: subagents.appendingPathComponent("agent-x.jsonl"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("nothing.jsonl"))
        let plain = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: store)], debounceInterval: 0.02,
                                                        monitorChanges: false), members: ["present", "linked", "absent"])
        var recorder = try await start(plain)
        XCTAssertEqual(plain.resolution(for: "linked"), .confirmedAbsent, "no link in scope: a completed listing")
        XCTAssertEqual(plain.resolution(for: "absent"), .confirmedAbsent)
        recorder.stop()

        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("-linked-project"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("project"))
        let linked = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: store)], debounceInterval: 0.02,
                                                         monitorChanges: false), members: ["present", "linked", "absent"])
        recorder = try await start(linked)
        defer { recorder.stop() }
        guard case .loaded? = linked.resolution(for: "present") else { return XCTFail("present: not loaded") }
        XCTAssertEqual(linked.resolution(for: "linked"), .incomplete)
        XCTAssertEqual(linked.resolution(for: "absent"), .incomplete)
    }

    /// A link appearing where transcripts are listed, after a completed
    /// listing, takes completeness away at once: the source re-lists,
    /// coverage moves on, and a member it had proven absent no longer is.
    func testALinkAppearingInScopeWithdrawsAnAbsence() async throws {
        let store = try root()
        try claude(store, id: "present")
        let elsewhere = try root()
        try claude(elsewhere, id: "linked")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: store)], debounceInterval: 0.02,
                                                          monitorChanges: false), members: ["present", "linked"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "linked"), .confirmedAbsent)
        let link = store.appendingPathComponent("-linked-project")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere.appendingPathComponent("project"))
        watcher.reconcileEvent(path: link.path, flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsSymlink))
        try await eventually { watcher.resolution(for: "linked") == .incomplete }
        // Gone again: the next listing is exhaustive, and the absence returns.
        try FileManager.default.removeItem(at: link)
        watcher.reconcileEvent(path: link.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsSymlink))
        try await eventually { watcher.resolution(for: "linked") == .confirmedAbsent }
    }

    /// Codex: a rollout in a hidden folder under `sessions/` is never listed,
    /// so the listing is not exhaustive and no Codex member is proven absent.
    func testAHiddenFolderUnderCodexSessionsProvesNoMemberAbsent() async throws {
        let base = try root()
        let thread = UUID().uuidString.lowercased()
        let hidden = base.appendingPathComponent("sessions/2026/10/.stash")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try #"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/w","timestamp":"2026-10-01T10:00:00Z"}}"#
            .write(to: hidden.appendingPathComponent("rollout-2026-10-01T10-00-00-\(thread).jsonl"), atomically: true, encoding: .utf8)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: thread, via: .imported, agent: .codex)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: base)], debounceInterval: 0.02,
                                                               monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: thread), .incomplete)
    }

    /// The store root goes (a volume unmounted, a store moved) and FSEvents
    /// delivers a descendant's event before the root's own. A folder or file
    /// gone with its root proves nothing: no member may become absent, and
    /// the agent is no longer completely listed until a full listing works.
    func testAStoreRootGoneBeforeItsEventProvesNothingFromADescendantEvent() async throws {
        for descendant in ["directory", "file"] {
            let parent = try root()
            let store = parent.appendingPathComponent("store")
            let file = try claude(store, id: "member")
            try claude(store, id: "other")
            let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: store)], debounceInterval: 0.02,
                                                              monitorChanges: false), members: ["member", "other"])
            let recorder = try await start(watcher)
            guard case .loaded? = watcher.resolution(for: "member") else { recorder.stop(); return XCTFail("\(descendant): not loaded") }
            try FileManager.default.moveItem(at: store, to: parent.appendingPathComponent("away"))
            if descendant == "directory" {
                watcher.reconcileEvent(path: file.deletingLastPathComponent().path,
                                       flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved))
            } else {
                watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
            }
            // (No fresh request here: one lists the whole store again, which
            // fails on the missing root and would hide the bug.)
            try await Task.sleep(for: .milliseconds(800))
            for id in ["member", "other"] {
                XCTAssertNotEqual(watcher.resolution(for: id), .confirmedAbsent, "\(descendant): \(id)")
            }
            recorder.stop()
        }
    }

    func testMissingRootAndRetargetedSymlinkAreRearmed() async throws {
        let parent = try root()
        let missing = parent.appendingPathComponent("missing")
        let first = try root()
        let second = try root()
        try claude(first, id: "linked", text: "first")
        try claude(second, id: "linked", text: "second")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: missing)], debounceInterval: 0.02, monitorChanges: false), members: ["linked"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        // A root that is not there is a failed listing, not an empty store:
        // it proves nothing absent (ADR-030 archives on that proof).
        XCTAssertEqual(watcher.resolution(for: "linked"), .incomplete)
        try FileManager.default.createSymbolicLink(at: missing, withDestinationURL: first)
        watcher.reconcileEvent(path: missing.path, flags: UInt32(kFSEventStreamEventFlagRootChanged))
        try await eventually { recorder.latest.first?.title == "first" }
        try FileManager.default.removeItem(at: missing)
        try FileManager.default.createSymbolicLink(at: missing, withDestinationURL: second)
        watcher.reconcileEvent(path: missing.path, flags: UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagItemRenamed))
        try await eventually { recorder.latest.first?.title == "second" }
        try claude(second, id: "linked", text: "physical event")
        watcher.reconcileEvent(path: second.appendingPathComponent("project/linked.jsonl").path,
                               flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "physical event" }
    }

    /// ADR-030: a store that is not there proves nothing. With Claude's
    /// store present and empty and Codex's root missing, a Claude member is
    /// proven absent, a Codex member is not, and a member that names no
    /// agent (a legacy row, which either store could hold) is not either.
    /// Each verdict names the membership it is about.
    func testAMissingCodexRootLeavesCodexAndAgentlessMembersUnproven() async throws {
        let claudeRoot = try root()
        let codexBase = try root().appendingPathComponent("missing-codex")
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "claude-member", via: .imported, agent: .claude)
        try db.join(sessionID: "codex-member", via: .imported, agent: .codex)
        try db.join(sessionID: "agentless", via: .imported)
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexBase)],
                                        debounceInterval: 0.02, monitorChanges: false)
        let watcher = SessionEngine(source: source, database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "claude-member"), .confirmedAbsent)
        XCTAssertEqual(watcher.resolution(for: "codex-member"), .incomplete)
        XCTAssertEqual(watcher.resolution(for: "agentless"), .incomplete)
        let incarnation = try XCTUnwrap(db.sessionState("claude-member")?.incarnation)
        XCTAssertEqual(recorder.indices.last?.memberships["claude-member"],
                       MembershipRef(id: "claude-member", host: .local, incarnation: incarnation))

        // The store appears: absence is provable again.
        try FileManager.default.createDirectory(at: codexBase.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        await watcher.requestResolution("codex-member")
        try await eventually { watcher.resolution(for: "codex-member") == .confirmedAbsent }
    }

    func testDroppedEventsRecoverAndFailedEnumerationDoesNotProveAbsence() async throws {
        let root = try root()
        try claude(root, id: "kept")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: ["kept", "unknown"])
        store.failEnumeration = true
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "unknown"), .incomplete)
        store.failEnumeration = false
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { recorder.latest.first?.id == "kept" }
        XCTAssertEqual(watcher.resolution(for: "unknown"), .confirmedAbsent)
    }

    /// The member's (stale) hint lies inside the subtree that is re-listed, so
    /// the subtree reconcile does visit it: with the old bug, that successful
    /// subtree listing certified the whole store and marked it absent, though
    /// the full listing that would find it elsewhere never succeeded. No
    /// further full scan is triggered before the assertion.
    func testSuccessfulSubtreeCannotClearFailedFullEnumeration() async throws {
        let root = try root()
        let outside = try claude(root, id: "outside")
        let project = outside.deletingLastPathComponent()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "missing", via: .opened, agent: .claude,
                    locator: TranscriptLocator(localURL: project.appendingPathComponent("missing.jsonl")))
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        store.failEnumeration = true
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "missing"), .incomplete)
        let scans = store.enumerations
        watcher.reconcileEvent(path: project.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { store.enumerations > scans }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watcher.resolution(for: "missing"), .incomplete,
                       "a subtree listing must not establish absence for the whole store")
        store.failEnumeration = false
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await eventually { watcher.resolution(for: "missing") == .confirmedAbsent }
    }

    func testValidatedPathHintLoadsMismatchedFilenameAndRejectsWrongIdentity() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date(), filenameID: UUID().uuidString.lowercased())
        let db = try TempleDB.inMemory()
        try db.join(sessionID: id, via: .opened, agent: .codex, locator: TranscriptLocator(localURL: file))
        try db.join(sessionID: "wrong", via: .opened, agent: .codex, locator: TranscriptLocator(localURL: file))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.map(\.id) == [id] }
        XCTAssertEqual(try db.sessionState(id)?.transcriptPath, file.path)
        XCTAssertEqual(watcher.resolution(for: "wrong"), .mismatch)
    }

    func testCodexSharedTitlesAreReadInsideAnExplicitEnrichment() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: [id])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 1 }
        let parses = watcher.metrics.factReads
        let date = recorder.latest.first?.updatedAt
        let title = root.appendingPathComponent("session_index.jsonl")
        try "{\"id\":\"\(id)\",\"thread_name\":\"Retitled\"}".write(to: title, atomically: true, encoding: .utf8)
        await watcher.requestResolution(id)
        try await eventually { recorder.latest.first?.title == "Retitled" }
        XCTAssertEqual(recorder.latest.first?.updatedAt, date)
        XCTAssertEqual(recorder.latest.first?.filePath, file)
        try FileManager.default.removeItem(at: title)
        await watcher.requestResolution(id)
        try await eventually { recorder.latest.first?.title == "(no prompt)" }
        XCTAssertGreaterThanOrEqual(watcher.metrics.factReads, parses + 2)
    }

    func testAdoptionCatchUpFindsFileCreatedBeforeRegistrationWithoutPublishingIt() async throws {
        let root = try root()
        let time = Date()
        let id = UUID().uuidString.lowercased()
        try rollout(root, id: id, at: time)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "catch-up adoption")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 0.3) { candidate in
            XCTAssertEqual(candidate?.sessionID, id); decided.fulfill()
        }
        await fulfillment(of: [decided], timeout: 2)
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    func testAdoptionRefusesTwoReadableCandidates() async throws {
        let root = try root()
        let time = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "ambiguous decision")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 0.35) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        await fulfillment(of: [decided], timeout: 2)
    }

    func testStaggeredCandidateInsideWholeWindowRefusesAdoption() async throws {
        let root = try root()
        let time = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "whole window remains ambiguous")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 5) { candidate in
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(time), 5)
            XCTAssertNil(candidate)
            decided.fulfill()
        }
        try await Task.sleep(for: .seconds(2))
        let second = try rollout(root, id: UUID().uuidString.lowercased(), at: time.addingTimeInterval(2))
        watcher.reconcileEvent(path: second.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        await fulfillment(of: [decided], timeout: 5)
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    func testCandidateSeenThenRemovedStillBlocksUniqueAdoption() async throws {
        let root = try root()
        let time = Date()
        let first = try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "previously seen competitor remains ambiguous")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 0.4) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        try await eventually { store.headerReads == 1 }
        try FileManager.default.removeItem(at: first)
        let second = try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        watcher.reconcileEvent(path: second.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        await fulfillment(of: [decided], timeout: 2)
    }

    func testRemovedOnlyCandidateCannotBeAdoptedAtDeadline() async throws {
        let root = try root()
        let time = Date()
        let file = try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "removed candidate cannot bind")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 0.3) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        try await eventually { store.headerReads == 1 }
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [decided], timeout: 2)
    }

    func testOneRolloutCannotSatisfyTwoOverlappingRequests() async throws {
        let root = try root()
        let time = Date()
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "two refused requests")
        decided.expectedFulfillmentCount = 2
        for offset in [0.0, 0.08] {
            adopt(watcher, projectPath: "/private/tmp", startedAt: time.addingTimeInterval(offset), window: 0.3) { candidate in
                XCTAssertNil(candidate); decided.fulfill()
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        let file = try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        await fulfillment(of: [decided], timeout: 2)
    }

    func testIncompleteAdoptionHeaderIsRetriedOnLaterWrite() async throws {
        let root = try root()
        let time = Date()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: time)
        let complete = try Data(contentsOf: file)
        try Data("{\"type\":".utf8).write(to: file)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "completed header")
        adopt(watcher, projectPath: "/private/tmp", startedAt: time, window: 0.35) { candidate in
            XCTAssertEqual(candidate?.sessionID, id); decided.fulfill()
        }
        try await Task.sleep(for: .milliseconds(80))
        try complete.write(to: file)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        await fulfillment(of: [decided], timeout: 2)
        XCTAssertTrue(recorder.latest.isEmpty)
    }

    func testStartupBuffersAFileCreatedAfterEnumeration() async throws {
        let root = try root()
        try claude(root, id: "before")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        // Injected events only: the write lands mid-scan, deterministically.
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: ["before", "during"])
        let file = root.appendingPathComponent("project/during.jsonl")
        store.afterListing = {
            try? #"{"type":"user","sessionId":"during","cwd":"/private/tmp","message":{"content":"during scan"}}"#.write(to: file, atomically: true, encoding: .utf8)
            watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        }
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 2 }
        XCTAssertEqual(watcher.metrics.factReads, 2)
    }

    func testNonmemberCodexWritesAndWALTrafficDoNotParseOrPublish() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let outsideID = UUID().uuidString.lowercased()
        try rollout(root, id: id, at: Date())
        let outside = try rollout(root, id: outsideID, at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        // Injected events only: a late FSEvent for the member's own fresh
        // file is a member change (it revokes and re-reads, legitimately).
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: [id])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 1 }
        let counts = watcher.metrics.factReads
        let publications = recorder.indices.count
        try rollout(root, id: outsideID, at: Date())
        watcher.reconcileEvent(path: outside.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.reconcileEvent(path: root.appendingPathComponent("state_5.sqlite-wal").path,
                               flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watcher.metrics.factReads, counts)
        XCTAssertEqual(recorder.indices.count, publications)
    }

    func testHeaderReaderIgnoresLargeInvalidUTF8TailAndRejectsHeaderPastBound() throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date())
        let header = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0a]) + Data(repeating: 0xff, count: 4 * 1024 * 1024))
        try handle.close()
        XCTAssertEqual(try StoreIO.readFirstLine(file), header)
        let store = CodexSessionStore(root: root)
        XCTAssertEqual(try store.adoptionHeader(at: file)?.id, id)
        // A valid header beginning beyond the cap must never be reached.
        try (Data(repeating: 0x20, count: StoreIO.readWindowBytes) + header + Data([0x0a])).write(to: file)
        XCTAssertThrowsError(try StoreIO.readFirstLine(file))
        XCTAssertThrowsError(try store.adoptionHeader(at: file)?.id)
    }

    func testIncompleteEligibleRolloutBlocksAdoptingReadableOutsider() async throws {
        let root = try root()
        let now = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: now)
        let own = try rollout(root, id: UUID().uuidString.lowercased(), at: now)
        try Data("{\"type\":\"session_meta\"".utf8).write(to: own)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let done = expectation(description: "unresolved competitor refuses adoption")
        adopt(watcher, projectPath: "/private/tmp", startedAt: now, window: 0.15) { result in
            XCTAssertNil(result); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testSharedHintCannotAdvanceAnotherMembersSignatureInEitherOrder() async throws {
        for validFirst in [true, false] {
            let root = try root()
            let valid = validFirst ? "10000000-0000-0000-0000-000000000000" : "f0000000-0000-0000-0000-000000000000"
            let wrong = validFirst ? "f0000000-0000-0000-0000-000000000000" : "10000000-0000-0000-0000-000000000000"
            let file = try rollout(root, id: valid, at: Date())
            let db = try TempleDB.inMemory()
            for id in [valid, wrong] { try db.join(sessionID: id, via: .opened, agent: .codex, locator: TranscriptLocator(localURL: file)) }
            let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
            let recorder = try await start(watcher)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"updated prompt\"}}\n".utf8))
            try handle.close()
            watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
            try await eventually { recorder.latest.first?.title == "updated prompt" }
            XCTAssertEqual(recorder.latest.map(\.id), [valid])
            recorder.stop()
        }
    }

    func testRestoredCreatedClaudeRowIsAbsentAndRuntimeJoinAwaitsCreation() async throws {
        let root = try root()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "restored", via: .created, agent: .claude)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        try db.join(sessionID: "new", via: .created, agent: .claude)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "restored"), .confirmedAbsent)
        XCTAssertEqual(watcher.resolution(for: "new"), .awaitingCreation)
    }

    func testAdoptionReadsOnlyRecentHeadersAndReusesSignaturesAcrossRequests() async throws {
        let root = try root()
        let now = Date()
        for _ in 0..<30 {
            let file = try rollout(root, id: UUID().uuidString.lowercased(), at: now.addingTimeInterval(-3600))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: file.path)
        }
        let id = UUID().uuidString.lowercased()
        try rollout(root, id: id, at: now)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let first = expectation(description: "deadline adoption")
        adopt(watcher, projectPath: "/private/tmp", startedAt: now, window: 0.2) { result in
            XCTAssertEqual(result?.sessionID, id); first.fulfill()
        }
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(store.headerReads, 1)
        let second = expectation(description: "same cached candidate already claimed")
        adopt(watcher, projectPath: "/private/tmp", startedAt: now, window: 0.2) { result in
            XCTAssertNil(result); second.fulfill()
        }
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(store.headerReads, 1)
    }

    func testLiveStartupWatchPrecedesEnumeration() async throws {
        let root = try root()
        try claude(root, id: "before")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02), members: ["before", "during"])
        let file = root.appendingPathComponent("project/during.jsonl")
        store.afterListing = {
            try? #"{"type":"user","sessionId":"during","cwd":"/private/tmp","message":{"content":"during scan"}}"#.write(to: file, atomically: true, encoding: .utf8)
            // Hold enumeration open long enough for the live stream to record
            // the write. A stream armed after enumeration misses this event.
            Thread.sleep(forTimeInterval: 0.15)
        }
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try XCTSkipIf(!watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        try await eventually { recorder.latest.count == 2 }
    }

    func testLiveMissingAndRetargetedRoots() async throws {
        let base = try root()
        let logical = base.appendingPathComponent("logical")
        let watcher = try memberEngine(LocalSessionSource(stores: [ClaudeSessionStore(root: logical)], debounceInterval: 0.02), members: ["member"])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try XCTSkipIf(!watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        try claude(logical, id: "member", text: "created root")
        try await eventually { recorder.latest.first?.title == "created root" }
        try FileManager.default.removeItem(at: logical)
        let physical = base.appendingPathComponent("physical")
        try claude(physical, id: "member", text: "retargeted")
        try FileManager.default.createSymbolicLink(at: logical, withDestinationURL: physical)
        try await eventually { recorder.latest.first?.title == "retargeted" }
        try claude(physical, id: "member", text: "physical modification")
        try await eventually { recorder.latest.first?.title == "physical modification" }
    }

    func testSymlinkedCodexSessionsMapsPhysicalEvents() async throws { try await exerciseSymlinkedCodex(inject: true) }
    func testLiveSymlinkedCodexSessionsIsWatched() async throws { try await exerciseSymlinkedCodex(inject: false) }
    private func exerciseSymlinkedCodex(inject: Bool) async throws {
        let base = try root()
        let physical = try root()
        let id = UUID().uuidString.lowercased()
        let physicalFile = try rollout(physical, id: id, at: Date())
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("sessions"), withDestinationURL: physical.appendingPathComponent("sessions"))
        let watcher = try memberEngine(LocalSessionSource(stores: [CodexSessionStore(root: base)], debounceInterval: 0.02), members: [id])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 1 }
        XCTAssertEqual(recorder.latest.first?.filePath.path, base.appendingPathComponent("sessions/2026/10/02/" + physicalFile.lastPathComponent).path)
        let initial = recorder.latest.first?.createdAt
        try XCTSkipIf(!inject && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        try rollout(physical, id: id, at: Date().addingTimeInterval(1))
        if inject { watcher.reconcileEvent(path: physicalFile.path, flags: UInt32(kFSEventStreamEventFlagItemModified)) }
        try await eventually { recorder.latest.first?.createdAt != nil && recorder.latest.first?.createdAt != initial }
    }

    func testReadOnlyWatcherLoadsMembersWithoutUpdatingHints() async throws {
        let root = try root()
        let file = try claude(root, id: "member")
        let path = root.appendingPathComponent("state.sqlite")
        let writable = try TempleDB(path: path)
        try writable.join(sessionID: "member", via: .opened)
        let db = try TempleDB(readOnlyPath: path)
        XCTAssertTrue(db.isReadOnly)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "member"), .loaded(file))
        XCTAssertTrue(recorder.indices.allSatisfy { $0.facts.isEmpty }, "a read-only database authorizes nothing")
        XCTAssertEqual(watcher.metrics.factReads, 0)
        XCTAssertNil(try db.sessionState("member")?.transcriptPath)
    }

    func testSnapshotReadsDoNotWaitForBackgroundHeaderIO() async throws {
        let root = try root()
        try rollout(root, id: UUID().uuidString.lowercased(), at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let entered = expectation(description: "header IO in flight")
        let gate = DispatchSemaphore(value: 0)
        store.headerObserver = {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 1)
        }
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: ["pruned"])
        let recorder = try await start(watcher)
        defer { recorder.stop(); gate.signal() }
        adopt(watcher, projectPath: "/private/tmp", startedAt: Date(), window: 1) { _ in }
        await fulfillment(of: [entered], timeout: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }
        let began = Date()
        XCTAssertEqual(watcher.resolution(for: "pruned"), .confirmedAbsent)
        XCTAssertNotNil(watcher.latestSnapshot)
        _ = watcher.isMonitoring
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.05)
    }

    func testAdoptionCacheOverflowRefusesInsteadOfLosingCompetitors() async throws {
        let root = try root()
        let now = Date()
        try rollout(root, id: "00000000-0000-0000-0000-000000000000", at: now)
        try rollout(root, id: "ffffffff-ffff-ffff-ffff-ffffffffffff", at: now)
        let directory = root.appendingPathComponent("sessions/2026/10/02")
        for number in 0..<520 {
            let file = directory.appendingPathComponent("rollout-2026-10-02T00-00-00-10000000-\(number).jsonl")
            try #"{"type":"other"}"#.write(to: file, atomically: true, encoding: .utf8)
        }
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let refused = expectation(description: "neither competitor may be evicted before decision")
        adopt(watcher, projectPath: "/private/tmp", startedAt: now, window: 1) { candidate in
            XCTAssertNil(candidate); refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 3)
        XCTAssertLessThanOrEqual(store.headerReads, 512)
    }

    func testExternalProcessJoinsBecomeVisibleAtNextLaunch() async throws {
        let root = try root()
        let file = try claude(root, id: "external")
        let path = root.appendingPathComponent("state.sqlite")
        let db = try TempleDB(path: path)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        let otherProcess = try TempleDB(path: path)
        try otherProcess.join(sessionID: "external", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: file))
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(recorder.latest.isEmpty)
        XCTAssertNil(watcher.resolution(for: "external"))
        await recorder.stopNow()
        XCTAssertNil(watcher.latestSnapshot)
        let next = try await start(watcher)
        defer { next.stop() }
        try await eventually { next.latest.map(\.id) == ["external"] }
    }

    func testAdoptionFilenameTimestampAdmitsOldMtimeCompetitor() async throws {
        let root = try root()
        let now = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: now)
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let renamed = file.deletingLastPathComponent().appendingPathComponent("rollout-\(formatter.string(from: now))-\(id).jsonl")
        try FileManager.default.moveItem(at: file, to: renamed)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: renamed.path)
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false))
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let refused = expectation(description: "recent filename is eligible despite older mtime")
        adopt(watcher, projectPath: "/private/tmp", startedAt: now, window: 1) { candidate in
            XCTAssertNil(candidate); refused.fulfill()
        }
        await fulfillment(of: [refused], timeout: 2)
    }

    func testCodexFilenameParserMatchesOrdinaryAndRevertedUpstreamForms() throws {
        let store = CodexSessionStore(root: try root())
        let thread = "019ff1a2-b3c4-7d5e-8f60-112233445566"
        let rollout = "019ff1a2-b3c4-7d5e-8f60-667788990011"
        for suffix in [thread, thread + "_" + rollout] {
            let file = URL(fileURLWithPath: "/tmp/rollout-2026-08-11T18-42-07-\(suffix).jsonl")
            XCTAssertEqual(store.filenameID(at: file), thread)
        }
        for name in [
            "rollout-fixture-\(thread).jsonl",
            "rollout-2026-02-30T18-42-07-\(thread).jsonl",
            "rollout-2026-08-11T24-42-07-\(thread).jsonl",
            "rollout-2026-08-11T18-42-07-\(thread)_invalid.jsonl",
            "rollout-2026-08-11T18-42-07-\(thread)_.jsonl",
            "rollout-2026-08-11T18-42-07-\(thread)_\(rollout)_\(rollout).jsonl"
        ] { XCTAssertNil(store.filenameID(at: URL(fileURLWithPath: "/tmp/" + name)), name) }
        XCTAssertEqual(store.filenameID(at: URL(fileURLWithPath: "/tmp/rollout-2024-02-29T23-59-59-\(thread).jsonl")), thread)
    }

    func testCodexThreadRevertSelectsNewestFilenameThenRolloutIDDespiteMtimeAndOldHint() async throws {
        let root = try root()
        let thread = UUID().uuidString.lowercased()
        let original = try rollout(root, id: thread, at: Date())
        let data = try Data(contentsOf: original)
        let directory = original.deletingLastPathComponent()
        let olderRevert = directory.appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_10000000-0000-0000-0000-000000000000.jsonl")
        let selected = directory.appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_20000000-0000-0000-0000-000000000000.jsonl")
        try data.write(to: olderRevert); try data.write(to: selected)
        // Upstream resume ranks filename timestamps and rollout IDs, not mtime.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1000)], ofItemAtPath: original.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: selected.path)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: thread, via: .opened, agent: .codex, locator: TranscriptLocator(localURL: original),
                    core: SessionCore(directory: "/w", title: "Complete", lastActiveAt: Date()))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        // The consumer persists what the engine authorizes: here, the hint.
        let committer = FactCommitter(database: db)
        let stream = watcher.snapshots()
        let consumer = Task { for await snapshot in stream { committer.receive(snapshot.facts) } }
        defer { consumer.cancel() }
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: thread), .loaded(selected))
        XCTAssertEqual(watcher.metrics.factReads, 0, "a complete row: identity only")
        try await eventually { (try? db.sessionState(thread)?.transcriptPath) == selected.path }
        let newest = directory.appendingPathComponent("rollout-2026-10-02T00-00-02-\(thread)_30000000-0000-0000-0000-000000000000.jsonl")
        try data.write(to: newest)
        watcher.reconcileEvent(path: newest.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await eventually { watcher.resolution(for: thread) == .loaded(newest) }
        try await eventually { (try? db.sessionState(thread)?.transcriptPath) == newest.path }
        try FileManager.default.removeItem(at: newest)
        watcher.reconcileEvent(path: newest.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { watcher.resolution(for: thread) == .loaded(selected) }
        XCTAssertFalse(recorder.indices.contains { $0.resolutions[thread] == .loaded(olderRevert) || $0.resolutions[thread] == .loaded(original) })
        for file in [original, olderRevert, selected] { try FileManager.default.removeItem(at: file) }
        watcher.reconcileEvent(path: selected.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { watcher.resolution(for: thread) == .confirmedAbsent }
    }

    func testUnreadableSelectedRevertDoesNotSilentlyLoadOlderRollout() async throws {
        let root = try root()
        let thread = UUID().uuidString.lowercased()
        let original = try rollout(root, id: thread, at: Date())
        let selected = original.deletingLastPathComponent().appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_10000000-0000-0000-0000-000000000000.jsonl")
        try Data("{".utf8).write(to: selected)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: thread, via: .opened, agent: .codex, locator: TranscriptLocator(localURL: original))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: thread), .incomplete)
        XCTAssertTrue(recorder.latest.isEmpty)
        try Data(contentsOf: original).write(to: selected)
        watcher.reconcileEvent(path: selected.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.filePath == selected }
    }

    func testUnhintedMemberDoesNotSearchPayloadIDsAndLoadsOnMatchingFilenameCreation() async throws {
        let root = try root()
        let member = UUID().uuidString.lowercased()
        let outside = try rollout(root, id: member, at: Date(), filenameID: UUID().uuidString.lowercased())
        let db = try TempleDB.inMemory()
        try db.join(sessionID: member, via: .opened, agent: .codex)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: member), .confirmedAbsent)
        XCTAssertEqual(store.headerReads, 0)
        XCTAssertEqual(watcher.metrics.factReads, 0)
        XCTAssertEqual(watcher.metrics.reads, 0, "the payload id of another file is never searched")
        let matching = try rollout(root, id: member, at: Date())
        watcher.reconcileEvent(path: matching.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await eventually { recorder.latest.first?.filePath == matching }
        XCTAssertEqual(watcher.metrics.factReads, 1)
        XCTAssertEqual(watcher.metrics.reads, 1)
        _ = outside
        XCTAssertEqual(store.headerReads, 0)
    }

    func testCodexFailedEnumerationKeepsMissingMemberIncompleteUntilRecovery() async throws {
        let root = try root()
        // An empty store that is there (a missing one would stay incomplete, ADR-030).
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let member = UUID().uuidString.lowercased()
        let store = EngineCountingStore(CodexSessionStore(root: root))
        store.failEnumeration = true
        let watcher = try memberEngine(LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), members: [member])
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: member), .incomplete)
        store.failEnumeration = false
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        try await eventually { watcher.resolution(for: member) == .confirmedAbsent }
        XCTAssertEqual(store.headerReads, 0)
    }

    func testNonmemberRolloutWritesPerformZeroHeaderParsesSQLAndStatePublications() async throws {
        let root = try root()
        let sql = EngineSQLCounter()
        var configuration = Configuration()
        configuration.prepareDatabase { database in database.trace { _ in sql.increment() } }
        let db = try TempleDB(database: DatabaseQueue(configuration: configuration))
        // Pin the real-store problem: many durable members with pruned logs.
        for _ in 0..<173 { try db.join(sessionID: UUID().uuidString.lowercased(), via: .opened) }
        let member = UUID().uuidString.lowercased()
        try rollout(root, id: member, at: Date())
        try db.join(sessionID: member, via: .opened, agent: .codex)
        var outside: [URL] = []
        for _ in 0..<80 {
            let file = try rollout(root, id: UUID().uuidString.lowercased(), at: Date(timeIntervalSince1970: 1000))
            let renamed = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: "2026-10-02", with: "2000-01-01"))
            try FileManager.default.moveItem(at: file, to: renamed)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: renamed.path)
            outside.append(renamed)
        }
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(store.headerReads, 0, "Startup must never scan outside headers")
        for adopting in [false, true] {
            if adopting {
                adopt(watcher, projectPath: "/elsewhere", startedAt: Date(), window: 2) { _ in }
                try await Task.sleep(for: .milliseconds(100))
            }
            sql.reset()
            let parses = watcher.metrics.factReads
            let headers = store.headerReads
            let publications = recorder.indices.count
            let listings = store.enumerations
            for file in outside {
                // Rewrite real content, preserving an ineligible mtime before
                // delivery. Both the ordinary and pending-adoption paths run.
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
                watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
            }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(store.headerReads - headers, 0)
            XCTAssertEqual(watcher.metrics.factReads, parses)
            XCTAssertEqual(sql.count, 0, "No SQL reads or writes for nonmember rollouts")
            XCTAssertEqual(store.enumerations, listings)
            XCTAssertEqual(recorder.indices.count, publications)
        }
    }


    func testCommittedHintSelectsANewRevertBeforeItsFilesystemEvent() async throws {
        let root = try root()
        let thread = UUID().uuidString.lowercased()
        let original = try rollout(root, id: thread, at: Date())
        let db = try TempleDB.inMemory()
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionEngine(source: LocalSessionSource(stores: [store], debounceInterval: 0.02, monitorChanges: false), database: db)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let listings = store.enumerations
        let reverted = original.deletingLastPathComponent().appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_10000000-0000-0000-0000-000000000000.jsonl")
        try Data(contentsOf: original).write(to: reverted)
        try db.join(sessionID: thread, via: .created, agent: .codex, locator: TranscriptLocator(localURL: reverted))
        try await eventually { recorder.latest.first?.filePath == reverted }
        XCTAssertEqual(store.enumerations, listings)
        XCTAssertEqual(watcher.metrics.factReads, 1)
        XCTAssertFalse(recorder.indices.contains { $0.resolutions[thread] == .loaded(original) })
        XCTAssertEqual(store.headerReads, 0)
    }

    func testOldJSONAndDatabaseMigrationPreserveMembershipAndProvenance() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/session-state-v8.json")
        let old = try Data(contentsOf: fixture)
        let state = try JSONDecoder().decode(SessionState.self, from: old)
        XCTAssertNil(state.agent); XCTAssertNil(state.transcriptPath); XCTAssertTrue(state.pinned)
        let root = try root()
        let path = root.appendingPathComponent("temple.sqlite")
        do {
            let db = try TempleDB(path: path)
            try db.join(sessionID: "legacy", via: .opened)
            try db.setPinned(true, sessionID: "legacy")
        }
        let oldDB = try DatabaseQueue(path: path.path)
        try oldDB.write { db in
            try db.execute(sql: "ALTER TABLE session_state DROP COLUMN agent")
            try db.execute(sql: "ALTER TABLE session_state DROP COLUMN transcript_path")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9-session-transcript'")
        }
        let upgraded = try TempleDB(path: path)
        let row = try XCTUnwrap(upgraded.sessionState("legacy"))
        XCTAssertTrue(row.pinned); XCTAssertEqual(row.joinedVia, .opened)
        XCTAssertNil(row.agent); XCTAssertNil(row.transcriptPath)
        try upgraded.join(sessionID: "legacy", via: .imported, agent: .claude, locator: TranscriptLocator(localURL: URL(fileURLWithPath: "/tmp/legacy.jsonl")))
        XCTAssertEqual(try upgraded.sessionState("legacy")?.joinedVia, .opened)
        XCTAssertEqual(try upgraded.sessionState("legacy")?.agent, .claude)
    }


}

@MainActor
private final class EngineRecorder {
    var indices: [EngineSnapshot] = []
    /// The parsed facts the latest snapshot authorizes (nothing persists them
    /// in these tests, so they stay while the row wants them).
    var latest: [TranscriptSummary] { indices.last?.allSessions ?? [] }
    private let watcher: SessionEngine
    private var task: Task<Void, Never>?
    init(_ watcher: SessionEngine) {
        self.watcher = watcher
        let stream = watcher.snapshots()
        task = Task { [weak self] in
            for await index in stream { self?.indices.append(index) }
        }
    }
    func stop() { task?.cancel(); let watcher = watcher; Task { await watcher.stop() } }
    func stopNow() async { task?.cancel(); await watcher.stop() }
}

private final class EngineCountingStore: IncrementalSessionStore, @unchecked Sendable {
    private let inner: any IncrementalSessionStore
    var afterListing: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var fail = false
    private var headerCount = 0
    private var listingCount = 0
    var enumerations: Int { lock.lock(); defer { lock.unlock() }; return listingCount }
    var headerObserver: (@Sendable () -> Void)?
    var headerReads: Int { lock.lock(); defer { lock.unlock() }; return headerCount }
    var parses: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    var failEnumeration: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); fail = newValue; lock.unlock() }
    }
    init(_ inner: any IncrementalSessionStore) { self.inner = inner }
    var agent: Agent { inner.agent }
    var watchedURLs: [URL] { inner.watchedURLs }
    var sharedFactURLs: [URL] { inner.sharedFactURLs }
    func loadSummaries() -> [TranscriptSummary] { XCTFail("engine must never load the full store"); return [] }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] {
        lock.lock(); listingCount += 1; lock.unlock()
        if failEnumeration { throw CocoaError(.fileReadNoPermission) }
        let listed = try inner.enumerateSessionFiles()
        let callback = afterListing; afterListing = nil; callback?()
        return listed
    }
    func enumerateSessionFilesAudited() throws -> (files: [URL], exhaustive: Bool) {
        lock.lock(); listingCount += 1; lock.unlock()
        if failEnumeration { throw CocoaError(.fileReadNoPermission) }
        let listed = try inner.enumerateSessionFilesAudited()
        let callback = afterListing; afterListing = nil; callback?()
        return listed
    }
    func inAuditScope(_ path: String) -> Bool { inner.inAuditScope(path) }
    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        lock.lock(); listingCount += 1; lock.unlock()
        return try inner.enumerateSessionFiles(in: subtree)
    }
    func rootAvailable() -> Bool { inner.rootAvailable() }
    func acceptsTranscript(_ url: URL) -> Bool { inner.acceptsTranscript(url) }
    func filenameID(at url: URL) -> String? { inner.filenameID(at: url) }
    func rolloutSelectionKey(at url: URL) -> String? { inner.rolloutSelectionKey(at: url) }
    func sharedRevision() -> UInt64? { inner.sharedRevision() }
    func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?) { inner.sharedFactsSnapshot() }
    var sharedTransfers: Int { inner.sharedTransfers }
    func adoptionHeader(at url: URL) throws -> AdoptionCandidate? {
        lock.lock(); headerCount += 1; lock.unlock()
        headerObserver?()
        return try inner.adoptionHeader(at: url)
    }
    func loadSummary(at url: URL) -> TranscriptSummary? {
        lock.lock(); counts[url.deletingPathExtension().lastPathComponent, default: 0] += 1; lock.unlock()
        return inner.loadSummary(at: url)
    }
}

private final class EngineSQLCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}
