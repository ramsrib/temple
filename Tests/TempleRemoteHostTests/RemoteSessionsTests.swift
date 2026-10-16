import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// The launch model as a test matrix (section 11): the controller's
/// decisions and durable writes, with the tab's remote command run on a pty
/// against a real tmux under the test's own TMUX_TMPDIR, and every query
/// over the local `/bin/sh` stand-in.
@MainActor
final class RemoteSessionsTests: XCTestCase {
    typealias StandIn = RemoteScriptsTests.StandIn
    typealias PTYClient = RemoteScriptsTests.PTYClient

    private let record = RemoteHostRecord.config("box")

    private func controller(_ host: StandIn, store: RemoteStateStore, failing: Bool = false,
                            master: Bool = true) -> RemoteSessions {
        let environment = host.environment
        return RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                              store: { store },
                              resolve: { _ in .resolved(["hostname": "box.example", "user": "u", "port": "22"]) },
                              makeExec: { _, path in
                                  failing ? FailingExec() as RemoteExec : LocalShellExec(path: path, environment: environment)
                              },
                              masterCheck: { _ in master })
    }

    struct FailingExec: RemoteExec {
        func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
            RemoteOutput(status: 255, stdout: "", stderr: "ssh: connect to host box port 22: Operation timed out\n",
                         reachedCommand: false)
        }
    }

    /// The tab: the remote command (the argv's last word) run by a login
    /// shell on a pty.
    private func tab(_ host: StandIn, _ plan: RemoteSessions.OpenPlan) throws -> PTYClient {
        try PTYClient(try XCTUnwrap(plan.argv.last), environment: host.environment)
    }

    private func request(_ mode: RemoteSessions.OpenRequest.Mode = .new, directory: String,
                         resumeAnyway: Bool = false) -> RemoteSessions.OpenRequest {
        RemoteSessions.OpenRequest(agent: .claude, sessionID: "sess-1", mode: mode, directory: directory,
                                   extraArguments: ["--model", "x"], resumeAnyway: resumeAnyway)
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    /// A stand-in `claude` on the host's PATH that just waits.
    private func installAgent(_ host: StandIn) {
        host.tree.write("bin/claude", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/claude-argv\"\nexec sleep 60\n", executable: true)
    }

    func testCreateCollectAttachStopResume() async throws {
        let host = StandIn()
        try host.installRealTmux()
        installAgent(host)
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)

        // First Open: a creation, its row written before anything runs.
        let first = try await sessions.open(request(directory: "~"))
        XCTAssertTrue(first.creating)
        XCTAssertEqual(Array(first.argv.prefix(3)), ["/usr/bin/env", "TERM=xterm-256color", "/usr/bin/ssh"])
        XCTAssertTrue(first.argv.contains("-t"))
        XCTAssertEqual(first.argv[first.argv.count - 2], "box")
        XCTAssertEqual(first.agentArgv, ["claude", "--model", "x", "--session-id", "sess-1"])
        let row = try XCTUnwrap(store.run(first.handle))
        XCTAssertNil(row.creation)
        XCTAssertEqual(row.directoryIntent, "~")

        var client = try tab(host, first)
        let collected = await until { if case .ok = await sessions.collect(first.handle) { return true }; return false }
        XCTAssertTrue(collected)
        let proven = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(proven.creation, .proven)
        XCTAssertEqual(proven.socketPath, host.tmuxDir + "/tmux-\(getuid())/temple")
        XCTAssertEqual(proven.directory.map { URL(fileURLWithPath: $0).lastPathComponent }, "home")
        // Acknowledged: gone from the host once written here.
        XCTAssertNil(host.record(proven.recordPath))
        XCTAssertEqual(try String(contentsOfFile: host.home + "/claude-argv", encoding: .utf8),
                       "--model\nx\n--session-id\nsess-1\n")

        // Disconnect (the tab's ssh goes): present, so Detached.
        client.end()
        let present = await sessions.exitCheck(first.handle)
        XCTAssertEqual(present, .present)

        // Every later Open attaches, on the pinned socket, and creates nothing.
        let second = try await sessions.open(request(directory: "~"))
        XCTAssertFalse(second.creating)
        XCTAssertEqual(second.handle, first.handle)
        XCTAssertEqual(second.attachment, 2)
        XCTAssertTrue(second.argv.last?.contains("'attach'") == true)
        XCTAssertTrue(second.argv.last?.contains(proven.socketPath ?? "?") == true)
        XCTAssertEqual(try store.runs(host: record.host).count, 1)
        client = try tab(host, second)
        let attached = await until {
            (try? host.tmux(["-L", "temple", "display-message", "-p", "-t", "=temple-\(first.handle):", "#{session_attached}"]).stdout)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        XCTAssertTrue(attached)

        // Close while idle: Temple's client goes first, then the one-command stop.
        client.end()
        let stopped = await sessions.stop(first.handle, fromAttachedTab: true)
        XCTAssertEqual(stopped, .killed)
        let ended = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(ended.endEvidence, .killed)
        XCTAssertNotNil(ended.endedAt)
        // The last session: the server has exited, which a check would read
        // as unknown; the acknowledged kill is the evidence, and stands.
        guard case .unknown(_, true) = await sessions.exitCheck(first.handle) else { return XCTFail() }
        XCTAssertEqual(try store.run(first.handle)?.endEvidence, .killed)

        // Reopen: a new run with resume, the old one kept.
        let third = try await sessions.open(request(.resume, directory: "~"))
        XCTAssertTrue(third.creating)
        XCTAssertNotEqual(third.handle, first.handle)
        XCTAssertEqual(third.agentArgv, ["claude", "--model", "x", "--resume", "sess-1"])
        XCTAssertEqual(try store.runs(host: record.host, sessionID: "sess-1").map(\.handle), [first.handle, third.handle])
        sessions.abandon(third.handle, reason: "test")
        XCTAssertEqual(try store.run(third.handle)?.creation, .failed)
    }

    func testAnOKNeverCollectedIsRecoveredOnTheNextOpenBeforeTheAttach() async throws {
        let host = StandIn()
        try host.installRealTmux()
        installAgent(host)
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let store = try RemoteStateStore()
        let first = try await controller(host, store: store).open(request(directory: "~"))
        let client = try tab(host, first)
        let marker = try XCTUnwrap(store.run(first.handle)).recordPath
        let written = await until { host.record(marker) != nil }
        XCTAssertTrue(written)
        // Quit before the first fetch: the tab goes, nothing was collected.
        client.end()
        // Relaunch: a new controller, the same store.
        let relaunched = controller(host, store: store)
        let plan = try await relaunched.open(request(.resume, directory: "~"))
        XCTAssertFalse(plan.creating, "attach-only: the original may be running")
        XCTAssertEqual(plan.handle, first.handle)
        let run = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(run.creation, .proven)
        XCTAssertNotNil(run.socketPath)
        XCTAssertTrue(plan.argv.last?.contains(run.socketPath ?? "?") == true, "attaches on the pinned socket")
    }

    func testAFailedClientAfterCreationIsUnprovenAndTheNextOpenAttaches() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_STATUS": "1", "STUB_ERR": "open terminal failed: not a terminal"]
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        let first = try await sessions.open(request(directory: "~"))
        try host.runLaunch(try XCTUnwrap(first.argv.last))
        let collected = await sessions.collect(first.handle)
        XCTAssertEqual(collected, .clientFailed("open terminal failed: not a terminal"))
        XCTAssertEqual(try store.run(first.handle)?.creation, .unproven)
        let next = try await sessions.open(request(directory: "~"))
        XCTAssertFalse(next.creating)
        XCTAssertEqual(next.handle, first.handle)
    }

    func testAPaneThatCannotEnterItsFolderFailsTheRunAndTheNextOpenCreates() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_RUN_PANE": "1", "STUB_SOCKET": "/tmp/s"]
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        let first = try await sessions.open(request(directory: "~/nowhere"))
        try host.runLaunch(try XCTUnwrap(first.argv.last))
        let collected = await sessions.collect(first.handle)
        XCTAssertEqual(collected, .failedCD(directory: "~/nowhere"))
        let failed = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(failed.creation, .failed)
        XCTAssertNotNil(failed.endedAt)
        let next = try await sessions.open(request(directory: "~"))
        XCTAssertTrue(next.creating)
    }

    func testAnUnreachableHostLeavesItRunningAndNothingIsRetried() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        var run = RemoteRun(handle: "h1", host: record.host, agent: .claude, mode: .new, directoryIntent: "~",
                            sessionID: "sess-1", recordPath: "r-1", startedAt: Date())
        run.creation = .proven
        try store.insert(run)
        let counting = CountingExec()
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store }, resolve: { _ in .resolved([:]) },
                                      makeExec: { _, _ in counting })
        let outcome = await sessions.stop("h1", fromAttachedTab: false)
        guard case .unconfirmed(_, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try store.run("h1")?.leftRunningReason, .hostDidNotAnswer)
        XCTAssertEqual(sessions.unnoticedLeftRunning().map(\.handle), ["h1"])
        // A later contact lists; it never stops anything on its own.
        let before = counting.stops
        _ = await sessions.listSessions()
        _ = await sessions.exitCheck("h1")
        XCTAssertEqual(counting.stops, before, "no automatic kill, ever")
        sessions.noticeLeftRunning()
        XCTAssertEqual(sessions.unnoticedLeftRunning(), [])
        // Keep clears the flag: an ordinary detached session.
        sessions.keep("h1")
        XCTAssertFalse(try XCTUnwrap(store.run("h1")).isLeftRunning)
        XCTAssertNil(try store.run("h1")?.endedAt)
    }

    final class CountingExec: RemoteExec, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var stops: Int { lock.withLock { count } }
        func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
            if script.contains("kill-session") { lock.withLock { count += 1 } }
            return RemoteOutput(status: 255, stdout: "", stderr: "ssh: Could not resolve hostname box\n", reachedCommand: false)
        }
    }

    func testOpenOfALeftRunningSessionAttachesAndClearsTheFlag() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        var run = RemoteRun(handle: "h1", host: record.host, agent: .claude, mode: .new, directoryIntent: "~",
                            sessionID: "sess-1", recordPath: "r-1", startedAt: Date())
        run.creation = .proven
        run.socketPath = "/tmp/tmux-1000/temple"
        run.leftRunningAt = Date()
        run.leftRunningReason = .quitDeadline
        try store.insert(run)
        let plan = try await controller(host, store: store).open(request(.resume, directory: "~"))
        XCTAssertFalse(plan.creating)
        XCTAssertFalse(try XCTUnwrap(store.run("h1")).isLeftRunning)
    }

    func testResumeAnywayStartsANewRunAndKeepsTheOldOne() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        var run = RemoteRun(handle: "h1", host: record.host, agent: .claude, mode: .new, directoryIntent: "~",
                            sessionID: "sess-1", recordPath: "r-1", startedAt: Date())
        run.creation = .unproven
        try store.insert(run)
        let sessions = controller(host, store: store)
        let plan = try await sessions.open(request(.resume, directory: "~", resumeAnyway: true))
        XCTAssertTrue(plan.creating)
        XCTAssertNotEqual(plan.handle, "h1")
        XCTAssertNil(try store.run("h1")?.endedAt, "kept, so Stop can still reach it")
        XCTAssertEqual(sessions.liveRun(sessionID: "sess-1")?.handle, plan.handle)
        XCTAssertEqual(RemoteSessions.manualStopCommand(handle: "h1"), "tmux -L temple kill-session -t temple-h1")
    }

    func testAStoreThatCannotBeReadRefusesTheOpen() async throws {
        let host = StandIn()
        struct Broken: Error {}
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { throw Broken() }, resolve: { _ in .resolved([:]) },
                                      makeExec: { _, _ in FailingExec() })
        do {
            _ = try await sessions.open(request(directory: "~"))
            XCTFail("an unreadable store must refuse, never mint")
        } catch RemoteSessions.OpenError.store {}
    }

    func testNewCodexLaunchesWaitForPhase1bButCodexRowsWithAnIDResume() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        var codex = request(.new, directory: "~")
        codex.agent = .codex
        do { _ = try await sessions.open(codex); XCTFail() } catch RemoteSessions.OpenError.refused {}
        codex.mode = .resume
        let plan = try await sessions.open(codex)
        XCTAssertEqual(plan.agentArgv, ["codex", "--model", "x", "resume", "sess-1"])
    }
}
