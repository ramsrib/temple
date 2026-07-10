import XCTest
@testable import TempleCore

final class CachedIndexStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-index-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index-cache.json")
    }

    private func session(
        _ id: String,
        project: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: id.hasPrefix("c") ? .codex : .claude,
            projectPath: project,
            title: "Session \(id)",
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            messageCount: 3,
            model: "test-model",
            lastMessagePreview: "Preview",
            gitBranch: "main",
            originator: "test"
        )
    }

    private func smallIndex() -> SessionIndex {
        SessionIndex(projects: [
            Project(path: "/projects/one", sessions: [
                session("a1", project: "/projects/one"),
                session("c1", project: "/projects/one"),
            ]),
            Project(path: "/projects/two", sessions: [
                session("a2", project: "/projects/two"),
            ]),
        ])
    }

    func testRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let index = smallIndex()
        try CachedIndexStore.save(index, to: url)

        XCTAssertEqual(CachedIndexStore.load(from: url), index)
    }

    func testSchemaVersionMismatchReturnsNil() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CachedIndexStore.save(smallIndex(), to: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertNil(CachedIndexStore.load(from: url))
    }

    func testCorruptFileReturnsNil() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not JSON".utf8).write(to: url)

        XCTAssertNil(CachedIndexStore.load(from: url))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(CachedIndexStore.load(from: temporaryURL()))
    }

    func testUnknownSessionFieldIsIgnored() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CachedIndexStore.save(smallIndex(), to: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var index = try XCTUnwrap(object["index"] as? [String: Any])
        var projects = try XCTUnwrap(index["projects"] as? [[String: Any]])
        var sessions = try XCTUnwrap(projects[0]["sessions"] as? [[String: Any]])
        sessions[0]["futureField"] = "x"
        projects[0]["sessions"] = sessions
        index["projects"] = projects
        object["index"] = index
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertEqual(CachedIndexStore.load(from: url), smallIndex())
    }

    func testRealisticCacheLoadsUnderTwoHundredMilliseconds() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let projects = (0..<50).map { projectNumber in
            let path = "/projects/\(projectNumber)"
            let sessions = (0..<10).map { sessionNumber in
                session(
                    "p\(projectNumber)-s\(sessionNumber)",
                    project: path,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000
                                    + Double(projectNumber * 10 + sessionNumber))
                )
            }
            return Project(path: path, sessions: sessions)
        }
        let index = SessionIndex(projects: projects)
        try CachedIndexStore.save(index, to: url)

        let start = ContinuousClock.now
        let loaded = CachedIndexStore.load(from: url)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(loaded, index)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }
}
