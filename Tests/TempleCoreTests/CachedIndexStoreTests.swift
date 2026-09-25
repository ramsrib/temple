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

    /// A cache written before ADR-024 files Codex subagents under their
    /// parent's id; it must not survive the upgrade that stopped doing that.
    func testAVersionOneCacheIsNotLoaded() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CachedIndexStore.save(smallIndex(), to: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        XCTAssertNil(CachedIndexStore.load(from: url))
    }

    /// What `templectl --import-all` gates on. Set, empty and the real
    /// directory spelled another way must all read as "not redirected".
    func testStateIsRedirectedOnlyToADirectoryOtherThanTheRealOne() {
        let key = "TEMPLE_STATE_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }
        let real = TempleState.defaultDirectory.path

        unsetenv(key)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, "", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real, 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real + "/", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, real + "/../Temple", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, "~/Library/Application Support/Temple", 1)
        XCTAssertFalse(TempleState.isRedirected)
        setenv(key, FileManager.default.temporaryDirectory.appendingPathComponent("temple-demo-state").path, 1)
        XCTAssertTrue(TempleState.isRedirected)
    }

    /// A fresh install has no state dir yet, which is exactly when a spelling
    /// of it that Foundation will not resolve could slip past the guard.
    func testCanonicalPathMatchesMissingDirectoriesAcrossCaseAndSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("temple-canonical-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("Real", isDirectory: true)
        let link = base.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        let missing = target.appendingPathComponent("Application Support/Temple")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let recased = URL(fileURLWithPath: missing.path.replacingOccurrences(of: "Real/Application", with: "real/application"))
        let throughLink = link.appendingPathComponent("Application Support/Temple")

        XCTAssertEqual(TempleState.canonicalPath(recased), TempleState.canonicalPath(missing))
        XCTAssertEqual(TempleState.canonicalPath(throughLink), TempleState.canonicalPath(missing))
        XCTAssertNotEqual(TempleState.canonicalPath(base.appendingPathComponent("Other/Temple")),
                          TempleState.canonicalPath(missing))
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
