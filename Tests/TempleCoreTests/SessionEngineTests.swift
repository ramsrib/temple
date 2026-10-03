import XCTest
import CoreServices
import GRDB
@testable import TempleCore

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
        try "{\"type\":\"user\",\"cwd\":\"/private/tmp\",\"message\":{\"content\":\"\(text)\"}}".write(to: file, atomically: true, encoding: .utf8)
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

    private func start(_ watcher: SessionWatcher) async throws -> EngineRecorder {
        let recorder = EngineRecorder(watcher)
        try await eventually { !recorder.indices.isEmpty }
        return recorder
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(predicate())
    }

    func testSnapshotsCarryResolutionsAndSummariesForLoadedMembers() async throws {
        let root = try root()
        let file = try claude(root, id: "loaded", text: "Recorded prompt")
        try claude(root, id: "outside")
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], members: ["loaded", "missing"])
        let updates = watcher.snapshots()
        var snapshots: [EngineSnapshot] = []
        let task = Task { for await snapshot in updates { snapshots.append(snapshot) } }
        let recorder = try await start(watcher)
        defer { task.cancel(); recorder.stop() }
        try await eventually { snapshots.last?.summaries["loaded"] != nil }
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertGreaterThan(snapshot.generation, 0)
        XCTAssertEqual(snapshot.resolutions["loaded"], .loaded(file))
        XCTAssertEqual(snapshot.resolutions["missing"], .confirmedAbsent)
        XCTAssertEqual(Set(snapshot.summaries.keys), ["loaded"])
        XCTAssertEqual(snapshot.summaries["loaded"]?.cwd, "/private/tmp")
        XCTAssertEqual(snapshot.summaries["loaded"]?.firstPrompt, "Recorded prompt")
        XCTAssertEqual(snapshot.summaries["loaded"]?.locator.localURL, file)
        XCTAssertEqual(snapshot.summaries["loaded"]?.modifiedAt, recorder.latest.first?.updatedAt)

        let replay = watcher.snapshots()
        var iterator = replay.makeAsyncIterator()
        let replayed = await iterator.next()
        XCTAssertEqual(replayed, snapshot)
        try FileManager.default.removeItem(at: file)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { snapshots.last?.resolutions["loaded"] == .confirmedAbsent }
        XCTAssertNil(snapshots.last?.summaries["loaded"])
    }

    func testOnlyMembersAreParsedAndNonmemberWriteDoesNotPublish() async throws {
        let root = try root()
        let member = try claude(root, id: "member")
        let outside = try claude(root, id: "outside")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: ["member"], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(store.parses, ["member": 1])
        let before = recorder.indices.count
        try claude(root, id: "outside", text: "changed")
        watcher.reconcileEvent(path: outside.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(store.parses, ["member": 1])
        XCTAssertEqual(recorder.indices.count, before)
        try claude(root, id: "member", text: "new title")
        watcher.reconcileEvent(path: member.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "new title" }
        XCTAssertEqual(store.parses["member"], 2)
    }

    func testCommittedJoinLoadsWithoutAnEventAndRepeatedJoinDoesNotReparse() async throws {
        let root = try root()
        let file = try claude(root, id: "existing")
        let db = try TempleDB.inMemory()
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertTrue(store.parses.isEmpty)
        try db.join(sessionID: "existing", via: .opened, agent: .claude, transcriptPath: file)
        try await eventually { recorder.latest.count == 1 }
        XCTAssertEqual(try db.sessionState("existing")?.transcriptPath, file.path)
        try db.join(sessionID: "existing", via: .opened)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.parses["existing"], 1)
    }

    /// History's undo of an import: a committed leave takes the session out of
    /// the live index without a filesystem event, and a refused leave (the row
    /// was touched since) changes nothing.
    func testCommittedLeaveDropsTheSessionAndARefusedLeaveKeepsIt() async throws {
        let root = try root()
        let imported = try claude(root, id: "imported")
        let pinned = try claude(root, id: "pinned")
        let db = try TempleDB.inMemory()
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try db.join(sessionID: "imported", via: .imported, agent: .claude, transcriptPath: imported)
        try db.join(sessionID: "pinned", via: .imported, agent: .claude, transcriptPath: pinned)
        try db.setPinned(true, sessionID: "pinned")
        try await eventually { recorder.latest.count == 2 }

        XCTAssertTrue(try db.leave(sessionID: "imported"))
        try await eventually { Set(recorder.latest.map(\.id)) == ["pinned"] }
        XCTAssertNil(watcher.resolution(for: "imported"))

        XCTAssertFalse(try db.leave(sessionID: "pinned"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(Set(recorder.latest.map(\.id)), ["pinned"])
    }

    func testDelayedLeaveAfterReimportKeepsMembershipAndEventRouting() async throws {
        let root = try root()
        let file = try claude(root, id: "reimported")
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "reimported", via: .imported, agent: .claude, transcriptPath: file)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertTrue(try db.leave(sessionID: "reimported"))
        try db.join(sessionID: "reimported", via: .imported, agent: .claude, transcriptPath: file)
        // Force the callback order: resolution of the new commit, then the
        // delayed invalidation from the old leave, irrespective of DB delivery.
        watcher.requestResolution("reimported")
        watcher.forgetMember("reimported")
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
        try db.join(sessionID: "kept", via: .imported, agent: .claude, transcriptPath: file)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try queue.close()
        watcher.forgetMember("kept")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(recorder.latest.map(\.id), ["kept"])
        XCTAssertEqual(watcher.resolution(for: "kept"), .loaded(file))
    }

    func testPrestartJoinWaitsForClaudeCreationAndDeletionKeepsMembership() async throws {
        let root = try root()
        let db = try TempleDB.inMemory()
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
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
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], members: ["alias"], debounceInterval: 0.02)
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
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], members: ["moved"], debounceInterval: 0.02)
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

    func testMissingRootAndRetargetedSymlinkAreRearmed() async throws {
        let parent = try root()
        let missing = parent.appendingPathComponent("missing")
        let first = try root()
        let second = try root()
        try claude(first, id: "linked", text: "first")
        try claude(second, id: "linked", text: "second")
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: missing)], members: ["linked"], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "linked"), .confirmedAbsent)
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

    func testDroppedEventsRecoverAndFailedEnumerationDoesNotProveAbsence() async throws {
        let root = try root()
        try claude(root, id: "kept")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: ["kept", "unknown"], debounceInterval: 0.02)
        store.failEnumeration = true
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "unknown"), .resolving)
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
                    transcriptPath: project.appendingPathComponent("missing.jsonl"))
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        store.failEnumeration = true
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: "missing"), .resolving)
        let scans = store.enumerations
        watcher.reconcileEvent(path: project.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { store.enumerations > scans }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watcher.resolution(for: "missing"), .resolving,
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
        try db.join(sessionID: id, via: .opened, agent: .codex, transcriptPath: file)
        try db.join(sessionID: "wrong", via: .opened, agent: .codex, transcriptPath: file)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.map(\.id) == [id] }
        XCTAssertEqual(try db.sessionState(id)?.transcriptPath, file.path)
        XCTAssertEqual(watcher.resolution(for: "wrong"), .unreadable)
    }

    func testCodexSharedTitlesUpdateWithoutRolloutModification() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: [id], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let parses = store.parses
        let date = recorder.latest.first?.updatedAt
        let title = root.appendingPathComponent("session_index.jsonl")
        try "{\"id\":\"\(id)\",\"thread_name\":\"Retitled\"}".write(to: title, atomically: true, encoding: .utf8)
        watcher.reconcileEvent(path: title.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await eventually { recorder.latest.first?.title == "Retitled" }
        XCTAssertEqual(recorder.latest.first?.updatedAt, date)
        XCTAssertEqual(recorder.latest.first?.filePath, file)
        try FileManager.default.removeItem(at: title)
        watcher.reconcileEvent(path: title.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { recorder.latest.first?.title == "(no prompt)" }
        XCTAssertEqual(store.parses, parses)
    }

    func testAdoptionCatchUpFindsFileCreatedBeforeRegistrationWithoutPublishingIt() async throws {
        let root = try root()
        let time = Date()
        let id = UUID().uuidString.lowercased()
        try rollout(root, id: id, at: time)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "catch-up adoption")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.3) { candidate in
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
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "ambiguous decision")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.35) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        await fulfillment(of: [decided], timeout: 2)
    }

    func testStaggeredCandidateInsideWholeWindowRefusesAdoption() async throws {
        let root = try root()
        let time = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "whole window remains ambiguous")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 5) { candidate in
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
        let watcher = SessionWatcher(stores: [store], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "previously seen competitor remains ambiguous")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.4) { candidate in
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
        let watcher = SessionWatcher(stores: [store], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "removed candidate cannot bind")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.3) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        try await eventually { store.headerReads == 1 }
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [decided], timeout: 2)
    }

    func testOneRolloutCannotSatisfyTwoOverlappingRequests() async throws {
        let root = try root()
        let time = Date()
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "two refused requests")
        decided.expectedFulfillmentCount = 2
        for offset in [0.0, 0.08] {
            watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time.addingTimeInterval(offset), window: 0.3) { candidate in
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
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "completed header")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.35) { candidate in
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
        let watcher = SessionWatcher(stores: [store], members: ["before", "during"], debounceInterval: 0.02)
        let file = root.appendingPathComponent("project/during.jsonl")
        store.afterListing = {
            try? #"{"type":"user","cwd":"/private/tmp","message":{"content":"during scan"}}"#.write(to: file, atomically: true, encoding: .utf8)
            watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        }
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { recorder.latest.count == 2 }
        XCTAssertEqual(store.parses, ["before": 1, "during": 1])
    }

    func testNonmemberCodexWritesAndWALTrafficDoNotParseOrPublish() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let outsideID = UUID().uuidString.lowercased()
        try rollout(root, id: id, at: Date())
        let outside = try rollout(root, id: outsideID, at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: [id], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let counts = store.parses
        let publications = recorder.indices.count
        try rollout(root, id: outsideID, at: Date())
        watcher.reconcileEvent(path: outside.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        watcher.reconcileEvent(path: root.appendingPathComponent("state_5.sqlite-wal").path,
                               flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.parses, counts)
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
        XCTAssertEqual(store.metadataHeader(at: file)?.sessionID, id)
        XCTAssertEqual(try store.adoptionHeader(at: file)?.sessionID, id)
        // A valid header beginning beyond the cap must never be reached.
        try (Data(repeating: 0x20, count: StoreIO.readWindowBytes) + header + Data([0x0a])).write(to: file)
        XCTAssertThrowsError(try StoreIO.readFirstLine(file))
        XCTAssertNil(store.metadataHeader(at: file))
        XCTAssertThrowsError(try store.adoptionHeader(at: file)?.sessionID)
    }

    func testIncompleteEligibleRolloutBlocksAdoptingReadableOutsider() async throws {
        let root = try root()
        let now = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: now)
        let own = try rollout(root, id: UUID().uuidString.lowercased(), at: now)
        try Data("{\"type\":\"session_meta\"".utf8).write(to: own)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let done = expectation(description: "unresolved competitor refuses adoption")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 0.15) { result in
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
            for id in [valid, wrong] { try db.join(sessionID: id, via: .opened, agent: .codex, transcriptPath: file) }
            let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], database: db,
                debounceInterval: 0.02)
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

    func testAdoptionTimersAreCancelledOnStopAndRestart() async throws {
        for restart in [false, true] {
            let root = try root()
            let now = Date()
            let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
            let recorder = try await start(watcher)
            let forbidden = expectation(description: "old generation never decides")
            forbidden.isInverted = true
            watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 0.2) { _ in forbidden.fulfill() }
            recorder.stop()
            var next: EngineRecorder?
            if restart { next = try await start(watcher) }
            try rollout(root, id: UUID().uuidString.lowercased(), at: now)
            await fulfillment(of: [forbidden], timeout: 0.4)
            next?.stop()
        }
    }

    func testRestoredCreatedClaudeRowIsAbsentAndRuntimeJoinAwaitsCreation() async throws {
        let root = try root()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "restored", via: .created, agent: .claude)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
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
        let watcher = SessionWatcher(stores: [store], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let first = expectation(description: "deadline adoption")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 0.2) { result in
            XCTAssertEqual(result?.sessionID, id); first.fulfill()
        }
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(store.headerReads, 1)
        let second = expectation(description: "same cached candidate already claimed")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 0.2) { result in
            XCTAssertNil(result); second.fulfill()
        }
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(store.headerReads, 1)
    }

    func testLiveStartupWatchPrecedesEnumeration() async throws {
        let root = try root()
        try claude(root, id: "before")
        let store = EngineCountingStore(ClaudeSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: ["before", "during"], debounceInterval: 0.02)
        let file = root.appendingPathComponent("project/during.jsonl")
        store.afterListing = {
            try? #"{"type":"user","cwd":"/private/tmp","message":{"content":"during scan"}}"#.write(to: file, atomically: true, encoding: .utf8)
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
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: logical)], members: ["member"], debounceInterval: 0.02)
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
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: base)], members: [id], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(recorder.latest.first?.filePath.path, base.appendingPathComponent("sessions/2026/10/02/" + physicalFile.lastPathComponent).path)
        try XCTSkipIf(!inject && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        try rollout(physical, id: id, at: Date().addingTimeInterval(1))
        if inject { watcher.reconcileEvent(path: physicalFile.path, flags: UInt32(kFSEventStreamEventFlagItemModified)) }
        try await eventually { recorder.latest.first?.createdAt != nil && recorder.latest.first?.createdAt != recorder.indices.first?.allSessions.first?.createdAt }
    }

    func testReadOnlyWatcherLoadsMembersWithoutUpdatingHints() async throws {
        let root = try root()
        let file = try claude(root, id: "member")
        let path = root.appendingPathComponent("state.sqlite")
        let writable = try TempleDB(path: path)
        try writable.join(sessionID: "member", via: .opened)
        let db = try TempleDB(readOnlyPath: path)
        XCTAssertTrue(db.isReadOnly)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(recorder.latest.first?.filePath, file)
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
        let watcher = SessionWatcher(stores: [store], members: ["pruned"],
            debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop(); gate.signal() }
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: Date(), window: 1) { _ in }
        await fulfillment(of: [entered], timeout: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }
        let began = Date()
        XCTAssertEqual(watcher.resolution(for: "pruned"), .confirmedAbsent)
        XCTAssertNotNil(watcher.publishedIndex)
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
        let watcher = SessionWatcher(stores: [store], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let refused = expectation(description: "neither competitor may be evicted before decision")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 1) { candidate in
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
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        let otherProcess = try TempleDB(path: path)
        try otherProcess.join(sessionID: "external", via: .imported, agent: .claude, transcriptPath: file)
        watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(recorder.latest.isEmpty)
        XCTAssertNil(watcher.resolution(for: "external"))
        recorder.stop()
        try await eventually { watcher.publishedIndex == nil }
        let next = try await start(watcher)
        defer { next.stop() }
        XCTAssertEqual(next.latest.map(\.id), ["external"])
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
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let refused = expectation(description: "recent filename is eligible despite older mtime")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: now, window: 1) { candidate in
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
        try db.join(sessionID: thread, via: .opened, agent: .codex, transcriptPath: original)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(recorder.latest.map(\.id), [thread])
        XCTAssertEqual(recorder.latest.first?.filePath, selected)
        XCTAssertEqual(store.parses, [selected.deletingPathExtension().lastPathComponent: 1])
        XCTAssertEqual(try db.sessionState(thread)?.transcriptPath, selected.path)
        let newest = directory.appendingPathComponent("rollout-2026-10-02T00-00-02-\(thread)_30000000-0000-0000-0000-000000000000.jsonl")
        try data.write(to: newest)
        watcher.reconcileEvent(path: newest.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await eventually { recorder.latest.first?.filePath == newest }
        XCTAssertEqual(recorder.latest.count, 1)
        XCTAssertEqual(try db.sessionState(thread)?.transcriptPath, newest.path)
        try FileManager.default.removeItem(at: newest)
        watcher.reconcileEvent(path: newest.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { recorder.latest.first?.filePath == selected }
        XCTAssertNil(store.parses[olderRevert.deletingPathExtension().lastPathComponent])
        for file in [original, olderRevert, selected] { try FileManager.default.removeItem(at: file) }
        watcher.reconcileEvent(path: selected.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        try await eventually { watcher.resolution(for: thread) == .confirmedAbsent && recorder.latest.isEmpty }
    }

    func testUnreadableSelectedRevertDoesNotSilentlyLoadOlderRollout() async throws {
        let root = try root()
        let thread = UUID().uuidString.lowercased()
        let original = try rollout(root, id: thread, at: Date())
        let selected = original.deletingLastPathComponent().appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_10000000-0000-0000-0000-000000000000.jsonl")
        try Data("{".utf8).write(to: selected)
        let db = try TempleDB.inMemory()
        try db.join(sessionID: thread, via: .opened, agent: .codex, transcriptPath: original)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: thread), .unreadable)
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
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: member), .confirmedAbsent)
        XCTAssertEqual(store.headerReads, 0)
        XCTAssertTrue(store.parses.isEmpty)
        let matching = try rollout(root, id: member, at: Date())
        watcher.reconcileEvent(path: matching.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        try await eventually { recorder.latest.first?.filePath == matching }
        XCTAssertNil(store.parses[outside.deletingPathExtension().lastPathComponent])
        XCTAssertEqual(store.headerReads, 0)
    }

    func testCodexFailedEnumerationKeepsMissingMemberResolvingUntilRecovery() async throws {
        let root = try root()
        let member = UUID().uuidString.lowercased()
        let store = EngineCountingStore(CodexSessionStore(root: root))
        store.failEnumeration = true
        let watcher = SessionWatcher(stores: [store], members: [member], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(watcher.resolution(for: member), .resolving)
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
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        XCTAssertEqual(store.headerReads, 0, "Startup must never scan outside headers")
        for adopting in [false, true] {
            if adopting {
                watcher.registerAdoption(projectPath: "/elsewhere", startedAt: Date(), window: 2) { _ in }
                try await Task.sleep(for: .milliseconds(100))
            }
            sql.reset()
            let parses = store.parses
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
            XCTAssertEqual(store.parses, parses)
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
        let watcher = SessionWatcher(stores: [store], database: db, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let listings = store.enumerations
        let reverted = original.deletingLastPathComponent().appendingPathComponent("rollout-2026-10-02T00-00-01-\(thread)_10000000-0000-0000-0000-000000000000.jsonl")
        try Data(contentsOf: original).write(to: reverted)
        try db.join(sessionID: thread, via: .created, agent: .codex, transcriptPath: reverted)
        try await eventually { recorder.latest.first?.filePath == reverted }
        XCTAssertEqual(store.enumerations, listings)
        XCTAssertNil(store.parses[original.deletingPathExtension().lastPathComponent])
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
        try upgraded.join(sessionID: "legacy", via: .imported, agent: .claude, transcriptPath: URL(fileURLWithPath: "/tmp/legacy.jsonl"))
        XCTAssertEqual(try upgraded.sessionState("legacy")?.joinedVia, .opened)
        XCTAssertEqual(try upgraded.sessionState("legacy")?.agent, .claude)
    }


}

@MainActor
private final class EngineRecorder {
    var indices: [SessionIndex] = []
    var latest: [AgentSession] { indices.last?.allSessions ?? [] }
    private let watcher: SessionWatcher
    private var task: Task<Void, Never>?
    init(_ watcher: SessionWatcher) {
        self.watcher = watcher
        let stream = watcher.start()
        task = Task { [weak self] in
            for await index in stream { self?.indices.append(index) }
        }
    }
    func stop() { task?.cancel(); watcher.stop() }
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
    var cacheInvalidationToken: String? { inner.cacheInvalidationToken }
    var sharedTitleURLs: [URL] { inner.sharedTitleURLs }
    func loadSharedTitles() -> [String: String] { inner.loadSharedTitles() }
    func loadSessions() -> [AgentSession] { XCTFail("engine must never load the full store"); return [] }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] {
        lock.lock(); listingCount += 1; lock.unlock()
        if failEnumeration { throw CocoaError(.fileReadNoPermission) }
        let listed = try inner.enumerateSessionFiles()
        let callback = afterListing; afterListing = nil; callback?()
        return listed
    }
    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        lock.lock(); listingCount += 1; lock.unlock()
        return try inner.enumerateSessionFiles(in: subtree)
    }
    func acceptsTranscript(_ url: URL) -> Bool { inner.acceptsTranscript(url) }
    func filenameID(at url: URL) -> String? { inner.filenameID(at: url) }
    func rolloutSelectionKey(at url: URL) -> String? { inner.rolloutSelectionKey(at: url) }
    func metadataHeader(at url: URL) -> CodexRolloutCandidate? { inner.metadataHeader(at: url) }
    func adoptionHeader(at url: URL) throws -> CodexRolloutCandidate? {
        lock.lock(); headerCount += 1; lock.unlock()
        headerObserver?()
        return try inner.adoptionHeader(at: url)
    }
    func loadSession(at url: URL) -> AgentSession? {
        lock.lock(); counts[url.deletingPathExtension().lastPathComponent, default: 0] += 1; lock.unlock()
        return inner.loadSession(at: url)
    }
}

private final class EngineSQLCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}
