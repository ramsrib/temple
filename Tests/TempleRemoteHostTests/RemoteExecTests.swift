import Foundation
import XCTest
@testable import TempleRemoteHost

final class RemoteExecTests: XCTestCase {
    func testStreamsAreSeparateAndTheStatusIsKept() async throws {
        let output = try await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], deadline: 5)
        XCTAssertEqual(output, ProcessRunner.Output(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    func testTheDeadlineKillsTheProcessAndAnswers() async throws {
        let tree = TempTree("deadline")
        let pidFile = tree.path + "/pid"
        let started = Date()
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "echo $$ > \(pidFile); exec sleep 30"], deadline: 0.5)
            XCTFail("a hung command must not answer normally")
        } catch let error as RemoteExecError {
            XCTAssertEqual(error, .deadline(seconds: 0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNotEqual(kill(pid, 0), 0, "the query's process is gone")
    }

    func testCancellationKillsTheProcess() async throws {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], deadline: 60) }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testALaunchFailureSaysWhy() async {
        do {
            _ = try await ProcessRunner.run("/nonexistent/ssh", [], deadline: 1)
            XCTFail("no such binary")
        } catch let error as RemoteExecError {
            guard case .launchFailed = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    /// The whole query path through a stand-in `ssh` that, like sshd, hands
    /// the remote command to a login shell (zsh here) after rc chatter on
    /// both streams. The chatter is discarded; the arguments arrive intact;
    /// the argv names the host after `--` and carries no control command.
    func testSSHExecFramesOffLoginChatterAndPassesArgumentsWhole() async throws {
        let tree = TempTree("fake-ssh")
        let log = tree.path + "/argv"
        let ssh = tree.write("ssh", """
        #!/bin/sh
        printf '%s\\n' "$@" > \(log)
        while [ "$1" != "--" ]; do shift; done
        shift; host=$1; shift
        echo "Welcome to $host (rc chatter)"; echo "motd noise" >&2
        exec /bin/zsh -f -c "$1"
        """, executable: true)
        let connection = SSHConnection(record: .config("box"), stateDirectory: tree.url, sshPath: ssh.path)
        let exec = SSHExec(connection: connection, path: "/usr/bin:/bin")
        let output = try await exec.run(script: #"printf '%s|' "$@"; echo "$PATH"; echo oops >&2; exit 4"#,
                                        args: ["it's", "a b", "back\\slash"], deadline: 5)
        XCTAssertEqual(output.status, 4)
        XCTAssertEqual(output.stdout, "it's|a b|back\\slash|/usr/bin:/bin\n")
        XCTAssertEqual(output.stderr, "oops\n")
        let argv = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        XCTAssertTrue(argv.contains("ControlMaster=no"))
        XCTAssertFalse(argv.contains("-O"))
        XCTAssertEqual(argv[argv.firstIndex(of: "--")! + 1], "box")
    }

    func testAnSSHFailureKeepsSSHsOwnWords() {
        let raw = ProcessRunner.Output(status: 255, stdout: "",
                                       stderr: "ssh: connect to host box port 22: Connection refused\n")
        let output = SSHExec.unframe(raw, marker: "__temple_x__")
        XCTAssertEqual(output.status, 255)
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(output.firstErrorLine, "ssh: connect to host box port 22: Connection refused")
    }

    func testLocalShellExecRunsTheSameCommandShape() async throws {
        let exec = LocalShellExec(path: "/custom/bin:/usr/bin:/bin")
        let output = try await exec.run(script: #"echo "$PATH|$1""#, args: ["x y"], deadline: 5)
        XCTAssertEqual(output.stdout, "/custom/bin:/usr/bin:/bin|x y\n")
        XCTAssertEqual(output.status, 0)
    }
}

final class RemoteEnvironmentTests: XCTestCase {
    /// zsh, login and interactive, reads its rc (which prints chatter and
    /// extends PATH); only what the frame holds is taken.
    func testTheLoginShellsPATHIsReadBetweenFrames() async throws {
        let tree = TempTree("env")
        tree.write(".zshrc", """
        echo "Welcome! motd line"
        echo "__temple_path_fake__"
        export PATH=/custom/bin:$PATH
        """)
        let exec = LocalShellExec(path: nil, environment: hostEnvironment(home: tree.path, path: "/usr/bin:/bin",
            extra: ["SHELL": "/bin/zsh", "ZDOTDIR": tree.path]))
        let environment = await RemoteEnvironment.resolve(using: exec)
        XCTAssertEqual(environment.shell, "/bin/zsh")
        XCTAssertNil(environment.problem)
        XCTAssertEqual(environment.path?.hasPrefix("/custom/bin:"), true, String(describing: environment.path))
    }

    func testAShellThatGivesNoPATHIsAProblemNotAGuess() async throws {
        let tree = TempTree("env-none")
        let shell = tree.write("noshell", "#!/bin/sh\necho 'I print nothing useful'\n", executable: true)
        let exec = LocalShellExec(path: nil, environment: hostEnvironment(home: tree.path, path: "/usr/bin:/bin",
                                                                          extra: ["SHELL": shell.path]))
        let environment = await RemoteEnvironment.resolve(using: exec)
        XCTAssertNil(environment.path)
        XCTAssertEqual(environment.problem, "\(shell.path) printed no PATH")
    }

    func testTransportFailuresAndDeadlinesProveNothing() async {
        let unreachable = RecordingExec { _, _ in RemoteOutput(status: 255, stdout: "", stderr: "ssh: Could not resolve hostname box\n") }
        let environment = await RemoteEnvironment.resolve(using: unreachable)
        XCTAssertNil(environment.path)
        XCTAssertEqual(environment.problem, "ssh: Could not resolve hostname box")
        let hung = RecordingExec { _, _ in throw RemoteExecError.deadline(seconds: 5) }
        let late = await RemoteEnvironment.resolve(using: hung)
        XCTAssertEqual(late.problem, "the login shell didn't answer within 5 seconds")
        XCTAssertEqual(hung.calls.count, 1, "one query")
    }
}
