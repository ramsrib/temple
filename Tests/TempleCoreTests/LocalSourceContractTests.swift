import XCTest
import CoreServices
@testable import TempleCore

final class LocalSourceContractTests: XCTestCase {
    func testCatalogQueryFiltersAgentsAndOrdersBatches() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p6-catalog-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, seconds) in [("older", 1.0), ("newer", 2.0)] {
            let file = project.appendingPathComponent("\(id).jsonl")
            try "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"message\":{\"content\":\"Fact\"}}".write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
        }
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root)])
        var ids: [String] = []
        for try await batch in source.catalog(CatalogQuery(agents: [.claude], newestFirst: false, batchSize: 1)) {
            if case .sessions(let summaries, _, _) = batch { ids += summaries.map(\.id) }
        }
        XCTAssertEqual(ids, ["older", "newer"])
        var excluded: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery(agents: [.codex])) { excluded.append(batch) }
        XCTAssertEqual(excluded, [.listed(total: 0)])
    }

    func testChangesNameOnlyTheAffectedRegisteredSession() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p6-changes-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["one", "two"] {
            try "{\"type\":\"user\",\"sessionId\":\"\(id)\"}".write(to: project.appendingPathComponent("\(id).jsonl"), atomically: false, encoding: .utf8)
        }
        let source = LocalSessionSource(stores: [ClaudeSessionStore(root: root)], debounceInterval: 0.01)
        let changes = source.changes()
        defer { source.release(["one", "two"]) }
        let changed = expectation(description: "semantic invalidation")
        let reader = Task { () throws -> [String] in
            for try await change in changes {
                if case .sessions(let ids) = change { changed.fulfill(); return ids }
            }
            return []
        }
        _ = try await source.resolve([ResolutionRequest(id: "one"), ResolutionRequest(id: "two")])
        let file = project.appendingPathComponent("one.jsonl")
        try FileManager.default.removeItem(at: file)
        source.reconcileEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        await fulfillment(of: [changed], timeout: 3)
        reader.cancel()
        let ids = try await reader.value
        XCTAssertEqual(ids, ["one"])
    }

    func testLocalAdoptionCancellationReleasesItsObservationWindow() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-p6-adopt-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LocalSessionSource(stores: [CodexSessionStore(root: root)], debounceInterval: 0.01)
        let task = Task { try await source.adopt(AdoptionRequest(directory: "/project", startedAt: Date(), window: 60)) }
        let deadline = Date().addingTimeInterval(2)
        while !source.isMonitoring, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = try? await task.value
        let stopped = Date().addingTimeInterval(2)
        while source.isMonitoring, Date() < stopped { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(source.isMonitoring)
    }
}
