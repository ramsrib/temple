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
/// --version`, `codex --version`, `tmux -V`, the launch chain detached and
/// attached (in a pseudo-terminal, under `TERM=xterm-256color`), logind.
/// Nothing starts an agent session. No master is created: these runs use
/// `ControlMaster=no` throughout.
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

        // The attached chain, as the sheet's terminal runs it: ssh -t in a
        // pseudo-terminal, TERM=xterm-256color outside.
        let attachedNonce = RemoteQuoting.nonce()
        let remote = RemoteQuoting.shellCommand(script: TmuxCheck.attachedScript, args: [attachedNonce], path: path)
        let argv = ["/usr/bin/ssh"] + connection.arguments(for: .query).map { $0 == "-T" ? "-t" : $0 } + ["--", name, remote]
        var environmentForTerminal = ProcessInfo.processInfo.environment
        environmentForTerminal["TERM"] = "xterm-256color"
        let attached = try await ProcessRunner.run("/usr/bin/script", ["-q", "/dev/null"] + argv,
                                                   environment: environmentForTerminal, deadline: 30)
        lines.append("  attached client exit status \(attached.status)")

        let tmux = await TmuxCheck.run(nonce: RemoteQuoting.nonce(), attachedNonce: attachedNonce,
                                       attachedStatus: attached.status, using: exec)
        lines.append(ConnectionTest.row(tmux).line)
        guard case .accepted = tmux else { XCTFail("\(name): \(tmux)"); return }

        let logind = await LogindCheck.run(using: exec)
        lines.append(ConnectionTest.row(logind).line)

        let resolved = ConnectionTest.parseResolution(try await ProcessRunner.run(
            connection.resolutionArgv[0], Array(connection.resolutionArgv.dropFirst()), deadline: 5).stdout)
        let summary = HostTestSummary(connectedAs: resolved["user"].flatMap { user in resolved["hostname"].map { "\(user)@\($0)" } },
                                      environment: environment, claude: claude, codex: codex, tmux: tmux, logind: logind)
        lines.append("Status: \(summary.statusLine)")

        // Nothing left behind: no throwaway socket, no check files; the
        // record directory is removed when the check left it empty.
        let leftovers = try await exec.run(script: """
            d=${TMPDIR:-/tmp}/temple-launch-$(id -u)
            ls "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null | grep '^temple-check-' || true
            ls "$d" 2>/dev/null | grep '^check-' || true
            rmdir "$d" 2>/dev/null || true
            """, args: [], deadline: 10)
        XCTAssertEqual(leftovers.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "\(name) leftovers")
        print(lines.joined(separator: "\n"))
    }
}
