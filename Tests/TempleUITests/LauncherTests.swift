import XCTest
@testable import TempleUI
import TempleCore

final class LauncherTests: XCTestCase {

    func testClaudeSpecMintsIdAndCodexIsProvisional() {
        let claude = SessionLauncher.newSession(agent: .claude, projectPath: "/p/a", uuid: "uuid-1")
        XCTAssertEqual(claude.sessionID, "uuid-1")
        XCTAssertFalse(claude.isProvisional)
        XCTAssertEqual(claude.projectPath, "/p/a")
        let codex = SessionLauncher.newSession(agent: .codex, projectPath: "/p/b")
        XCTAssertNil(codex.sessionID)
        XCTAssertTrue(codex.isProvisional)
    }

    @MainActor
    func testTheLocalLauncherBuildsNewAndResumeArgvFromIntent() throws {
        let launcher = LocalHostLauncher(binaryPath: { "/bin/" + $0.binaryName })
        let new = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .new(sessionID: "uuid-1"), directory: "/p/a", host: .local))
        XCTAssertEqual(new.displayArgv, ["/bin/claude", "--session-id", "uuid-1"])
        let codex = try launcher.prepare(AgentLaunchSpec(agent: .codex, mode: .new(sessionID: nil), directory: "/p/b", host: .local))
        XCTAssertEqual(codex.displayArgv, ["/bin/codex"])
        let resume = try launcher.prepare(AgentLaunchSpec(agent: .claude, mode: .resume(sessionID: "sid"), directory: "/p/c", host: .local))
        XCTAssertEqual(resume.displayArgv, ["/bin/claude", "--resume", "sid"])
        XCTAssertEqual(resume.command.cwd, "/p/c")
        for launch in [new, codex, resume] { launch.result?.cancel() }
    }
}
