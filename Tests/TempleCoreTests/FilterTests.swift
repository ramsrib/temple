import XCTest
@testable import TempleCore

final class FilterTests: XCTestCase {
    private func session(path: String) -> AgentSession {
        AgentSession(
            id: UUID().uuidString,
            agent: .codex,
            projectPath: path,
            title: "Work",
            createdAt: nil,
            updatedAt: Date(),
            filePath: URL(fileURLWithPath: "/tmp/session.jsonl")
        )
    }

    func testRootCwdIsNoise() {
        XCTAssertTrue(SessionFilter.isNoise(session(path: "/"), pathExists: { _ in true }))
    }

    func testMissingCwdIsNoise() {
        XCTAssertTrue(SessionFilter.isNoise(session(path: "/gone"), pathExists: { _ in false }))
    }

    func testOrdinaryExistingSessionIsNotNoise() {
        XCTAssertFalse(SessionFilter.isNoise(session(path: "/work/project"), pathExists: { _ in true }))
    }

    func testFilteringCanIncludeNoise() {
        let sessions = [session(path: "/"), session(path: "/work")]
        XCTAssertEqual(SessionFilter.filtered(sessions, includeNoise: true, pathExists: { _ in true }).count, 2)
        XCTAssertEqual(SessionFilter.filtered(sessions, includeNoise: false, pathExists: { _ in true }).count, 1)
    }
}
