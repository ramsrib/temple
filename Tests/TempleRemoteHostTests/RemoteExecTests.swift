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

    /// A child that leaves a descendant holding stderr open: the answer
    /// comes once the child has exited (after a short grace), and every
    /// descriptor the run opened is closed again.
    func testADescendantHoldingAStreamDoesNotHoldTheAnswerOrItsDescriptors() async throws {
        let tree = TempTree("descendant")
        let pidFile = tree.path + "/pid"
        let before = openDescriptors()
        let started = Date()
        let output = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 >&2 & echo $! > \(pidFile); echo out; exit 5"],
                                                 deadline: 20)
        XCTAssertEqual(output.status, 5)
        XCTAssertEqual(output.stdout, "out\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(openDescriptors(), before, "both read ends closed")
        if let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        // And at a deadline, with the child itself hung.
        let hung = openDescriptors()
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 >&2 & exec sleep 30"], deadline: 0.3)
            XCTFail("hung")
        } catch RemoteExecError.deadline {}
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(openDescriptors(), hung, "torn down at the deadline too")
    }

    /// The stdin writer is the run's own: a pipe-sized upload to a process
    /// whose descendant holds stdin open without reading is cut off when
    /// the run is answered, its descriptor closed with the readers, and
    /// nothing of Temple's is left waiting on the pipe.
    func testAnUploadToAStdinNobodyReadsIsTornDownWithTheRun() async throws {
        let tree = TempTree("stdin-holder")
        let pidFile = tree.path + "/pid"
        let before = openDescriptors()
        let payload = Data(repeating: 0x78, count: 4 << 20)
        let started = Date()
        // The shell exits at once; its child keeps stdin (and the output
        // streams) open and never reads.
        let output = try await ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & echo $! > \(pidFile); exit 0"],
                                                 input: payload, deadline: 10)
        XCTAssertEqual(output.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "answered after the drain grace, not the deadline")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(openDescriptors(), before, "the writer's descriptor closed with the readers")
        if let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        // And at a deadline, with the reader alive and not reading.
        let hung = openDescriptors()
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "exec sleep 30"], input: payload, deadline: 0.3)
            XCTFail("hung")
        } catch RemoteExecError.deadline {}
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(openDescriptors(), hung, "torn down at the deadline too")
        // A reader that does read gets every byte.
        let read = try await ProcessRunner.run("/bin/sh", ["-c", "wc -c | tr -d ' '"], input: payload, deadline: 10)
        XCTAssertEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), String(payload.count))
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    func testCancellationKillsTheProcess() async throws {
        let tree = TempTree("cancel")
        let pidFile = tree.path + "/pid"
        let task = Task { try await ProcessRunner.run("/bin/sh", ["-c", "echo $$ > \(pidFile); exec sleep 30"], deadline: 60) }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pid = try XCTUnwrap(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNotEqual(kill(pid, 0), 0, "the cancelled query's process is gone")
    }

    /// Cancelled at each point of setup, deterministically: the run answers
    /// CancellationError, starts no process, and leaves no descriptor open,
    /// readers registered after the answer included.
    func testCancellationDuringSetupLeavesNothingBehind() async throws {
        defer { ProcessRunner.setupHook = nil }
        for stage in [ProcessRunner.SetupStage.pipesCreated, .readersAttached] {
            let before = openDescriptors()
            let launches = RemoteProcessCounter.launches
            // The hook runs inside the run's own task, so cancelling the
            // current task lands exactly at this stage.
            ProcessRunner.setupHook = { reached in
                guard reached == stage else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], deadline: 60) }
            do { _ = try await task.value; XCTFail("cancelled at \(stage)") } catch is CancellationError {}
            XCTAssertEqual(RemoteProcessCounter.launches, launches, "\(stage): nothing started")
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(openDescriptors(), before, "\(stage): every descriptor closed")
        }
    }

    /// Cancelled before it starts: nothing is started at all.
    func testACancelledRunStartsNothing() async throws {
        let launches = RemoteProcessCounter.launches
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run("/bin/sleep", ["30"], deadline: 60)
        }
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {}
        XCTAssertEqual(RemoteProcessCounter.launches, launches)
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
