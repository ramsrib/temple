import XCTest
@testable import TempleCore

final class StoreTests: XCTestCase {

    func testClaudeTextExtractionFromString() {
        XCTAssertEqual(ClaudeSessionStore.text(from: "hello"), "hello")
    }

    func testClaudeTextExtractionFromContentArray() {
        let content: [[String: Any]] = [["type": "text", "text": "build me a thing"]]
        XCTAssertEqual(ClaudeSessionStore.text(from: content), "build me a thing")
    }

    func testDecodeDirNameIsBestEffort() {
        XCTAssertEqual(
            ClaudeSessionStore.decodeDirName("-Users-sriram-Projects-active-raven"),
            "/Users/sriram/Projects/active/raven")
    }

    func testCleanTitleCollapsesAndCaps() {
        XCTAssertEqual(StoreIO.cleanTitle("  a\n  b\tc "), "a b c")
        XCTAssertEqual(StoreIO.cleanTitle(String(repeating: "x", count: 300)).count, 201)
    }

    func testIndexGroupsByProjectPath() {
        let base = URL(fileURLWithPath: "/tmp/x.jsonl")
        let s1 = AgentSession(id: "1", agent: .claude, projectPath: "/p/a",
                              title: "t1", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 10),
                              filePath: base)
        let s2 = AgentSession(id: "2", agent: .codex, projectPath: "/p/a",
                              title: "t2", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 20),
                              filePath: base)
        let s3 = AgentSession(id: "3", agent: .claude, projectPath: "/p/b",
                              title: "t3", createdAt: nil, updatedAt: Date(timeIntervalSince1970: 5),
                              filePath: base)

        let store = StubStore(sessions: [s1, s2, s3])
        let index = SessionIndex.build(stores: [store])

        XCTAssertEqual(index.projects.count, 2)
        // /p/a is most recently active → first.
        XCTAssertEqual(index.projects.first?.path, "/p/a")
        // Newest session within /p/a is first.
        XCTAssertEqual(index.projects.first?.sessions.first?.id, "2")
    }
}

private struct StubStore: SessionStore {
    let agent: Agent = .claude
    let sessions: [AgentSession]
    func loadSessions() -> [AgentSession] { sessions }
}
