import XCTest
import CoreServices
@testable import TempleCore
@testable import TempleLocalHost

/// The local source's coverage state machine (ADR-032): an event that could
/// change an agent's tree makes it incomplete at once; only a full audited
/// listing whose revision is still current when it finishes makes it
/// complete again; one scan in flight and at most one follow-up, spaced and
/// retried on a bounded backoff.
final class CoverageStateTests: XCTestCase {
    private var root: URL!
    private var claudeRoot: URL { root.appendingPathComponent("claude") }
    private var project: URL { claudeRoot.appendingPathComponent("-work-project") }
    private var codexBase: URL { root.appendingPathComponent("codex") }
    private var sessions: URL { codexBase.appendingPathComponent("sessions") }
    private var day: URL { sessions.appendingPathComponent("2026/10/01") }
    private var outside: URL { root.appendingPathComponent("outside") }
    private var observers: [Task<Void, Never>] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/temple-coverage-\(UUID().uuidString)")
        for dir in [project, day, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: project.appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl"))
        try Data("{}".utf8).write(to: day.appendingPathComponent("rollout-2026-10-01T10-00-00-\(UUID().uuidString.lowercased()).jsonl"))
    }

    override func tearDown() {
        observers.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A running source (observed, as the engine would) over both stores.
    private func source(stores: [any IncrementalSessionStore]? = nil, interval: TimeInterval = 0.05) async throws -> LocalSessionSource {
        let source = LocalSessionSource(stores: stores ?? [ClaudeSessionStore(root: claudeRoot), CodexSessionStore(root: codexBase)],
                                        debounceInterval: 0.01, monitorChanges: false, coverageScanInterval: interval)
        let changes = source.changes()
        observers.append(Task { do { for try await _ in changes {} } catch {} })
        _ = try await complete(source)
        return source
    }

    private func complete(_ source: LocalSessionSource) async throws -> Set<Agent> {
        try await source.locate([]).complete
    }

    private func eventually(_ source: LocalSessionSource, timeout: TimeInterval = 4, _ condition: (Set<Agent>) -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(try await complete(source)) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("never held: \(try await complete(source))", file: file, line: line)
    }

    private func event(_ source: LocalSessionSource, _ url: URL, _ flags: Int) {
        source.reconcileEvent(path: url.path, flags: UInt32(flags))
    }

    // MARK: Dirty at once

    /// A plain folder moved in whole, holding a hidden folder (Codex) or a
    /// link (Claude): only the moved folder's own event arrives. The agent
    /// is incomplete at once, and the scan keeps it so.
    func testAFolderMovedInWithOnlyItsOwnEventMakesItsAgentIncomplete() async throws {
        let source = try await source()
        var agents = try await complete(source)
        XCTAssertEqual(agents, [.claude, .codex])

        let codexFolder = outside.appendingPathComponent("moved-day")
        try FileManager.default.createDirectory(at: codexFolder.appendingPathComponent(".stash"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codexFolder.appendingPathComponent(".stash/rollout-2026-10-01T10-00-00-\(UUID().uuidString.lowercased()).jsonl"))
        let codexTarget = sessions.appendingPathComponent("2026/10/02")
        try FileManager.default.moveItem(at: codexFolder, to: codexTarget)
        event(source, codexTarget, kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        agents = try await complete(source)
        XCTAssertEqual(agents, [.claude], "incomplete at once, before any scan")

        let claudeFolder = outside.appendingPathComponent("moved-project")
        try FileManager.default.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeFolder.appendingPathComponent("linked.jsonl"),
                                                   withDestinationURL: outside.appendingPathComponent("anything.jsonl"))
        let claudeTarget = claudeRoot.appendingPathComponent("-moved-project")
        try FileManager.default.moveItem(at: claudeFolder, to: claudeTarget)
        event(source, claudeTarget, kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        agents = try await complete(source)
        XCTAssertEqual(agents, [])

        // The scans that follow find what the moves brought in: still not.
        let scans = source.coverageScans
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(source.coverageScans, scans)
        agents = try await complete(source)
        XCTAssertEqual(agents, [])
    }

    // MARK: Recovery

    /// A hidden flag cleared, a hidden file deleted: each is an event the
    /// source acts on without looking at what is there now, and a scan
    /// brings completeness back.
    func testClearingAHiddenFlagOrDeletingAHiddenFileRecoversThroughTheScan() async throws {
        var flagged = project.appendingPathComponent("notes.txt")
        try Data().write(to: flagged)
        var values = URLResourceValues(); values.isHidden = true
        try flagged.setResourceValues(values)
        let source = try await source(stores: [ClaudeSessionStore(root: claudeRoot)])
        var agents = try await complete(source)
        XCTAssertEqual(agents, [.codex], "the first listing met a hidden file (Codex has no store here: complete)")

        values.isHidden = false
        try flagged.setResourceValues(values)
        event(source, flagged, kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsFile)
        try await eventually(source) { $0.contains(.claude) }

        let dotted = project.appendingPathComponent(".swap")
        try Data().write(to: dotted)
        event(source, dotted, kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        agents = try await complete(source)
        XCTAssertFalse(agents.contains(.claude))
        try FileManager.default.removeItem(at: dotted)
        event(source, dotted, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        try await eventually(source) { $0.contains(.claude) }
    }

    /// A content write to a transcript changes nothing about coverage.
    func testAContentWriteToATranscriptKeepsCoverage() async throws {
        let source = try await source()
        let transcript = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)[0]
        let before = try await source.locate([]).coverage
        event(source, transcript, kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        try await Task.sleep(for: .milliseconds(100))
        let after = try await source.locate([])
        XCTAssertEqual(after.complete, [.claude, .codex])
        XCTAssertEqual(after.coverage, before)
        XCTAssertEqual(source.coverageScans, 0)
    }

    /// An event during a scan wins: the scan's result, about a tree that no
    /// longer is, is dropped, and a follow-up decides.
    func testAnEventDuringAScanDiscardsItsResult() async throws {
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        let calls = ScanCalls()
        let source = try await source(stores: [ClaudeSessionStore(root: claudeRoot)])
        source.coverageScanHook = { _ in
            switch calls.next() {
            case 1: first.wait()
            case 2: second.wait()
            default: break
            }
        }
        let gone = project.appendingPathComponent("gone.jsonl")
        event(source, gone, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        try await waitFor { calls.count == 1 }
        // While the first scan lists, the tree changes again.
        event(source, gone, kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        first.signal()
        try await waitFor { calls.count == 2 }
        var agents = try await complete(source)
        XCTAssertFalse(agents.contains(.claude), "the first scan's result was dropped")
        XCTAssertEqual(source.coverageScans, 1)
        second.signal()
        try await eventually(source) { $0.contains(.claude) }
        agents = try await complete(source)
        XCTAssertTrue(agents.contains(.claude))
        XCTAssertEqual(source.coverageScans, 2)
    }

    /// A burst of a hundred writes to a hidden file is a bounded number of
    /// scans: one in flight, one follow-up, spaced.
    func testABurstOfHiddenWritesIsABoundedNumberOfScans() async throws {
        let source = try await source(stores: [ClaudeSessionStore(root: claudeRoot)], interval: 0.3)
        let swap = project.appendingPathComponent(".swap")
        try Data().write(to: swap)
        let enumerations = source.metrics.enumerations
        for _ in 0..<100 { event(source, swap, kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile) }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertGreaterThanOrEqual(source.coverageScans, 1)
        XCTAssertLessThanOrEqual(source.coverageScans, 2, "one scan and one follow-up for the whole burst")
        XCTAssertEqual(source.metrics.enumerations, enumerations, "no full listing of the filename map per event")
        let agents = try await complete(source)
        XCTAssertFalse(agents.contains(.claude), "a hidden file there: not exhaustive")
    }

    /// A store root missing at the start is retried on a backoff with no
    /// event at all, and completes once it is there; then scanning stops.
    func testAMissingRootRecoversWithoutAnEvent() async throws {
        try FileManager.default.removeItem(at: claudeRoot)
        let source = try await source(stores: [ClaudeSessionStore(root: claudeRoot)])
        var agents = try await complete(source)
        XCTAssertFalse(agents.contains(.claude))
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try await eventually(source) { $0.contains(.claude) }
        let scans = source.coverageScans
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(source.coverageScans, scans, "complete: nothing more to scan")
        agents = try await complete(source)
        XCTAssertTrue(agents.contains(.claude))
    }

    /// The scan runs off the source's queue: events are recorded, and
    /// coverage withdrawn, while a scan is held.
    func testAHeldScanDoesNotHoldInvalidation() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = ScanCalls()
        let source = try await source()
        source.coverageScanHook = { _ in if calls.next() == 1 { gate.wait() } }
        defer { gate.signal() }
        event(source, project.appendingPathComponent("a.jsonl"), kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        try await waitFor { calls.count == 1 }
        let before = try await source.locate([]).coverage
        event(source, day.appendingPathComponent("x"), kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        let after = try await source.locate([])
        XCTAssertFalse(after.complete.contains(.codex), "withdrawn while a Claude scan is held")
        XCTAssertGreaterThan(after.coverage, before)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ScanCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
