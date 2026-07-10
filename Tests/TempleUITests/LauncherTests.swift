import XCTest
@testable import TempleUI
import TempleCore

final class LauncherTests: XCTestCase {

    func testClaudeSpecMintsIdAndInjectsIt() {
        let spec = SessionLauncher.newSession(agent: .claude, projectPath: "/p/a",
                                              claudePath: "/bin/claude", uuid: "uuid-1")
        XCTAssertEqual(spec.sessionID, "uuid-1")
        XCTAssertFalse(spec.isProvisional)
        XCTAssertEqual(spec.command.argv, ["/bin/claude", "--session-id", "uuid-1"])
        XCTAssertEqual(spec.command.cwd, "/p/a")
    }

    func testCodexSpecIsProvisional() {
        let spec = SessionLauncher.newSession(agent: .codex, projectPath: "/p/b", codexPath: "/bin/codex")
        XCTAssertNil(spec.sessionID)
        XCTAssertTrue(spec.isProvisional)
        XCTAssertEqual(spec.command.argv, ["/bin/codex"])
        XCTAssertEqual(spec.command.cwd, "/p/b")
    }

    func testResumeUsesSessionArgv() {
        let session = AgentSession(id: "sid", agent: .claude, projectPath: "/p/c", title: "t",
                                   createdAt: nil, updatedAt: Date(), filePath: URL(fileURLWithPath: "/tmp/x"))
        let cmd = SessionLauncher.resume(session)
        XCTAssertEqual(cmd.argv, ["claude", "--resume", "sid"])
        XCTAssertEqual(cmd.cwd, "/p/c")
    }
}
