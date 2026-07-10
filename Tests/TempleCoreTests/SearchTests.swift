import XCTest
@testable import TempleCore

final class SearchTests: XCTestCase {
    private func session(
        id: String,
        title: String,
        path: String = "/work/temple",
        agent: Agent = .claude,
        updated: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(id: id, agent: agent, projectPath: path, title: title,
                     createdAt: nil, updatedAt: Date(timeIntervalSince1970: updated),
                     filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    private func index(_ sessions: [AgentSession]) -> SessionIndex {
        SessionIndex(projects: [Project(path: "/work/temple", sessions: sessions)])
    }

    func testRankingExactThenPrefixThenSubstring() {
        let value = index([
            session(id: "substring", title: "Fix the auth bug"),
            session(id: "exact", title: "auth"),
            session(id: "prefix", title: "Auth cleanup")
        ])
        XCTAssertEqual(value.search("auth").map(\.id), ["exact", "prefix", "substring"])
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(index([session(id: "one", title: "Build Parser")]).search("PARSER").map(\.id), ["one"])
    }

    func testProjectAndAgentMatches() {
        let projectSession = session(id: "project", title: "Unrelated", path: "/work/Temple")
        let agentSession = session(id: "agent", title: "Other", path: "/work/else", agent: .codex)
        let value = SessionIndex(projects: [
            Project(path: projectSession.projectPath, sessions: [projectSession]),
            Project(path: agentSession.projectPath, sessions: [agentSession])
        ])
        XCTAssertEqual(value.search("temple").map(\.id), ["project"])
        XCTAssertEqual(value.search("codex").map(\.id), ["agent"])
    }

    func testNoMatchAndEmptyQueryReturnEmpty() {
        let value = index([session(id: "one", title: "Build")])
        XCTAssertTrue(value.search("missing").isEmpty)
        XCTAssertTrue(value.search("  ").isEmpty)
    }
}
