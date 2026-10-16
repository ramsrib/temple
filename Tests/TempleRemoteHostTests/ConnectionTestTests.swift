import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

@MainActor
final class ConnectionTestTests: XCTestCase {
    private func makeTest(_ tree: TempTree, exec: @escaping (String?) -> RemoteExec) -> ConnectionTest {
        let connection = SSHConnection(record: .config("box"), stateDirectory: tree.directory("state"), sshPath: "/usr/bin/ssh")
        return ConnectionTest(record: .config("box"), connection: connection, workDirectory: tree.url.appendingPathComponent("work"),
                              makeExec: exec, resolve: { ["user": "mentes", "hostname": "10.0.0.2"] },
                              pollInterval: .milliseconds(20))
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// The sheet's whole run, with the terminal's part played by the test:
    /// connect succeeds, the environment is read, the attached step is
    /// handed over and reports, then each check runs as a query with the
    /// resolved PATH. Rows read as the design gives them.
    func testASuccessfulRunChecksEverythingWithTheResolvedPATH() async throws {
        let tree = TempTree("ct-ok")
        let paths = PathLog()
        let test = makeTest(tree) { path in
            paths.append(path)
            return RecordingExec { script, args in
                if script == RemoteEnvironment.script {
                    return RemoteOutput(status: 0, stdout: "shell /bin/bash\nchatter\n\(args[0])\n/home/mentes/.local/bin:/usr/bin\n\(args[0])\n", stderr: "")
                }
                if script == ToolCheck.script {
                    return args[0] == "claude"
                        ? RemoteOutput(status: 0, stdout: "found\t0\t/home/mentes/.local/bin/claude\n2.1.283 (Claude Code)\n", stderr: "")
                        : RemoteOutput(status: 0, stdout: "missing\n", stderr: "")
                }
                if script == TmuxCheck.script {
                    XCTAssertEqual(args.count, 2)
                    return RemoteOutput(status: 0, stdout: "version\ttmux 3.4\nchain\t0\n", stderr: "")
                }
                if script == LogindCheck.script { return RemoteOutput(status: 0, stdout: "busctl\t0\nb true\n", stderr: "") }
                return RemoteOutput(status: 99, stdout: "", stderr: "unexpected script")
            }
        }
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        test.start()
        XCTAssertEqual(test.phase, .connecting)
        XCTAssertEqual(test.surfaceArgv.prefix(4), ["/usr/bin/env", "/bin/sh", "-c", ConnectionTest.wrapperScript])
        XCTAssertTrue(test.surfaceArgv.contains("ControlMaster=auto"))
        XCTAssertEqual(test.surfaceArgv.suffix(3), ["--", "box", "true"])
        let work = test.workDirectory
        try "0\n".write(to: work.appendingPathComponent("connect.status"), atomically: true, encoding: .utf8)
        await waitUntil { FileManager.default.fileExists(atPath: work.appendingPathComponent("go").path) }
        let go = try Data(contentsOf: work.appendingPathComponent("go"))
        let argv = go.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(argv.prefix(2), ["/usr/bin/env", "TERM=xterm-256color"])
        XCTAssertTrue(argv.contains("-t"))
        XCTAssertTrue(argv.last!.hasPrefix("'env' 'PATH=/home/mentes/.local/bin:/usr/bin' 'sh' '-c' "), argv.last!)
        try "0\n".write(to: work.appendingPathComponent("attach.status"), atomically: true, encoding: .utf8)
        await waitUntil { test.phase == .finished }
        XCTAssertEqual(test.phase, .finished)
        XCTAssertEqual(paths.values, [nil, "/home/mentes/.local/bin:/usr/bin"], "the environment query has no PATH; every check has the resolved one")
        XCTAssertEqual(test.rows.map(\.line), [
            "Login shell: /bin/bash, PATH read.",
            "tmux: 3.4, launch chain accepted",
            "claude: 2.1.283 at /home/mentes/.local/bin/claude",
            "codex: not on PATH",
            "This host ends your processes when your last login ends (KillUserProcesses=yes). Sessions won't survive a disconnect unless lingering is enabled (loginctl enable-linger).",
        ])
        XCTAssertEqual(finished?.statusLine, "Connected as mentes@10.0.0.2. Claude Code 2.1.283, tmux 3.4. No codex on PATH.")
        XCTAssertEqual(finished?.unavailableReason(for: .codex), "No codex on PATH.")
        test.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "the work files go with the sheet")
    }

    func testAFailedConnectRunsNoChecksAndKeepsSSHsLine() async throws {
        let tree = TempTree("ct-fail")
        let exec = RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") }
        let test = makeTest(tree) { _ in exec }
        test.start()
        let work = test.workDirectory
        try "Offending ECDSA key in /Users/me/.ssh/known_hosts:3\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.\n"
            .write(to: work.appendingPathComponent("connect.err"), atomically: true, encoding: .utf8)
        try "255\n".write(to: work.appendingPathComponent("connect.status"), atomically: true, encoding: .utf8)
        await waitUntil { test.phase == .failed }
        XCTAssertEqual(test.failure, .changedHostKey(offending: "Offending ECDSA key in /Users/me/.ssh/known_hosts:3"))
        XCTAssertEqual(test.summary?.statusLine, test.failure?.message)
        XCTAssertTrue(exec.calls.isEmpty, "no checks after a failed connect")
        test.cancel()
    }

    func testClosingTheTerminalEndsAConnectingTest() async {
        let tree = TempTree("ct-closed")
        let test = makeTest(tree) { _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } }
        test.start()
        test.terminalEnded()
        XCTAssertEqual(test.phase, .failed)
        XCTAssertEqual(test.failure?.message, "Couldn't connect: the terminal closed before ssh finished.")
        test.cancel()
    }

    /// The wrapper itself, under /bin/sh: the connect's status and stderr
    /// are recorded (stderr still reaching the terminal), and the attached
    /// step runs from the handed-over argv and reports its status. Run in a
    /// pseudo-terminal, as libghostty runs it.
    func testTheWrapperRecordsStatusAndRunsTheHandedOverStep() async throws {
        let tree = TempTree("ct-wrapper")
        let work = tree.directory("work")
        tree.write("work/attach.sh", ConnectionTest.attachScript)
        let script = ConnectionTest.wrapperScript
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", script, "temple-test", work.path,
                             "/bin/sh", "-c", "echo 'Warning: Permanently added box' >&2; echo hello; exit 0"]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = Pipe()
        try process.run()
        defer { process.terminate() }
        await waitUntil { FileManager.default.fileExists(atPath: work.appendingPathComponent("connect.status").path) }
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("connect.status"), encoding: .utf8), "0\n")
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("connect.err"), encoding: .utf8),
                       "Warning: Permanently added box\n")
        var go = Data()
        for word in ["/bin/sh", "-c", "exit 7"] { go.append(Data(word.utf8)); go.append(0) }
        try go.write(to: work.appendingPathComponent("go"))
        await waitUntil { FileManager.default.fileExists(atPath: work.appendingPathComponent("attach.status").path) }
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("attach.status"), encoding: .utf8), "7\n")
        XCTAssertTrue(process.isRunning, "the terminal keeps what it showed until the sheet closes")
    }

    func testAFailingConnectSkipsTheAttachedStep() async throws {
        let tree = TempTree("ct-wrapper-fail")
        let work = tree.directory("work")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ConnectionTest.wrapperScript, "temple-test", work.path,
                             "/bin/sh", "-c", "echo 'Permission denied (publickey).' >&2; exit 255"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        defer { process.terminate() }
        await waitUntil { FileManager.default.fileExists(atPath: work.appendingPathComponent("connect.status").path) }
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("connect.status"), encoding: .utf8), "255\n")
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("connect.err"), encoding: .utf8),
                       "Permission denied (publickey).\n")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("attach.status").path))
    }

    /// The attached check hangs (a stand-in ssh that never returns): at the
    /// timeout Temple ends that client, and only it, and calls the check
    /// unconfirmed; the test still finishes.
    func testAHungAttachedClientIsEndedAtTheTimeout() async throws {
        let tree = TempTree("ct-hung")
        let pids = tree.path + "/pids"
        // Connect (`… true`) succeeds; the attached step hangs.
        let ssh = tree.write("ssh", """
        #!/bin/sh
        for last; do :; done
        [ "$last" = true ] && exit 0
        echo $$ >> \(pids)
        exec sleep 60
        """, executable: true)
        let connection = SSHConnection(record: .config("box"), stateDirectory: tree.directory("state"), sshPath: ssh.path)
        let test = ConnectionTest(record: .config("box"), connection: connection, workDirectory: tree.url.appendingPathComponent("work"),
            makeExec: { _ in RecordingExec { script, args in
                if script == RemoteEnvironment.script {
                    return RemoteOutput(status: 0, stdout: "shell /bin/sh\n\(args[0])\n/usr/bin:/bin\n\(args[0])\n", stderr: "")
                }
                if script == TmuxCheck.script { return RemoteOutput(status: 0, stdout: "version\ttmux 3.4\nchain\t0\n", stderr: "") }
                return RemoteOutput(status: 0, stdout: "missing\n", stderr: "")
            } },
            resolve: { [:] }, pollInterval: .milliseconds(20), attachTimeout: 1)
        XCTAssertTrue(test.start())
        // The terminal, as libghostty would run it: a pseudo-terminal.
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        terminal.arguments = ["-q", "/dev/null"] + test.surfaceArgv
        terminal.standardInput = Pipe()
        terminal.standardOutput = Pipe()
        try terminal.run()
        defer { terminal.terminate() }
        await waitUntil({ test.phase == .finished }, timeout: 15)
        XCTAssertEqual(test.phase, .finished)
        XCTAssertEqual(test.summary?.tmux, .attachedUnconfirmed(version: "3.4", reason: "it didn't finish in time"))
        let hung = try String(contentsOfFile: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        XCTAssertEqual(hung.count, 1)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNotEqual(kill(hung[0], 0), 0, "the attached client was ended")
        XCTAssertTrue(terminal.isRunning, "the terminal itself stays until the sheet closes")
        test.cancel()
    }

    /// Storage Temple can't write: the test fails before any terminal
    /// starts, saying why.
    func testUnwritableStorageFailsBeforeTheTerminal() throws {
        let tree = TempTree("ct-unwritable")
        let locked = tree.directory("locked")
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        let test = makeTest(tree) { _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } }
        let blocked = ConnectionTest(record: test.record, connection: test.connection,
                                     workDirectory: locked.appendingPathComponent("work"),
                                     makeExec: { _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } },
                                     resolve: { [:] })
        var finished: HostTestSummary?
        blocked.onFinished = { finished = $0 }
        XCTAssertFalse(blocked.start())
        XCTAssertEqual(blocked.phase, .failed)
        guard case .localSetup? = blocked.failure else { return XCTFail("\(String(describing: blocked.failure))") }
        XCTAssertTrue(blocked.failure?.message.hasPrefix("Temple couldn't prepare the test: ") ?? false)
        XCTAssertNotNil(finished)
        XCTAssertFalse(blocked.start(), "a failed test never starts again")
    }

    /// The wrapper, given a folder it can't write, says so on the terminal
    /// and exits rather than waiting forever.
    func testTheWrapperExitsVisiblyWhenItCannotRecord() async throws {
        let tree = TempTree("ct-wrapper-locked")
        let locked = tree.directory("locked")
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o700) }
        let output = try await ProcessRunner.run("/bin/sh", ["-c", ConnectionTest.wrapperScript, "temple-test", locked.path, "/usr/bin/true"],
                                                 deadline: 10)
        XCTAssertEqual(output.status, 70)
        XCTAssertEqual(output.stderr, "Temple could not record the test in \(locked.path): the folder is not writable\n")
    }

    func testSSHGResolutionParsing() {
        XCTAssertEqual(ConnectionTest.parseResolution("user mentes\nhostname 10.0.0.2\nidentityfile ~/.ssh/a\nidentityfile ~/.ssh/b\n"),
                       ["user": "mentes", "hostname": "10.0.0.2", "identityfile": "~/.ssh/a"])
    }
}

final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String?] = []
    func append(_ value: String?) { lock.withLock { _values.append(value) } }
    var values: [String?] { lock.withLock { _values } }
}

final class RemoteSessionSourceTests: XCTestCase {
    /// The phase-0 source answers the v1 way and runs nothing: it has no
    /// exec at all.
    func testTheInertSourceProvesNothingAndListsNothing() async throws {
        let source = RemoteSessionSource(host: HostID(rawValue: "box"))
        XCTAssertEqual(source.capabilities, [])
        let located = try await source.locate([LocateRequest(id: "x", agent: .claude, refresh: true)])
        XCTAssertTrue(located.candidates.isEmpty)
        XCTAssertTrue(located.complete.isEmpty, "a listing that proves nothing")
        let evidence = await source.directoryEvidence("/home/mentes/p")
        XCTAssertEqual(evidence, .unknown)
        let proof = await source.proveAbsent(ids: ["x"], agent: .claude)
        XCTAssertEqual(proof, .unproven)
        let adopted = try await source.adopt(AdoptionRequest(directory: "/p", startedAt: Date()))
        XCTAssertEqual(adopted, .incomplete)
        do {
            _ = try await source.read(TranscriptLocator(host: source.host, path: "x"), agent: .claude, expecting: "x", facts: true)
            XCTFail("reads are a transport failure")
        } catch let error as TranscriptReadError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
        var batches: [CatalogBatch] = []
        for try await batch in source.catalog(CatalogQuery()) { batches.append(batch) }
        XCTAssertEqual(batches, [.storeFailed(agent: nil, message: "Temple doesn't list sessions on box.")])
    }
}
