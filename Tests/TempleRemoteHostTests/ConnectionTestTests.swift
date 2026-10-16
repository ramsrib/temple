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

    /// The terminal runs the user's ssh and nothing else, creating the
    /// master; its exit 0 starts every check, each a query with the
    /// resolved PATH; rows read as the design gives them.
    func testASuccessfulConnectChecksEverythingOverQueries() async throws {
        let tree = TempTree("ct-ok")
        let paths = PathLog()
        let test = makeTest(tree, exec: Self.host(paths))
        var finished: HostTestSummary?
        test.onFinished = { finished = $0 }
        XCTAssertEqual(test.surfaceArgv, ["/usr/bin/env", "/usr/bin/ssh"] + test.connection.arguments(for: .interactive)
                       + ["--", "box", "true"])
        for option in ["ControlMaster=auto", "ControlPersist=600", "-t"] {
            XCTAssertTrue(test.surfaceArgv.contains(option), option)
        }
        XCTAssertFalse(test.surfaceArgv.contains("BatchMode=yes"), "the user answers ssh here")
        XCTAssertFalse(test.surfaceArgv.contains("/bin/sh"), "no wrapper: the terminal's process is ssh")

        test.terminalExited(status: 0)
        XCTAssertEqual(test.phase, .connecting, "nothing before start")
        XCTAssertTrue(test.start())
        XCTAssertTrue(paths.values.isEmpty, "no query before the connect ends")
        test.terminalExited(status: 0)
        XCTAssertEqual(test.phase, .checking)
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
        test.terminalExited(status: 1)
        XCTAssertEqual(test.phase, .finished, "a later exit changes nothing")
    }

    /// Any other end runs no check and reconnects nothing.
    func testAFailedConnectRunsNoChecks() async throws {
        let tree = TempTree("ct-fail")
        let paths = PathLog()
        let test = makeTest(tree, exec: Self.host(paths))
        XCTAssertTrue(test.start())
        test.terminalExited(status: 255)
        XCTAssertEqual(test.phase, .failed)
        XCTAssertEqual(test.failure, .connectFailed(status: 255))
        XCTAssertEqual(test.failure?.message, "Couldn't connect. See ssh's message above.")
        XCTAssertEqual(test.summary?.statusLine, "Couldn't connect: ssh exited with status 255. Test the connection to see ssh's message.")
        XCTAssertTrue(test.failure?.allowsRetry ?? false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(paths.values.isEmpty, "no query, no reconnect")
    }

    /// A status the terminal never reported: a real one arriving in the
    /// grace wins; otherwise the end is unknown, and nothing runs.
    func testAnUnknownEndNeverStartsChecks() async throws {
        let tree = TempTree("ct-unknown")
        let paths = PathLog()
        let unknown = makeTest(tree, exec: Self.host(paths))
        XCTAssertTrue(unknown.start())
        unknown.terminalExited(status: nil)
        XCTAssertEqual(unknown.phase, .connecting)
        await waitUntil { unknown.phase == .failed }
        XCTAssertEqual(unknown.failure, .connectFailed(status: nil))
        XCTAssertEqual(unknown.summary?.statusLine, "Couldn't connect. Test the connection to see ssh's message.")

        let late = makeTest(tree, exec: Self.host(paths))
        XCTAssertTrue(late.start())
        late.terminalExited(status: nil)
        late.terminalExited(status: 0)
        XCTAssertEqual(late.phase, .checking, "the real status, in the grace, decides")
        await waitUntil { late.phase == .finished }
        XCTAssertEqual(late.phase, .finished)
        late.cancel()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(paths.values.count, 2, "only the run with a real 0 queried")
    }

    /// Closing the sheet mid-check cancels the outstanding query (its own
    /// ssh client) and publishes nothing.
    func testCancellingCancelsOutstandingQueries() async throws {
        let tree = TempTree("ct-cancel")
        let cancelled = PathLog()
        let test = makeTest(tree) { _ in
            RecordingExec { _, _ in
                do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.append("cancelled"); throw error }
                return RemoteOutput(status: 0, stdout: "", stderr: "")
            }
        }
        var published = false
        test.onFinished = { _ in published = true }
        XCTAssertTrue(test.start())
        test.terminalExited(status: 0)
        try await Task.sleep(for: .milliseconds(100))
        test.cancel()
        await waitUntil { !cancelled.values.isEmpty }
        XCTAssertEqual(cancelled.values.count, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(published)
        XCTAssertEqual(test.phase, .checking)
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
        test.terminalExited(status: 0)
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
