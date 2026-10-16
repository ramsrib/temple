import XCTest
import TempleTestSupport
@testable import TempleCore
@testable import TempleLocalHost

/// What only this Mac's source can show about `proveAbsent` (ADR-030): a
/// store that is not configured or not there proves nothing, and the
/// observation window ends at a delivery barrier, not at a guess about
/// FSEvents' latency.
final class LocalAbsenceProofTests: XCTestCase {
    private var root: URL!
    private var observers: [Task<Void, Never>] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/-work-project"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        observers.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func observed(_ source: LocalSessionSource) async throws {
        let changes = source.changes()
        observers.append(Task { do { for try await _ in changes {} } catch {} })
        let deadline = Date().addingTimeInterval(3)
        while !source.isMonitoring, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(source.isMonitoring)
    }

    /// An agent with no store configured here was never listed: unproven,
    /// not "missing everywhere". A configured store whose root is not there
    /// lists nothing and proves nothing either.
    func testNoStoreOrNoRootProvesNothing() async throws {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))], debounceInterval: 0.01)
        try await observed(source)
        let codex = await source.proveAbsent(ids: ["x"], agent: .codex)
        XCTAssertEqual(codex, .unproven)

        let missing = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("not-there"))], debounceInterval: 0.01)
        try await observed(missing)
        let proof = await missing.proveAbsent(ids: ["x"], agent: .claude)
        XCTAssertFalse(proof.exhaustive)
        XCTAssertFalse(proof.proves("x"))
    }

    /// The asked transcript is created at the very end of the window, with
    /// half a second of stream latency still to run: a proof that only
    /// waited would close before FSEvents delivered it. The barrier
    /// delivers it: not quiescent, nothing proven.
    func testACreationLateInTheWindowIsHeard() async throws {
        let latency: TimeInterval = 0.5
        let project = root.appendingPathComponent("claude/-work-project")
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        debounceInterval: latency)
        try await observed(source)
        let id = UUID().uuidString.lowercased()
        // Settled first: the fixture's own folders are delivered, and a
        // proof with nothing happening proves.
        var control = AbsenceProof.unproven
        for _ in 0..<5 where !control.proves(id) {
            try await Task.sleep(for: .seconds(latency))
            control = await source.proveAbsent(ids: [id], agent: .claude)
        }
        XCTAssertTrue(control.proves(id), "a quiet proof proves")
        // Made at the very end of the wait: FSEvents still holds it.
        source.proofWindowEndHook = {
            try? Data(#"{"type":"user","sessionId":"\#(id)"}"#.utf8).write(to: project.appendingPathComponent("\(id).jsonl"))
        }
        let proof = await source.proveAbsent(ids: [id], agent: .claude)
        XCTAssertFalse(proof.quiescent, "the late creation was delivered before the proof closed")
        XCTAssertFalse(proof.proves(id))
    }

    // MARK: The stream's callback

    /// A stream's batch is processed after its callback returns, never in
    /// it: an event that re-arms (here a dropped-events notice) replaces the
    /// stream from the queue, and the source keeps monitoring under the new
    /// one. A batch the replaced stream had queued is dropped: delivered
    /// under the old generation, its own dropped-events notice re-arms
    /// nothing. The live generation's still does.
    func testAReArmFromAnEventWorksAndAStaleBatchIsDropped() async throws {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        debounceInterval: 0.01)
        try await observed(source)
        let dropped = UInt32(kFSEventStreamEventFlagKernelDropped)
        let path = root.appendingPathComponent("claude").path

        let first = source.currentStreamGeneration
        source.enqueueStreamBatch([(path, dropped)], streamGeneration: first)
        let second = source.currentStreamGeneration
        XCTAssertGreaterThan(second, first, "the event re-armed the stream")
        XCTAssertTrue(source.isMonitoring, "and the new stream is running")

        source.enqueueStreamBatch([(path, dropped)], streamGeneration: first)
        XCTAssertEqual(source.currentStreamGeneration, second, "the replaced stream's batch is dropped")

        source.enqueueStreamBatch([(path, dropped), (path, dropped)], streamGeneration: second)
        XCTAssertEqual(source.currentStreamGeneration, second + 1,
                       "the live stream's batch re-arms once; the rest of it belonged to the stream it replaced")
        XCTAssertTrue(source.isMonitoring)
    }

    /// A re-arm drops the rest of its batch and every batch the old stream
    /// had queued, and the new stream only hears what happens from now. A
    /// sentinel-folder removal re-arms too, so it must reconcile like the
    /// other re-arms: a transcript created just before, whose event sits in
    /// the same batch behind the removal, is still reported. The stream's
    /// latency is long, so only the reconciliation can report it in time.
    func testASentinelRemovalReArmsWithoutLosingTheChangesItDropped() async throws {
        let project = root.appendingPathComponent("claude/-work-project")
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        debounceInterval: 30)
        let seen = SeenIDs()
        let changes = source.changes()
        observers.append(Task {
            do {
                for try await change in changes {
                    if case .transcripts(let ids, _) = change { seen.add(ids) }
                }
            } catch {}
        })
        let ready = Date().addingTimeInterval(3)
        while !source.isMonitoring, Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(source.isMonitoring)
        let sentinel = try XCTUnwrap(source.currentSentinelFolder)
        let generation = source.currentStreamGeneration

        let id = UUID().uuidString.lowercased()
        let transcript = project.appendingPathComponent("\(id).jsonl")
        try Data(#"{"type":"user","sessionId":"\#(id)"}"#.utf8).write(to: transcript)
        try FileManager.default.removeItem(at: sentinel)
        source.enqueueStreamBatch([
            (sentinel.path, UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)),
            (transcript.path, UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
        ], streamGeneration: generation)

        XCTAssertGreaterThan(source.currentStreamGeneration, generation, "the removal re-armed")
        let deadline = Date().addingTimeInterval(5)
        while !seen.contains(id), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(seen.contains(id), "the transcript whose event was dropped is reported by the reconciliation")
        XCTAssertNotEqual(source.currentSentinelFolder, sentinel, "a new sentinel folder is watched")
        XCTAssertTrue(source.isMonitoring)
    }

    // MARK: Round 8

    private func settledSource(latency: TimeInterval = 0.01) async throws -> LocalSessionSource {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        debounceInterval: latency)
        try await observed(source)
        return source
    }

    /// A proof that settles: the fixture's own writes may still be arriving.
    private func settledProof(_ source: LocalSessionSource, _ id: String) async throws -> AbsenceProof {
        var proof = await source.proveAbsent(ids: [id], agent: .claude)
        for _ in 0..<8 where !proof.proves(id) {
            try await Task.sleep(for: .milliseconds(150))
            proof = await source.proveAbsent(ids: [id], agent: .claude)
        }
        return proof
    }

    /// Only stores on local filesystems are proven: a network or FUSE
    /// volume, at the root or mounted inside it, changes behind this Mac's
    /// event stream.
    func testAStoreNotOnLocalFilesystemsProvesNothing() async throws {
        let source = try await settledSource()
        XCTAssertTrue(LocalSessionSource.storeOnLocalFilesystems(root), "a temporary folder is local")
        let id = UUID().uuidString.lowercased()
        let local = try await settledProof(source, id)
        XCTAssertTrue(local.proves(id))
        source.localFilesystemProbe = { _ in false }
        let remote = await source.proveAbsent(ids: [id], agent: .claude)
        XCTAssertEqual(remote, .unproven)
    }

    /// The volume check reads the mount table from proofs for both agents at
    /// once: every concurrent caller gets the same, correct answer (the
    /// shared-buffer `getmntinfo` could hand one caller another's buffer).
    func testTheLocalVolumeCheckIsSafeToRunConcurrently() async {
        let root = self.root!
        let answers = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 { group.addTask { LocalSessionSource.storeOnLocalFilesystems(root) } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(answers.count, 64)
        XCTAssertTrue(answers.allSatisfy { $0 }, "a temporary folder is local, every time")
    }

    /// A notification that says the stream lost track invalidates a proof
    /// in flight, and is never a barrier's evidence — even one naming the
    /// barrier's own sentinel file.
    func testACompromisedNotificationInvalidatesAProofAndIsNoBarrier() async throws {
        let source = try await settledSource()
        let id = UUID().uuidString.lowercased()
        let control = try await settledProof(source, id)
        XCTAssertTrue(control.proves(id))
        let flags = [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagEventIdsWrapped]
        for flag in flags {
            source.barrierStartedHook = { sentinel in
                source.reconcileEvent(path: sentinel.path, flags: UInt32(flag | kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
            }
            let onSentinel = await source.proveAbsent(ids: [id], agent: .claude)
            XCTAssertFalse(onSentinel.quiescent, "flag \(flag) on the sentinel")
            source.barrierStartedHook = nil
            _ = try await settledProof(source, id)
            let storePath = root.appendingPathComponent("claude/-work-project").path
            source.proofHook = { source.reconcileEvent(path: storePath, flags: UInt32(flag)) }
            let onStore = await source.proveAbsent(ids: [id], agent: .claude)
            XCTAssertFalse(onStore.quiescent, "flag \(flag) in the store")
            source.proofHook = nil
            _ = try await settledProof(source, id)
        }
    }

    /// Cancelled while the last hop to the source's queue waits: nothing.
    func testCancellingDuringTheLastHopProvesNothing() async throws {
        let source = try await settledSource()
        let id = UUID().uuidString.lowercased()
        _ = try await settledProof(source, id)
        let box = TaskBox(), start = FakeGate()
        source.proofBeforeReadbackHook = {
            // The readback is queued behind this: cancel while it waits.
            source.onQueueForTesting { box.task?.cancel(); Thread.sleep(forTimeInterval: 0.05) }
        }
        let task = Task { () -> AbsenceProof in
            await start.wait()
            return await source.proveAbsent(ids: [id], agent: .claude)
        }
        box.task = task
        start.open()
        let proof = await task.value
        XCTAssertEqual(proof, .unproven)
    }

    /// The sentinel folder deleted: the source makes and watches a new one,
    /// and proofs succeed again.
    func testADeletedSentinelFolderIsReplaced() async throws {
        let source = try await settledSource()
        let id = UUID().uuidString.lowercased()
        _ = try await settledProof(source, id)
        let old = try XCTUnwrap(source.sentinelFolderForTesting)
        try FileManager.default.removeItem(at: old)
        let proof = try await settledProof(source, id)
        XCTAssertTrue(proof.proves(id), "proven again after the folder went")
        let new = try XCTUnwrap(source.sentinelFolderForTesting)
        XCTAssertNotEqual(new, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    /// A barrier that times out leaves no sentinel file behind, nor does one
    /// whose event arrives late.
    func testABarrierLeavesNoSentinelFileBehind() async throws {
        let source = try await settledSource()
        let id = UUID().uuidString.lowercased()
        _ = try await settledProof(source, id)
        let folder = try XCTUnwrap(source.sentinelFolderForTesting)
        source.barrierTimeoutOverride = 0.2
        source.sentinelDeliveryBlockedForTesting = true
        for _ in 0..<3 {
            let proof = await source.proveAbsent(ids: [id], agent: .claude)
            XCTAssertFalse(proof.quiescent, "timed out")
        }
        try await Task.sleep(for: .milliseconds(300))
        var left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, [], "timed-out barriers' files removed")
        source.sentinelDeliveryBlockedForTesting = false
        let proof = try await settledProof(source, id)
        XCTAssertTrue(proof.proves(id))
        try await Task.sleep(for: .milliseconds(100))
        left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, [], "a passed barrier's file removed")
    }

    /// Without observation (a one-shot source) there is no barrier to raise
    /// and nothing heard: never quiescent.
    func testAnUnobservedSourceProvesNothing() async throws {
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root.appendingPathComponent("claude"))],
                                        debounceInterval: 0.01, monitorChanges: false)
        let proof = await source.proveAbsent(ids: ["x"], agent: .claude)
        XCTAssertTrue(proof.exhaustive)
        XCTAssertFalse(proof.quiescent)
    }
}

/// Session ids a change stream reported, read from the test.
private final class SeenIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func add(_ more: Set<String>) { lock.lock(); ids.formUnion(more); lock.unlock() }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
