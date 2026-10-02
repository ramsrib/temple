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
        let file = dir.appendingPathComponent("rollout-fixture-\(filenameID ?? id).jsonl")
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

    func testCommittedJoinLoadsWithoutAnEventAndRepeatedOpenResolvesAgain() async throws {
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
        try await eventually { store.parses["existing"] == 2 }
    }

    func testPrestartJoinWaitsForClaudeCreationAndDeletionKeepsMembership() async throws {
        let root = try root()
        let db = try TempleDB.inMemory()
        try db.join(sessionID: "later", via: .created, agent: .claude)
        let watcher = SessionWatcher(stores: [ClaudeSessionStore(root: root)], database: db, debounceInterval: 0.02)
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
        XCTAssertEqual(watcher.resolution(for: "unknown"), .unreadable)
        store.failEnumeration = false
        watcher.reconcileEvent(path: root.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs))
        try await eventually { recorder.latest.first?.id == "kept" }
        XCTAssertEqual(watcher.resolution(for: "unknown"), .confirmedAbsent)
    }

    func testLegacyPayloadIDRepairAndInvalidHintAreValidated() async throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date(), filenameID: UUID().uuidString.lowercased())
        let db = try TempleDB.inMemory()
        try db.join(sessionID: id, via: .opened)
        try db.join(sessionID: "wrong", via: .opened, agent: .codex, transcriptPath: file)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], database: db, headerMapURL: root.appendingPathComponent("headers.json"), debounceInterval: 0.02)
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
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], members: [id], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
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

    func testAdoptionWaitsForStaggeredAmbiguityAndRefusesIt() async throws {
        let root = try root()
        let time = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
        let watcher = SessionWatcher(stores: [CodexSessionStore(root: root)], debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        let decided = expectation(description: "ambiguous decision")
        watcher.registerAdoption(projectPath: "/private/tmp", startedAt: time, window: 0.35) { candidate in
            XCTAssertNil(candidate); decided.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        try rollout(root, id: UUID().uuidString.lowercased(), at: time.addingTimeInterval(0.1))
        await fulfillment(of: [decided], timeout: 2)
    }

    func testOneRolloutCannotSatisfyTwoOverlappingRequests() async throws {
        let root = try root()
        let time = Date()
        try rollout(root, id: UUID().uuidString.lowercased(), at: time)
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
        XCTAssertEqual(try store.metadataSessionID(at: file), id)
        // A valid header beginning beyond the cap must never be reached.
        try (Data(repeating: 0x20, count: StoreIO.readWindowBytes) + header + Data([0x0a])).write(to: file)
        XCTAssertThrowsError(try StoreIO.readFirstLine(file))
        XCTAssertNil(store.metadataHeader(at: file))
        XCTAssertThrowsError(try store.metadataSessionID(at: file))
    }

    func testLegacyRepairStartsAfterFirstPublicationAndKeepsResolvingUntilComplete() async throws {
        let root = try root()
        let fast = UUID().uuidString.lowercased()
        let legacy = UUID().uuidString.lowercased()
        try rollout(root, id: fast, at: Date())
        try rollout(root, id: legacy, at: Date(), filenameID: UUID().uuidString.lowercased())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let watcher = SessionWatcher(stores: [store], members: [fast, legacy, "pruned"],
                                     headerMapURL: root.appendingPathComponent("headers.json"), debounceInterval: 0.02)
        store.headerObserver = {
            XCTAssertEqual(watcher.publishedIndex?.allSessions.map(\.id), [fast])
            XCTAssertEqual(watcher.resolution(for: legacy), .resolving)
            XCTAssertEqual(watcher.resolution(for: "pruned"), .resolving)
        }
        let recorder = try await start(watcher)
        defer { recorder.stop(); store.headerObserver = nil }
        XCTAssertEqual(recorder.indices.first?.allSessions.map(\.id), [fast])
        try await eventually { recorder.latest.count == 2 }
        XCTAssertEqual(watcher.resolution(for: "pruned"), .confirmedAbsent)
        XCTAssertEqual(recorder.indices.count, 2)
    }

    func testPersistedHeaderMapReusedAcrossLaunchesAndOnlyChangedRolloutsReread() async throws {
        let root = try root()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        try rollout(root, id: first, at: Date())
        try rollout(root, id: second, at: Date())
        let mapURL = root.appendingPathComponent("headers.json")
        let store = EngineCountingStore(CodexSessionStore(root: root))
        for launch in 0..<3 {
            if launch == 2 { try rollout(root, id: first, at: Date().addingTimeInterval(30)) }
            let watcher = SessionWatcher(stores: [store], members: ["pruned"], headerMapURL: mapURL, debounceInterval: 0.02)
            let recorder = try await start(watcher)
            try await eventually { watcher.resolution(for: "pruned") == .confirmedAbsent }
            XCTAssertEqual(recorder.indices.count, 1, "Absent rows must not cause another publication")
            XCTAssertEqual(store.headerReads, launch == 2 ? 3 : 2)
            recorder.stop()
            _ = watcher.isMonitoring // wait for stop before another launch
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapURL.path))
    }

    func testCorruptAndOldSchemaHeaderMapsAreRebuiltAndReplacementsInvalidated() throws {
        let root = try root()
        let id = UUID().uuidString.lowercased()
        let file = try rollout(root, id: id, at: Date())
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let url = root.appendingPathComponent("headers.json")
        try Data("broken JSON".utf8).write(to: url)
        let rebuilt = RolloutHeaderMap(url: url)
        XCTAssertEqual(try rebuilt.payloadID(at: file, store: store), id)
        rebuilt.save(retaining: [file.path])
        let warm = RolloutHeaderMap(url: url)
        XCTAssertEqual(try warm.payloadID(at: file, store: store), id)
        XCTAssertEqual(store.headerReads, 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(try RolloutHeaderMap(url: url).payloadID(at: file, store: store), id)
        XCTAssertEqual(store.headerReads, 2)
        // A replacement at the same path with preserved size/mtime still has a
        // different inode and must not inherit the previous file's identity.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let replacementID = UUID().uuidString.lowercased()
        try rollout(root, id: replacementID, at: Date(), filenameID: id)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        XCTAssertEqual(try warm.payloadID(at: file, store: store), replacementID)
        XCTAssertEqual(store.headerReads, 3)
    }

    func testFailedHeaderReadDoesNotPersistAFalseNegativeOrConfirmAbsence() async throws {
        let root = try root()
        let file = try rollout(root, id: UUID().uuidString.lowercased(), at: Date())
        try Data("{incomplete".utf8).write(to: file)
        let store = EngineCountingStore(CodexSessionStore(root: root))
        let url = root.appendingPathComponent("headers.json")
        let watcher = SessionWatcher(stores: [store], members: ["pruned"], headerMapURL: url, debounceInterval: 0.02)
        let recorder = try await start(watcher)
        defer { recorder.stop() }
        try await eventually { watcher.resolution(for: "pruned") == .unreadable }
        XCTAssertEqual(recorder.indices.count, 1)
        XCTAssertThrowsError(try RolloutHeaderMap(url: url).payloadID(at: file, store: store))
        XCTAssertEqual(store.headerReads, 2, "Failed reads must be retried, not cached as absent")
    }

    func testOldJSONAndDatabaseMigrationPreserveMembershipAndProvenance() throws {
        let old = Data(#"{"id":"legacy","pinned":true,"archived":false,"joinedVia":"opened"}"#.utf8)
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

    func testVersionTwoCacheRejectedAndCurrentCacheFilteredByMembers() throws {
        let root = try root()
        let url = root.appendingPathComponent("cache.json")
        let sessions = ["in", "out"].map { AgentSession(id: $0, agent: .claude, projectPath: "/tmp", title: $0,
            createdAt: nil, updatedAt: Date(), filePath: URL(fileURLWithPath: "/tmp/\($0).jsonl")) }
        try CachedIndexStore.save(.grouping(sessions), to: url)
        XCTAssertEqual(CachedIndexStore.load(from: url, members: ["in"])?.allSessions.map(\.id), ["in"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertNil(CachedIndexStore.load(from: url, members: ["in"]))
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
    func loadSessions() -> [AgentSession] { XCTFail("engine must never load the full store"); return [] }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func enumerateSessionFiles() throws -> [URL] {
        if failEnumeration { throw CocoaError(.fileReadNoPermission) }
        let listed = try inner.enumerateSessionFiles()
        let callback = afterListing; afterListing = nil; callback?()
        return listed
    }
    func acceptsTranscript(_ url: URL) -> Bool { inner.acceptsTranscript(url) }
    func filenameID(at url: URL) -> String? { inner.filenameID(at: url) }
    func metadataHeader(at url: URL) -> CodexRolloutCandidate? { inner.metadataHeader(at: url) }
    func metadataSessionID(at url: URL) throws -> String? {
        lock.lock(); headerCount += 1; lock.unlock()
        headerObserver?()
        return try inner.metadataSessionID(at: url)
    }
    func loadSession(at url: URL) -> AgentSession? {
        lock.lock(); counts[url.deletingPathExtension().lastPathComponent, default: 0] += 1; lock.unlock()
        return inner.loadSession(at: url)
    }
}
