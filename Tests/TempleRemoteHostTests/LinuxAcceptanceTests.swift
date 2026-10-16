import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Linux acceptance of the exec layer and the Test connection's checks,
/// against real hosts. Opt-in, so the normal suite never touches the
/// network:
///
///     TEMPLE_REMOTE_ACCEPTANCE=masterblaster-mentes,jetson-mentes swift test --filter LinuxAcceptanceTests
///
/// Each name is an `~/.ssh/config` alias reachable without a prompt
/// (`BatchMode`). Read-only on the host except a throwaway tmux socket and
/// the check's record files, all removed: the environment, `claude
/// --version`, `codex --version`, `tmux -V`, the launch chain detached on a
/// throwaway socket, logind. (An attached client under `xterm-256color`
/// with a `tmux-256color` pane is phase 1a's acceptance.)
/// Nothing starts an agent session. The connect creates a master on a
/// socket under a temp state directory, as the Test sheet does, and the
/// queries ride it; the test ends that master itself when done (Temple
/// never does).
final class LinuxAcceptanceTests: XCTestCase {
    private var hosts: [String] {
        (ProcessInfo.processInfo.environment["TEMPLE_REMOTE_ACCEPTANCE"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func testEveryCheckOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        let state = TempTree("acceptance-state")
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            try await check(name, stateDirectory: state.url)
        }
    }

    private func check(_ name: String, stateDirectory: URL) async throws {
        let connection = SSHConnection(record: .config(name), stateDirectory: stateDirectory, sshPath: "/usr/bin/ssh")
        var lines: [String] = ["== \(name)"]

        // The Test connection's evidence: no master before the connect,
        // one after it (the sheet's terminal runs these same arguments; `-T`
        // here only because there is no terminal; the keys need no answer).
        try connection.prepareSocketDirectory()
        let check = connection.masterCheckArgv
        let before = try await ProcessRunner.run(check[0], Array(check.dropFirst()), deadline: 5)
        XCTAssertNotEqual(before.status, 0, "\(name): no master yet")
        let connect = connection.argv(.interactive, remoteCommand: "true").map { $0 == "-t" ? "-T" : $0 }
        let connected = try await ProcessRunner.run(connect[0], Array(connect.dropFirst()) + [], deadline: 30)
        XCTAssertEqual(connected.status, 0, "\(name): \(connected.stderr)")
        let after = try await ProcessRunner.run(check[0], Array(check.dropFirst()), deadline: 5)
        XCTAssertEqual(after.status, 0, "\(name): the connect left a master")
        lines.append("Master after connect: \(after.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        defer {
            // Test cleanup only: Temple itself never ends a master. This one
            // is the test's own, on a socket in a directory it removes.
            let exit = [check[0], check[1], check[2], "-O", "exit", "--", name]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exit[0])
            process.arguments = Array(exit.dropFirst())
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }

        let environment = await RemoteEnvironment.resolve(using: SSHExec(connection: connection, path: nil))
        XCTAssertNil(environment.problem, name)
        let path = try XCTUnwrap(environment.path, name)
        lines.append("Login shell: \(environment.shell), PATH read.")
        lines.append("  PATH=\(path)")
        // ssh's default command environment, for comparison only.
        let defaultPath = try await SSHExec(connection: connection, path: nil)
            .run(script: "printf '%s\\n' \"$PATH\"", args: [], deadline: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("  ssh default PATH=\(defaultPath)")

        let exec = SSHExec(connection: connection, path: path)
        let claude = await ToolCheck.run("claude", using: exec)
        let codex = await ToolCheck.run("codex", using: exec)
        for (binary, check) in [("claude", claude), ("codex", codex)] {
            lines.append(ConnectionTest.row(binary, check).line)
            guard case .runs(let found, _, _) = check else { XCTFail("\(name): \(binary) \(check)"); continue }
            XCTAssertTrue(found.hasSuffix("/.local/bin/\(binary)"), "\(name): \(found)")
        }

        let tmux = await TmuxCheck.run(nonce: RemoteQuoting.nonce(), using: exec)
        lines.append(ConnectionTest.row(tmux).line)
        guard case .accepted = tmux else { XCTFail("\(name): \(tmux)"); return }

        let logind = await LogindCheck.run(using: exec)
        lines.append(ConnectionTest.row(logind).line)

        let resolved = ConnectionTest.parseResolution(try await ProcessRunner.run(
            connection.resolutionArgv[0], Array(connection.resolutionArgv.dropFirst()), deadline: 5).stdout)
        let summary = HostTestSummary(connectedAs: resolved["user"].flatMap { user in resolved["hostname"].map { "\(user)@\($0)" } },
                                      environment: environment, claude: claude, codex: codex, tmux: tmux, logind: logind)
        lines.append("Status: \(summary.statusLine)")

        // Nothing left behind: no throwaway socket.
        let leftovers = try await exec.run(script: """
            ls "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null | grep '^temple-check-' || true
            """, args: [], deadline: 10)
        XCTAssertEqual(leftovers.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "\(name) leftovers")
        print(lines.joined(separator: "\n"))
    }
}
