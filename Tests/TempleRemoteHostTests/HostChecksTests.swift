import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

final class HostChecksTests: XCTestCase {
    /// A stand-in host: a temp HOME, a bin directory on PATH holding
    /// whatever the test puts there, and the system's sh tools.
    private func host(_ tree: TempTree, extraPath: [String] = []) -> LocalShellExec {
        let bin = tree.directory("bin").path
        let path = ([bin] + extraPath + ["/usr/bin", "/bin"]).joined(separator: ":")
        return LocalShellExec(path: path, environment: hostEnvironment(home: tree.path, path: "/usr/bin:/bin"))
    }

    func testToolChecksKeepEachToolsOwnWords() async throws {
        let tree = TempTree("tools")
        tree.write("bin/claude", "#!/bin/sh\necho '2.1.283 (Claude Code)'\n", executable: true)
        tree.write("bin/codex", "#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n", executable: true)
        let exec = host(tree)
        let claude = await ToolCheck.run("claude", using: exec)
        XCTAssertEqual(claude, .runs(path: tree.path + "/bin/claude", version: "2.1.283 (Claude Code)",
                                     output: "2.1.283 (Claude Code)"))
        let codex = await ToolCheck.run("codex", using: exec)
        XCTAssertEqual(codex, .fails(path: tree.path + "/bin/codex", status: 127,
                                     firstLine: "env: node: No such file or directory",
                                     output: "env: node: No such file or directory"))
        let missing = await ToolCheck.run("definitely-not-installed", using: exec)
        XCTAssertEqual(missing, .missing)
        XCTAssertTrue(codex.provesUnavailable)
        XCTAssertTrue(missing.provesUnavailable)
        XCTAssertFalse(claude.provesUnavailable)
        let unreachable = await ToolCheck.run("claude", using: RecordingExec { _, _ in throw RemoteExecError.deadline(seconds: 10) })
        XCTAssertEqual(unreachable, .notChecked(reason: "Didn't answer within 10 seconds."))
        XCTAssertFalse(unreachable.provesUnavailable, "a check that never ran proves nothing")
    }

    func testTmuxVersions() {
        XCTAssertEqual(TmuxVersion("tmux 3.2a")?.description, "3.2a")
        XCTAssertEqual(TmuxVersion("tmux 3.4"), TmuxVersion(major: 3, minor: 4))
        XCTAssertEqual(TmuxVersion("tmux next-3.5")?.description, "3.5")
        XCTAssertNil(TmuxVersion("tmux master"))
        XCTAssertTrue(TmuxVersion("tmux 3.2a")! >= TmuxChain.floor)
        XCTAssertTrue(TmuxVersion("tmux 3.1c")! < TmuxChain.floor)
        XCTAssertTrue(TmuxVersion("tmux 3.2a")! < TmuxChain.passthroughSince)
        XCTAssertTrue(TmuxVersion("tmux 3.10")! > TmuxVersion("tmux 3.9")!)
    }

    /// A stub tmux that records every invocation and refuses `prefix None`,
    /// as a tmux older than the floor does: the check names the command
    /// and keeps tmux's line.
    func testARefusedCommandIsNamedWithTmuxsOwnLine() async throws {
        let tree = TempTree("tmux-stub")
        let log = tree.path + "/calls"
        tree.write("bin/tmux", """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(log)
        [ "$1" = "-V" ] && { echo 'tmux 3.0a'; exit 0; }
        case "$*" in *"prefix None"*) echo 'invalid key: None' >&2; exit 1 ;; esac
        exit 0
        """, executable: true)
        let check = await TmuxCheck.run(nonce: "abc", attachedNonce: nil, attachedStatus: nil, using: host(tree))
        XCTAssertEqual(check, .refused(version: "3.0a", command: "prefix None", line: "invalid key: None"))
        XCTAssertEqual(HostTestSummary(tmux: check).statusLine, "Connected. tmux 3.0a refused the launch chain: invalid key: None")
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("-L temple-check-abc -f /dev/null start-server ; set -g default-shell /bin/sh ;"),
                      "the chain, one queue, on a throwaway socket: \(calls)")
        XCTAssertTrue(calls.contains("new-session -d -s check -c \(tree.path) -e PATH="))
        XCTAssertTrue(calls.contains("kill-server"))
        XCTAssertFalse(calls.contains("-L temple "), "never Temple's own server")
    }

    func testNoTmuxIsMissing() async throws {
        let tree = TempTree("no-tmux")
        // A PATH with sh's tools but no tmux at all.
        let exec = LocalShellExec(path: tree.directory("bin").path + ":/usr/bin:/bin",
                                  environment: hostEnvironment(home: tree.path, path: "/usr/bin:/bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/usr/bin/tmux"), "this Mac's /usr/bin has no tmux")
        let check = await TmuxCheck.run(nonce: "n", attachedNonce: nil, attachedStatus: nil, using: exec)
        XCTAssertEqual(check, .missing)
        XCTAssertEqual(HostTestSummary(tmux: check).statusLine,
                       "Connected. No tmux on this host. Install tmux 3.2 or newer to start sessions here.")
    }

    /// The real launch chain against this Mac's tmux, on a throwaway socket
    /// that is gone afterwards; and an attached client in a pseudo-terminal
    /// under `TERM=xterm-256color`, whose pane draws under `tmux-256color`.
    func testTheRealChainIsAcceptedDetachedAndAttached() async throws {
        guard let tmux = installedTmux() else { throw XCTSkip("no tmux installed (brew install tmux)") }
        let tree = TempTree("tmux-real")
        let tmuxDirectory = (tmux as NSString).deletingLastPathComponent
        let exec = LocalShellExec(path: "\(tmuxDirectory):/usr/bin:/bin",
                                  environment: hostEnvironment(home: tree.path, path: "/usr/bin:/bin",
                                                               extra: ["TMUX_TMPDIR": tree.path]))
        // Attached, through script(1) for a terminal.
        let attachedNonce = "att\(UInt32.random(in: 0...UInt32.max))"
        let attached = RemoteQuoting.shellCommand(script: TmuxCheck.attachedScript, args: [attachedNonce],
                                                  path: "\(tmuxDirectory):/usr/bin:/bin")
        var environment = hostEnvironment(home: tree.path, path: "/usr/bin:/bin", extra: ["TMUX_TMPDIR": tree.path])
        environment["TERM"] = "xterm-256color"
        let terminal = try await ProcessRunner.run("/usr/bin/script", ["-q", "/dev/null", "/bin/sh", "-c", attached],
                                                   environment: environment, deadline: 20)
        XCTAssertEqual(terminal.status, 0, terminal.stdout + terminal.stderr)

        let check = await TmuxCheck.run(nonce: "n\(UInt32.random(in: 0...UInt32.max))", attachedNonce: attachedNonce,
                                        attachedStatus: terminal.status, using: exec)
        guard case .accepted(let version, let passthrough) = check else { return XCTFail("\(check)") }
        XCTAssertEqual(passthrough, TmuxVersion("tmux \(version)").map { $0 >= TmuxChain.passthroughSince } ?? true)
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: tree.path)
            .filter { $0.contains("temple-check") || $0.hasPrefix("tmp/temple-launch") && $0.contains("check-") }
        XCTAssertEqual(leftovers, [], "the throwaway socket and the attached check's files are removed")
    }

    func testAnAttachedFailureIsReportedWithItsReason() {
        let output = RemoteOutput(status: 0, stdout: "attached-error\topen terminal failed: missing or unsuitable terminal: xterm-ghostty\nversion\ttmux 3.4\nchain\t0\n", stderr: "")
        XCTAssertEqual(TmuxCheck.parse(output, attachedStatus: 1),
                       .attachedFailed(version: "3.4", line: "open terminal failed: missing or unsuitable terminal: xterm-ghostty"))
        XCTAssertEqual(TmuxCheck.parse(RemoteOutput(status: 0, stdout: "version\ttmux 3.4\nchain\t0\n", stderr: ""), attachedStatus: 124),
                       .attachedFailed(version: "3.4", line: "the attached check didn't finish within 30 seconds"))
        XCTAssertEqual(TmuxCheck.parse(RemoteOutput(status: 0, stdout: "version\ttmux 3.2a\nchain\t0\n", stderr: ""), attachedStatus: 0),
                       .accepted(version: "3.2a", passthrough: false))
        XCTAssertEqual(TmuxCheck.parse(RemoteOutput(status: 0, stdout: "version\ttmux 3.1c\nchain\t0\n", stderr: ""), attachedStatus: 0),
                       .tooOld(version: "3.1c"))
    }

    func testLogind() {
        XCTAssertEqual(LogindCheck.parse(RemoteOutput(status: 0, stdout: "busctl\t0\nb true\n", stderr: "")), .killsUserProcesses(true))
        XCTAssertEqual(LogindCheck.parse(RemoteOutput(status: 0, stdout: "busctl\t0\nb false\n", stderr: "")), .killsUserProcesses(false))
        XCTAssertEqual(LogindCheck.parse(RemoteOutput(status: 0, stdout: "nobusctl\n", stderr: "")),
                       .notAvailable(reason: "no busctl on this host"))
        XCTAssertEqual(LogindCheck.parse(RemoteOutput(status: 0, stdout: "busctl\t1\nFailed to connect to bus\n", stderr: "")),
                       .notAvailable(reason: "Failed to connect to bus"))
    }

    /// Captured stderr from OpenSSH 10: an unknown key in BatchMode, a
    /// changed key, and ordinary failures.
    func testHostKeyClassification() {
        XCTAssertEqual(SSHFailure.classify(stderr: "No ED25519 host key is known for box and you have requested strict checking.\r\nHost key verification failed.\r\n", status: 255),
                       .unknownHostKey)
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the ED25519 key sent by the remote host is
        SHA256:abc.
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
        Offending ED25519 key in /Users/me/.ssh/known_hosts:12
        Host key for box has changed and you have requested strict checking.
        Host key verification failed.
        """
        let failure = SSHFailure.classify(stderr: changed, status: 255)
        XCTAssertEqual(failure, .changedHostKey(offending: "Offending ED25519 key in /Users/me/.ssh/known_hosts:12"))
        XCTAssertEqual(failure.message, "ssh says this host's key has changed and will not connect. Temple won't change your known_hosts; check the host first. ssh named the line: Offending ED25519 key in /Users/me/.ssh/known_hosts:12.")
        XCTAssertFalse(failure.allowsRetry)
        XCTAssertEqual(SSHFailure.unknownHostKey.message,
                       "ssh hasn't seen this host's key before. Test the connection to check it and confirm it.")
        XCTAssertEqual(SSHFailure.classify(stderr: "Warning: Permanently added 'box' (ED25519) to the list of known hosts.\r\nme@box: Permission denied (publickey).\r\n", status: 255),
                       .other(firstLine: "me@box: Permission denied (publickey)."))
        XCTAssertEqual(SSHFailure.other(firstLine: "me@box: Permission denied (publickey).").message,
                       "Couldn't connect: me@box: Permission denied (publickey).")
        XCTAssertEqual(SSHFailure.classify(stderr: "", status: 255), .other(firstLine: "ssh exited with status 255"))
    }

    func testStatusLines() {
        let path = RemoteEnvironment(shell: "/bin/bash", path: "/usr/bin", problem: nil)
        let healthy = HostTestSummary(connectedAs: "mentes@10.0.0.2", environment: path,
            claude: .runs(path: "/home/mentes/.local/bin/claude", version: "2.1.283 (Claude Code)", output: ""),
            codex: .runs(path: "/home/mentes/.local/bin/codex", version: "codex-cli 0.52.0", output: ""),
            tmux: .accepted(version: "3.4", passthrough: true), logind: .killsUserProcesses(false))
        XCTAssertEqual(healthy.statusLine, "Connected as mentes@10.0.0.2. Claude Code 2.1.283, Codex 0.52.0, tmux 3.4.")
        XCTAssertNil(healthy.unavailableReason(for: .claude))

        var broken = healthy
        broken.claude = .missing
        broken.codex = .fails(path: "/x/codex", status: 1, firstLine: "Error: something", output: "")
        broken.tmux = .accepted(version: "3.2a", passthrough: false)
        broken.environment = RemoteEnvironment(shell: "/bin/bash", path: nil, problem: "the login shell didn't answer within 5 seconds")
        XCTAssertEqual(broken.statusLine, "Connected as mentes@10.0.0.2. tmux 3.2a. No claude on PATH. codex is there but didn't run: Error: something. tmux 3.2a: clipboard passthrough is off on this version. Couldn't read the login shell's PATH: the login shell didn't answer within 5 seconds; using ssh's default environment.")
        XCTAssertEqual(broken.unavailableReason(for: .claude), "No claude on PATH.")
        XCTAssertEqual(broken.unavailableReason(for: .codex), "codex is there but didn't run: Error: something.")

        var old = healthy
        old.tmux = .tooOld(version: "3.0a")
        XCTAssertEqual(old.unavailableReason(for: .claude), "tmux 3.0a: Temple needs tmux 3.2 or newer to keep sessions running.")
        let unreachable = HostTestSummary(failure: .other(firstLine: "ssh: connect to host box port 22: Operation timed out"))
        XCTAssertEqual(unreachable.statusLine, "Couldn't connect: ssh: connect to host box port 22: Operation timed out.")
        XCTAssertNil(unreachable.unavailableReason(for: .claude), "couldn't connect proves nothing")
        XCTAssertEqual(HostTestSummary.notTested, "Not tested yet. Test the connection to check this host.")
    }
}
