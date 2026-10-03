import XCTest
import CoreServices
@testable import TempleCore
@testable import TempleUI

@MainActor
final class WatcherIndexSourceTests: XCTestCase {
    func testMultipleMemberWritesPublishOneIndexAtTheBatchBoundary() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-index-batch-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["one", "two"].map { project.appendingPathComponent("\($0).jsonl") }
        func write(_ file: URL, prompt: String) throws {
            try "{\"type\":\"user\",\"sessionId\":\"\(file.deletingPathExtension().lastPathComponent)\",\"cwd\":\"/project\",\"message\":{\"content\":\"\(prompt)\"}}".write(to: file, atomically: false, encoding: .utf8)
        }
        for file in files { try write(file, prompt: "Before") }
        let secondParse = expectation(description: "second member parse reached")
        let store = BatchGateStore(root: root, onSecondParse: { secondParse.fulfill() })
        let watcher = SessionWatcher(stores: [store], members: ["one", "two"], debounceInterval: 0.1)
        let source = WatcherIndexSource(watcher: watcher)
        defer { store.release(); source.stop() }
        let initial = expectation(description: "initial index")
        let complete = expectation(description: "complete batch index")
        let intermediate = expectation(description: "no partially reconciled index")
        intermediate.isInverted = true
        var indices: [EngineSnapshot] = []
        source.start { index in
            indices.append(index)
            let updated = index.allSessions.filter { $0.title == "After" }.count
            if indices.count == 1 { initial.fulfill() }
            if updated == 1 { intermediate.fulfill() }
            if updated == 2 { complete.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 3)
        store.arm()
        for file in files {
            try write(file, prompt: "After")
            watcher.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        }
        await fulfillment(of: [secondParse], timeout: 3)
        // The engine is paused before the second result. Even a fast main actor
        // must see no first-path index while this batch is unfinished.
        await fulfillment(of: [intermediate], timeout: 0.15)
        XCTAssertEqual(indices.count, 1)
        store.release()
        await fulfillment(of: [complete], timeout: 3)
        XCTAssertEqual(indices.count, 2)
        XCTAssertEqual(indices.last?.allSessions.map(\.title), ["After", "After"])
    }
}

private final class BatchGateStore: TranscriptSummaryStore, @unchecked Sendable {
    private let inner: ClaudeSessionStore
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let onSecondParse: @Sendable () -> Void
    private var armed = false
    private var parses = 0

    init(root: URL, onSecondParse: @escaping @Sendable () -> Void) {
        inner = ClaudeSessionStore(root: root)
        self.onSecondParse = onSecondParse
    }
    func arm() { lock.lock(); armed = true; parses = 0; lock.unlock() }
    func release() { gate.signal() }
    var agent: Agent { inner.agent }
    var watchedURLs: [URL] { inner.watchedURLs }
    func sessionFileURLs() -> [URL] { inner.sessionFileURLs() }
    func loadSummaries() -> [TranscriptSummary] { inner.loadSummaries() }
    func loadSummary(at url: URL) -> TranscriptSummary? {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        if armed { parses += 1 }
        let pause = armed && parses == 2
        lock.unlock()
        if pause {
            onSecondParse()
            XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
        }
        return inner.loadSummary(at: url)
    }
}
