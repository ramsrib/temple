import XCTest
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
