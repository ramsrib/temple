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
