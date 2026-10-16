import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

@MainActor
final class ConnectionTestTests: XCTestCase {
    private func makeTest(_ tree: TempTree, sshPath: String = "/usr/bin/ssh",
                          exec: @escaping (String?) -> RemoteExec) -> ConnectionTest {
        let connection = SSHConnection(record: .config("box"), stateDirectory: tree.directory("state"), sshPath: sshPath)
        return ConnectionTest(record: .config("box"), connection: connection, makeExec: exec,
                              resolve: { ["user": "mentes", "hostname": "10.0.0.2"] })
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A stand-in host answering every check the way the design's copy
    /// expects.
    private static func host(_ paths: PathLog) -> (String?) -> RemoteExec {
        { path in
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
                    XCTAssertEqual(args.count, 1)
                    return RemoteOutput(status: 0, stdout: "version\ttmux 3.4\nchain\t0\n", stderr: "")
                }
                if script == LogindCheck.script { return RemoteOutput(status: 0, stdout: "busctl\t0\nb true\n", stderr: "") }
                return RemoteOutput(status: 99, stdout: "", stderr: "unexpected script")
            }
        }
    }

    /// A stand-in ssh. Its connect step (`… -- box true`) does what `mode`
    /// says: `master` leaves a "master" behind (a file `-O check` answers
    /// to) and exits 0; `none-<status>` creates nothing and exits with that
    /// status; `none-killed` creates nothing and dies by SIGKILL. Its
    /// `-O check` exits 0 only when the master file is there, 255 otherwise,
    /// like ssh on a socket nothing listens on.
    private func standInSSH(_ tree: TempTree) -> URL {
        let master = tree.path + "/master"
        let mode = tree.path + "/mode"
        let log = tree.path + "/calls"
        return tree.write("ssh", """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(log)
        for a; do [ "$a" = "-O" ] && { [ -f \(master) ] && exit 0; echo "Control socket connect: No such file or directory" >&2; exit 255; }; done
        m=$(cat \(mode))
        case $m in
          master) : > \(master); exit 0 ;;
          none-killed) kill -9 $$ ;;
          none-*) exit "${m#none-}" ;;
        esac
        """, executable: true)
    }

    /// The terminal's part: run what the sheet's terminal would run.
    private func runTerminal(_ test: ConnectionTest) async throws {
        _ = try await ProcessRunner.run(test.surfaceArgv[0], Array(test.surfaceArgv.dropFirst()), deadline: 10)
    }

    /// The terminal runs the user's ssh and nothing else, creating the
    /// master; once it ends, a master on Temple's socket starts every
    /// check, each a query with the resolved PATH; rows read as the design
    /// gives them.
    func testAMasterStartsTheChecksOverQueries() async throws {
        let tree = TempTree("ct-ok")
        let ssh = standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let paths = PathLog()
        let test = makeTest(tree, sshPath: ssh.path, exec: Self.host(paths))
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        XCTAssertEqual(test.surfaceArgv, ["/usr/bin/env", ssh.path] + test.connection.arguments(for: .interactive)
                       + ["--", "box", "true"])
        for option in ["ControlMaster=auto", "ControlPersist=600", "-t"] {
            XCTAssertTrue(test.surfaceArgv.contains(option), option)
        }
        XCTAssertFalse(test.surfaceArgv.contains("BatchMode=yes"), "the user answers ssh here")
        XCTAssertEqual(test.connection.masterCheckArgv.suffix(5), ["BatchMode=yes", "-O", "check", "--", "box"])
        XCTAssertFalse(test.connection.masterCheckArgv.contains("exit"))

        test.terminalExited()
        XCTAssertEqual(test.phase, .connecting, "nothing before start")
        XCTAssertTrue(test.start())
        try await runTerminal(test)
        XCTAssertTrue(paths.values.isEmpty, "no query before the terminal ends")
        test.terminalExited()
        await waitUntil { test.phase == .finished }
        XCTAssertEqual(paths.values, [nil, "/home/mentes/.local/bin:/usr/bin"],
                       "the environment query has no PATH; every check has the resolved one")
        XCTAssertEqual(test.rows.map(\.line), [
            "Login shell: /bin/bash, PATH read.",
            "claude: 2.1.283 at /home/mentes/.local/bin/claude",
            "codex: not on PATH",
            "tmux: 3.4, detached tmux check passed",
            "This host ends your processes when your last login ends (KillUserProcesses=yes). Sessions won't survive a disconnect unless lingering is enabled (loginctl enable-linger).",
        ])
        XCTAssertEqual(finished?.statusLine, "Connected as mentes@10.0.0.2. Claude Code 2.1.283, tmux 3.4. No codex on PATH.")
        XCTAssertEqual(finished?.unavailableReason(for: .codex), "No codex on PATH.")
        test.terminalExited()
        XCTAssertEqual(test.phase, .finished, "a later end changes nothing")
        let calls = try String(contentsOfFile: tree.path + "/calls", encoding: .utf8)
        XCTAssertFalse(calls.contains("-O exit"), "the master is never ended")
    }

    /// A connect that leaves no master, however it ends (exit 0, 1, 255,
    /// killed), never starts a check and never connects again.
    func testNoMasterMeansNoChecksWhateverTheExit() async throws {
        for mode in ["none-0", "none-1", "none-255", "none-killed"] {
            let tree = TempTree("ct-none")
            let ssh = standInSSH(tree)
            try mode.write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
            let paths = PathLog()
            let test = makeTest(tree, sshPath: ssh.path, exec: Self.host(paths))
            XCTAssertTrue(test.start())
            try await runTerminal(test)
            test.terminalExited()
            await waitUntil { test.phase == .failed }
            XCTAssertEqual(test.phase, .failed, mode)
            XCTAssertEqual(test.failure, .connectFailed, mode)
            XCTAssertEqual(test.failure?.message, "Couldn't connect. See ssh's message above.")
            XCTAssertEqual(test.summary?.statusLine, "Couldn't connect. Test the connection to see ssh's message.")
            XCTAssertTrue(paths.values.isEmpty, "\(mode): no query")
            let calls = try String(contentsOfFile: tree.path + "/calls", encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(calls.count, 2, "\(mode): the connect and one -O check, no second connection")
            XCTAssertTrue(calls[1].contains("-O check"), mode)
        }
    }

    /// The terminal never started (or ended before ssh did anything): the
    /// same question, the same answer.
    func testAnEndWithoutAnyConnectIsNotAConnection() async throws {
        let tree = TempTree("ct-nothing")
        let ssh = standInSSH(tree)
        try "none-0".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let test = makeTest(tree, sshPath: ssh.path, exec: Self.host(PathLog()))
        XCTAssertTrue(test.start())
        test.terminalExited()
        test.terminalExited()
        await waitUntil { test.phase == .failed }
        XCTAssertEqual(test.failure, .connectFailed)
        XCTAssertEqual(try String(contentsOfFile: tree.path + "/calls", encoding: .utf8).split(separator: "\n").count, 1,
                       "asked once")
    }

    /// Closing the sheet mid-check cancels the outstanding query (its own
    /// ssh client) and publishes nothing.
    func testCancellingCancelsOutstandingQueries() async throws {
        let tree = TempTree("ct-cancel")
        let ssh = standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let cancelled = PathLog()
        let test = makeTest(tree, sshPath: ssh.path) { _ in
            RecordingExec { _, _ in
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.append("cancelled"); throw error }
                return RemoteOutput(status: 0, stdout: "", stderr: "")
            }
        }
        var published = false
        test.onFinished = { _ in published = true }
        XCTAssertTrue(test.start())
        try await runTerminal(test)
        test.terminalExited()
        await waitUntil { test.phase == .checking }
        try await Task.sleep(for: .milliseconds(100))
        test.cancel()
        await waitUntil { !cancelled.values.isEmpty }
        XCTAssertEqual(cancelled.values.count, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(published)
    }

    /// A socket directory that can't be used fails the test before any
    /// terminal starts, saying why.
    func testAnUnusableSocketDirectoryFailsBeforeTheTerminal() throws {
        let tree = TempTree("ct-socket")
        let state = tree.directory("state")
        tree.write("state/ssh", "a file, not a directory")
        let test = ConnectionTest(record: .config("box"),
                                  connection: SSHConnection(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh"),
                                  makeExec: { _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } },
                                  resolve: { [:] })
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        XCTAssertFalse(test.start())
        XCTAssertEqual(test.phase, .failed)
        guard case .localSetup? = test.failure else { return XCTFail("\(String(describing: test.failure))") }
        XCTAssertEqual(test.failure?.message, "Temple couldn't prepare the test: Temple won't use \(state.path)/ssh for ssh's connection: it is not a directory.")
        XCTAssertNotNil(finished)
        XCTAssertFalse(test.start(), "a failed test never starts again")
        test.terminalExited()
        XCTAssertEqual(test.phase, .failed)
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
