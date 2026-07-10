import XCTest
@testable import TempleCore

final class WatcherTests: XCTestCase {
    func testWatcherYieldsUpdatedIndexAfterNewSessionFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = SessionWatcher(
            stores: [ClaudeSessionStore(root: root)],
            debounceInterval: 0.1
        )
        let received = expectation(description: "updated index")
        let task = Task {
            var isInitial = true
            for await index in watcher.start() {
                if isInitial {
                    isInitial = false
                    let file = project.appendingPathComponent("new-session.jsonl")
                    let json = #"{"type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
                    try json.write(to: file, atomically: true, encoding: .utf8)
                } else if index.allSessions.contains(where: { $0.id == "new-session" }) {
                    received.fulfill()
                    break
                }
            }
        }

        await fulfillment(of: [received], timeout: 5)
        watcher.stop()
        task.cancel()
    }

    func testWatcherIncrementallyReloadsOneOfTwoHundredSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-scale-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstLine = #"{"type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        for index in 0..<200 {
            try firstLine.write(
                to: project.appendingPathComponent("session-\(index).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }

        let watcher = SessionWatcher(
            stores: [ClaudeSessionStore(root: root)],
            debounceInterval: 0.05
        )
        let received = expectation(description: "incremental update")
        let target = project.appendingPathComponent("session-100.jsonl")
        let task = Task {
            var mutationTime: Date?
            for await index in watcher.start() {
                if mutationTime == nil {
                    guard index.allSessions.count == 200 else { continue }
                    mutationTime = Date()
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(("\n" + #"{"type":"assistant","message":{"content":"updated"}}"#).utf8))
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
        watcher.stop()
        task.cancel()
    }

    func testWatcherDoesNotStarveUpdatesDuringSteadyEventStream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-watcher-steady-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = project.appendingPathComponent("streaming-session.jsonl")
        let firstLine = #"{"type":"user","message":{"content":"hello"},"cwd":"/tmp/project","timestamp":"2026-01-01T00:00:00Z"}"#
        try firstLine.write(to: session, atomically: true, encoding: .utf8)

        let watcher = SessionWatcher(
            stores: [ClaudeSessionStore(root: root)],
            debounceInterval: 0.3
        )
        let initial = expectation(description: "initial index")
        let updatedWhileAppending = expectation(description: "update before steady appends stop")
        let watchTask = Task {
            var receivedInitial = false
            for await index in watcher.start() {
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
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        await fulfillment(of: [updatedWhileAppending], timeout: 1.5)
        appendTask.cancel()
        _ = try? await appendTask.value
        watcher.stop()
        watchTask.cancel()
    }
}
