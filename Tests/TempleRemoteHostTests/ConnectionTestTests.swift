import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

@MainActor
final class ConnectionTestTests: XCTestCase {
    private func makeTest(_ tree: TempTree, sshPath: String = "/usr/bin/ssh",
                          resolved: [String: String] = ["user": "mentes", "hostname": "10.0.0.2"],
                          exec: @escaping (String?) -> RemoteExec) -> ConnectionTest {
        ConnectionTest(record: .config("box"), stateDirectory: tree.directory("state"), sshPath: sshPath,
                       makeExec: { _, path in exec(path) }, resolve: { _ in .resolved(resolved) })
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
                    return RemoteOutput(status: 0, stdout: "shell /bin/bash\nchatter\n\(args[0])\n/home/mentes/.local/bin:/usr/bin\n\(args[0]).cfg\n\(args[0])\n", stderr: "")
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
        test.terminalExited()
        XCTAssertEqual(test.phase, .connecting, "nothing before start")
        XCTAssertEqual(test.surfaceArgv, [], "no terminal before the connection exists")
        let started = await test.start()
        XCTAssertTrue(started)
        let connection = try XCTUnwrap(test.connection)
        XCTAssertEqual(test.surfaceArgv, ["/usr/bin/env", ssh.path] + connection.arguments(for: .interactive)
                       + ["--", "box", "true"])
        for option in ["ControlMaster=auto", "ControlPersist=600", "-t"] {
            XCTAssertTrue(test.surfaceArgv.contains(option), option)
        }
        XCTAssertFalse(test.surfaceArgv.contains("BatchMode=yes"), "the user answers ssh here")
        XCTAssertEqual(connection.masterCheckArgv.suffix(4), ["-O", "check", "--", "box"])
        for option in ["ControlMaster=no", "ControlPersist=no", "BatchMode=yes", "ProxyCommand=/usr/bin/false"] {
            XCTAssertTrue(connection.masterCheckArgv.contains(option), option)
        }
        XCTAssertFalse(connection.masterCheckArgv.contains("exit"))
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
            let started = await test.start()
            XCTAssertTrue(started)
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
        let started = await test.start()
        XCTAssertTrue(started)
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
        let started = await test.start()
        XCTAssertTrue(started)
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
    /// terminal starts, saying why; so does a configuration ssh can't read.
    func testAnUnusableSocketDirectoryFailsBeforeTheTerminal() async throws {
        let tree = TempTree("ct-socket")
        let state = tree.directory("state")
        tree.write("state/ssh", "a file, not a directory")
        let test = ConnectionTest(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh",
                                  makeExec: { _, _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } },
                                  resolve: { _ in .resolved([:]) })
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        let started = await test.start()
        XCTAssertFalse(started)
        XCTAssertEqual(test.phase, .failed)
        guard case .localSetup? = test.failure else { return XCTFail("\(String(describing: test.failure))") }
        XCTAssertEqual(test.failure?.message, "Temple couldn't prepare the test: Temple won't use \(state.path)/ssh for ssh's connection: it is not a directory.")
        XCTAssertNotNil(finished)
        XCTAssertEqual(test.surfaceArgv, [])
        let again = await test.start()
        XCTAssertFalse(again, "a failed test never starts again")
        test.terminalExited()
        XCTAssertEqual(test.phase, .failed)

        let unreadable = ConnectionTest(record: .config("box"), stateDirectory: tree.directory("state2"), sshPath: "/usr/bin/ssh",
                                        makeExec: { _, _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } },
                                        resolve: { _ in .failed("/Users/me/.ssh/config line 3: Bad configuration option: bogus") })
        let resolvedNothing = await unreadable.start()
        XCTAssertFalse(resolvedNothing)
        XCTAssertEqual(unreadable.failure?.message,
                       "Temple couldn't prepare the test: ssh couldn't read its configuration for box: /Users/me/.ssh/config line 3: Bad configuration option: bogus.")
    }

    /// A live master proves only a local process: when the first query
    /// over it never reaches the host, the test says so and never reports
    /// the host connected, and runs nothing more.
    func testAMasterWhoseQueriesFailIsUnconfirmed() async throws {
        let tree = TempTree("ct-unconfirmed")
        let ssh = standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let line = "mux_client_request_session: session request failed: Session open refused by peer"
        let failing = RecordingExec { _, _ in RemoteOutput(status: 255, stdout: "", stderr: line + "\n", reachedCommand: false) }
        let test = makeTest(tree, sshPath: ssh.path) { _ in failing }
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        let started = await test.start()
        XCTAssertTrue(started)
        try await runTerminal(test)
        test.terminalExited()
        await waitUntil { test.phase == .failed }
        XCTAssertEqual(test.failure, .unconfirmed(line))
        XCTAssertEqual(test.failure?.message, "Couldn't confirm the connection: \(line).")
        XCTAssertEqual(finished?.statusLine, "Couldn't confirm the connection: \(line).")
        XCTAssertFalse(finished?.statusLine.contains("Connected") ?? true)
        XCTAssertEqual(failing.calls.count, 1, "only the first query; nothing after it")
        XCTAssertTrue(test.rows.isEmpty)
    }

    /// While the first query over the master is out, nothing says
    /// connected; once it has run on the host, it is confirmed.
    func testTheConnectionIsUnconfirmedUntilAQueryReachesTheHost() async throws {
        let tree = TempTree("ct-pending")
        let ssh = standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let gate = PathLog()
        let answer = Self.host(PathLog())
        let test = makeTest(tree, sshPath: ssh.path) { path in
            let inner = answer(path)
            return RecordingExec { script, args in
                if script == RemoteEnvironment.script {
                    while gate.values.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                }
                return try await inner.run(script: script, args: args, deadline: 5)
            }
        }
        let started = await test.start()
        XCTAssertTrue(started)
        try await runTerminal(test)
        test.terminalExited()
        await waitUntil { test.phase == .checking }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(test.phase, .checking)
        XCTAssertFalse(test.connectionConfirmed, "a live master alone confirms nothing")
        XCTAssertNil(test.summary)
        gate.append("go")
        await waitUntil { test.connectionConfirmed }
        XCTAssertTrue(test.connectionConfirmed)
        await waitUntil { test.phase == .finished }
        XCTAssertEqual(test.summary?.statusLine.hasPrefix("Connected as"), true)
    }

    /// Closing the sheet while ssh -G runs cancels it; nothing is prepared.
    func testCancellingDuringResolutionPreparesNothing() async throws {
        let tree = TempTree("ct-resolve-cancel")
        let state = tree.url.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let seen = PathLog()
        func make(resolving seconds: Double) -> ConnectionTest {
            ConnectionTest(record: .config("box"), stateDirectory: state, sshPath: "/usr/bin/ssh",
                           makeExec: { _, _ in RecordingExec { _, _ in RemoteOutput(status: 0, stdout: "", stderr: "") } },
                           resolve: { _ in
                               do { try await Task.sleep(for: .seconds(seconds)) } catch { seen.append("cancelled") }
                               return .resolved(["hostname": "h"])
                           })
        }
        // The task running start() is cancelled (the sheet's own task).
        let byTask = make(resolving: 30)
        let running = Task { await byTask.start() }
        try await Task.sleep(for: .milliseconds(100))
        running.cancel()
        let startedByTask = await running.value
        XCTAssertFalse(startedByTask)
        XCTAssertEqual(seen.values, ["cancelled"], "ssh -G was cancelled")
        // The test alone is cancelled while resolution runs; the answer
        // that arrives afterwards prepares nothing.
        let byTest = make(resolving: 0.3)
        let other = Task { await byTest.start() }
        try await Task.sleep(for: .milliseconds(100))
        byTest.cancel()
        let startedByTest = await other.value
        XCTAssertFalse(startedByTest)
        XCTAssertNil(byTask.connection)
        XCTAssertNil(byTest.connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("ssh").path),
                       "no socket storage prepared")
    }

    /// Retargeting an alias in the config gives it a new socket at once:
    /// the old destination's master is never asked, and the identity shown
    /// is the one the socket was keyed by. Resolved by the real `ssh -G`
    /// against a fixture config.
    func testARetargetedAliasNeverReusesTheOldMaster() async throws {
        let tree = TempTree("ct-retarget")
        let config = tree.path + "/config"
        let ssh = standInSSH(tree)
        try "master".write(toFile: tree.path + "/mode", atomically: true, encoding: .utf8)
        let state = tree.directory("state")
        func test(target: String) async throws -> ConnectionTest {
            try "Host box\n  HostName \(target)\n  User mentes\n".write(toFile: config, atomically: true, encoding: .utf8)
            let test = ConnectionTest(record: .config("box"), stateDirectory: state, sshPath: ssh.path,
                                      makeExec: { _, path in Self.host(PathLog())(path) },
                                      resolve: { argv in await ConnectionTest.sshResolve(["/usr/bin/ssh", "-F", config] + argv.dropFirst()) })
            let started = await test.start()
            XCTAssertTrue(started)
            return test
        }
        let first = try await test(target: "10.0.0.1")
        let firstPath = try XCTUnwrap(first.connection?.controlPath)
        try await runTerminal(first)
        first.terminalExited()
        await waitUntil { first.phase == .finished }
        XCTAssertEqual(first.summary?.statusLine.hasPrefix("Connected as mentes@10.0.0.1."), true)

        // The same alias, pointed elsewhere, while the first master lives on.
        let second = try await test(target: "10.0.0.2")
        let secondPath = try XCTUnwrap(second.connection?.controlPath)
        XCTAssertNotEqual(secondPath, firstPath, "a new destination, a new socket")
        try await runTerminal(second)
        second.terminalExited()
        await waitUntil { second.phase == .finished }
        XCTAssertEqual(second.summary?.statusLine.hasPrefix("Connected as mentes@10.0.0.2."), true)
        let checks = try String(contentsOfFile: tree.path + "/calls", encoding: .utf8).split(separator: "\n")
            .filter { $0.contains("-O check") }
        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(checks[1].contains(secondPath), "the second test asked its own socket, not the old master's")
        XCTAssertFalse(checks[1].contains(firstPath))
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
