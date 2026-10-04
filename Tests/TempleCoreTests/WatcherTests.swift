import XCTest
import CoreServices
@testable import TempleCore

final class WatcherTests: XCTestCase {
    private var started: [SessionEngine] = []

    override func tearDown() async throws {
        for engine in started { await engine.stop() }
        started.removeAll()
        try await super.tearDown()
    }

    /// Bare member rows want every field, so loaded members carry their
    /// parsed facts in each snapshot (nothing persists them here).
    private func engine(_ source: LocalSessionSource, members: Set<String>) throws -> SessionEngine {
        let db = try TempleDB.inMemory()
        for id in members.sorted() { try db.join(sessionID: id, via: .imported) }
        let engine = SessionEngine(source: source, database: db)
        started.append(engine)
        return engine
    }

    /// The first snapshot, and the source observing (it starts on the
    /// engine's subscription, which the first publication can precede).
    private func waitForInitialPublication(_ watcher: SessionEngine) async throws {
        let deadline = Date().addingTimeInterval(3)
        while watcher.latestSnapshot == nil || watcher.metrics.locates == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(watcher.latestSnapshot)
        let monitoring = Date().addingTimeInterval(2)
        while !watcher.isMonitoring, Date() < monitoring { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testWatcherYieldsUpdatedIndexAfterNewSessionFile() async throws { try await exercise0(injectEvents: false) }
    func testWatcherYieldsUpdatedIndexAfterNewSessionFileWithInjectedEvents() async throws { try await exercise0(injectEvents: true) }

    private func exercise0(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = try engine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.1), members: ["new-session"])
        let received = expectation(description: "updated index")
        let stream = watcher.snapshots()
        await watcher.start()
        try await waitForInitialPublication(watcher)
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        let task = Task {
            var isInitial = true
            for await index in stream {
                if isInitial {
                    isInitial = false
                    let file = project.appendingPathComponent("new-session.jsonl")
                    let json = #"{"sessionId":"new-session","type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
                    try json.write(to: file, atomically: true, encoding: .utf8)
                    if injectEvents { watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated)) }
                } else if index.allSessions.contains(where: { $0.id == "new-session" }) {
                    received.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [received], timeout: 5)
        task.cancel()
    }

    func testWatcherIncrementallyReloadsOneOfTwoHundredSessions() async throws { try await exercise1(injectEvents: false) }
    func testWatcherIncrementallyReloadsOneOfTwoHundredSessionsWithInjectedEvents() async throws { try await exercise1(injectEvents: true) }

    private func exercise1(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-scale-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstLine = #"{"sessionId":"streaming-session","type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        for index in 0..<200 {
            try firstLine.replacingOccurrences(of: "streaming-session", with: "session-\(index)").write(
                to: project.appendingPathComponent("session-\(index).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }

        let watcher = try engine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.05), members: Set((0..<200).map { "session-\($0)" }))
        let received = expectation(description: "incremental update")
        let target = project.appendingPathComponent("session-100.jsonl")
        let stream = watcher.snapshots()
        await watcher.start()
        try await waitForInitialPublication(watcher)
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        let task = Task {
            var mutationTime: Date?
            for await index in stream {
                if mutationTime == nil {
                    guard index.allSessions.count == 200 else { continue }
                    mutationTime = Date()
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(("\n" + #"{"type":"assistant","message":{"content":"updated"}}"#).utf8))
                    if injectEvents { watcher.reconcileEvent(path: target.path, flags: UInt32(kFSEventStreamEventFlagItemModified)) }
                } else if index.allSessions.first(where: { $0.id == "session-100" })?.messageCount == 2 {
                    if let mutationTime {
                        XCTAssertLessThan(Date().timeIntervalSince(mutationTime), 2.0)
                    }
                    received.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [received], timeout: 2.0)
        task.cancel()
    }

    func testWatcherDoesNotStarveUpdatesDuringSteadyEventStream() async throws { try await exercise2(injectEvents: false) }
    func testWatcherDoesNotStarveUpdatesDuringSteadyEventStreamWithInjectedEvents() async throws { try await exercise2(injectEvents: true) }

    private func exercise2(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-steady-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = project.appendingPathComponent("streaming-session.jsonl")
        let firstLine = #"{"sessionId":"streaming-session","type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        try firstLine.write(to: session, atomically: true, encoding: .utf8)

        let watcher = try engine(LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.3), members: ["streaming-session"])
        let initial = expectation(description: "initial index")
        let updatedWhileAppending = expectation(description: "update before steady appends stop")
        let stream = watcher.snapshots()
        await watcher.start()
        try await waitForInitialPublication(watcher)
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        let watchTask = Task {
            var receivedInitial = false
            for await index in stream {
                if !receivedInitial {
                    receivedInitial = true
                    initial.fulfill()
                } else if index.allSessions.first(where: { $0.id == "streaming-session" })?.messageCount ?? 0 > 1 {
                    updatedWhileAppending.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [initial], timeout: 2.0)
        let appendTask = Task {
            for index in 0..<18 {
                guard !Task.isCancelled else { break }
                let handle = try FileHandle(forWritingTo: session)
                try handle.seekToEnd()
                let line = "\n" + #"{"type":"assistant","message":{"content":"update \#(index)"}}"#
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
                if injectEvents { watcher.reconcileEvent(path: session.path, flags: UInt32(kFSEventStreamEventFlagItemModified)) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        await fulfillment(of: [updatedWhileAppending], timeout: 1.5)
        appendTask.cancel()
        _ = try? await appendTask.value
        watchTask.cancel()
    }

    /// A brand-new session file is typically still being streamed by the CLI
    /// when the watcher first parses it. If the incomplete parse (no `cwd` yet)
    /// gets cached against the file's FINAL signature, the session stays
    /// wrong/missing until app restart. This wrapper deterministically lands a
    /// write inside the parse window.
    func testMidWriteParseIsRetriedNotPinned() async throws { try await exercise3(injectEvents: false) }
    func testMidWriteParseIsRetriedNotPinnedWithInjectedEvents() async throws { try await exercise3(injectEvents: true) }

    private func exercise3(injectEvents: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-race-\(UUID().uuidString)", isDirectory: true)
        // Dir name decodes lossily to "/tmp/tw/proj" — distinguishable from the
        // real cwd "/tmp/tw-proj" that only the late-written line carries.
        let project = root.appendingPathComponent("-tmp-tw-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = project.appendingPathComponent("racy-session.jsonl")
        let lateLine = "\n" + #"{"sessionId":"racy-session","type":"user","message":{"content":"hello"},"cwd":"/tmp/tw-proj","timestamp":"2026-01-01T00:00:01Z"}"#
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.05)
        // The CLI writes more of the file while the first read is in it:
        // after its bytes, before its closing stat.
        let once = Flag()
        source.readPhaseHook = { phase, url in
            guard phase == .bytesRead, url.lastPathComponent == file.lastPathComponent, once.setOnce(),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile(); handle.write(Data(lateLine.utf8)); try? handle.close()
        }
        let watcher = try engine(source, members: ["racy-session"])
        let corrected = expectation(description: "re-parsed with real cwd after mid-write race")
        let stream = watcher.snapshots()
        await watcher.start()
        try await waitForInitialPublication(watcher)
        try XCTSkipIf(!injectEvents && !watcher.isMonitoring, "FSEvents service unavailable in this execution environment")
        let task = Task {
            var isInitial = true
            for await index in stream {
                if isInitial {
                    isInitial = false
                    // Preamble only — a typed line but no cwd (like a freshly
                    // created claude session).
                    let preamble = #"{"sessionId":"racy-session","type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:00Z","content":"hi"}"#
                    try preamble.write(to: file, atomically: true, encoding: .utf8)
                    if injectEvents { watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemCreated)) }
                } else if index.allSessions.contains(where: { $0.projectPath == "/tmp/tw-proj" }) {
                    corrected.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [corrected], timeout: 5)
        task.cancel()
    }
}
