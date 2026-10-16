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

    private func controller(_ host: StandIn, store: @escaping () throws -> RemoteStateStore, failing: Bool = false,
                            master: Bool = true,
                            resolved: @escaping () -> [String: String] = { ["hostname": "box.example", "user": "u", "port": "22"] })
        -> RemoteSessions {
        let environment = host.environment
        return RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                              store: store,
                              resolve: { _ in .resolved(resolved()) },
                              makeExec: { _, path in
                                  failing ? FailingExec() as RemoteExec : LocalShellExec(path: path, environment: environment)
                              },
                              masterCheck: { _ in master })
    }

    private func controller(_ host: StandIn, store: RemoteStateStore, failing: Bool = false) -> RemoteSessions {
        controller(host, store: { store }, failing: failing)
    }

    struct FailingExec: RemoteExec {
        func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
            RemoteOutput(status: 255, stdout: "", stderr: "ssh: connect to host box port 22: Operation timed out\n",
                         reachedCommand: false)
        }
    }

    private func tab(_ host: StandIn, _ plan: RemoteSessions.OpenPlan) throws -> PTYClient {
        try PTYClient(try XCTUnwrap(plan.argv.last), environment: host.environment)
    }

    private func request(_ mode: RemoteSessions.OpenRequest.Mode = .new, directory: String = "~",
                         resumeAnyway: Bool = false, startNew: Bool = false) -> RemoteSessions.OpenRequest {
        RemoteSessions.OpenRequest(agent: .claude, sessionID: "sess-1", mode: mode, directory: directory,
                                   extraArguments: ["--model", "x"], resumeAnyway: resumeAnyway, startNew: startNew)
    }

    private func plan(_ outcome: RemoteSessions.OpenOutcome, file: StaticString = #filePath, line: UInt = #line) throws
        -> RemoteSessions.OpenPlan {
        guard case .plan(let plan) = outcome else {
            XCTFail("expected a plan, got \(outcome)", file: file, line: line)
            throw XCTSkip("no plan")
        }
        return plan
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

    private func insertRun(_ store: RemoteStateStore, handle: String = "h1", creation: RemoteRun.Creation? = .proven,
                           mutate: (inout RemoteRun) -> Void = { _ in }) throws {
        var run = RemoteRun(handle: handle, host: record.host, agent: .claude, mode: .new, directoryIntent: "~",
                            sessionID: "sess-1", recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
        run.creation = creation
        mutate(&run)
        try store.insert(run)
    }

    func testCreateCollectAttachStopResume() async throws {
        let host = StandIn()
        try host.installRealTmux()
        installAgent(host)
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)

        // First Open: a creation, its row written before anything runs.
        let first = try plan(await sessions.open(request()))
        XCTAssertTrue(first.creating)
        XCTAssertEqual(Array(first.argv.prefix(3)), ["/usr/bin/env", "TERM=xterm-256color", "/usr/bin/ssh"])
        XCTAssertTrue(first.argv.contains("-t"))
        XCTAssertEqual(first.argv[first.argv.count - 2], "box")
        XCTAssertEqual(first.agentArgv, ["claude", "--model", "x", "--session-id", "sess-1"])
        let row = try XCTUnwrap(store.run(first.handle))
        XCTAssertNil(row.creation)
        XCTAssertEqual(row.conversation, .unconfirmed)
        XCTAssertEqual(row.recordPath, RecordDirectory.locator(marker: RecordDirectory.marker(from: row.recordPath)!))

        var client = try tab(host, first)
        let collected = await until { if case .ok = await sessions.collect(first.handle) { return true }; return false }
        XCTAssertTrue(collected)
        let proven = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(proven.creation, .proven)
        XCTAssertEqual(proven.socketPath, host.tmuxDir + "/tmux-\(getuid())/temple")
        XCTAssertEqual(proven.directory.map { URL(fileURLWithPath: $0).lastPathComponent }, "home")
        XCTAssertNil(host.record(RecordDirectory.marker(from: proven.recordPath)!), "acknowledged once written here")
        XCTAssertEqual(try String(contentsOfFile: host.home + "/claude-argv", encoding: .utf8),
                       "--model\nx\n--session-id\nsess-1\n")
        try await sessions.confirmConversation(first.handle)

        client.end()
        let present = await sessions.exitCheck(first.handle)
        XCTAssertEqual(present, .present)

        // Every later Open attaches, on the pinned socket, and replays the
        // persisted creation evidence.
        let second = try plan(await sessions.open(request()))
        XCTAssertFalse(second.creating)
        XCTAssertEqual(second.handle, first.handle)
        XCTAssertEqual(second.attachment, 2)
        XCTAssertEqual(second.evidenceDirectory, proven.directory)
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
        let stopped = try await sessions.stop(first.handle, fromAttachedTab: true)
        XCTAssertEqual(stopped, RemoteSessions.StopRecord(outcome: .killed))
        XCTAssertEqual(try store.run(first.handle)?.endEvidence, .killed)
        guard case .unknown(_, true) = await sessions.exitCheck(first.handle) else { return XCTFail() }
        XCTAssertEqual(try store.run(first.handle)?.endEvidence, .killed)

        // Reopen: a new run with resume (the conversation was confirmed).
        let third = try plan(await sessions.open(request(.resume)))
        XCTAssertTrue(third.creating)
        XCTAssertNotEqual(third.handle, first.handle)
        XCTAssertEqual(third.agentArgv, ["claude", "--model", "x", "--resume", "sess-1"])
        XCTAssertEqual(try store.runs(host: record.host, sessionID: "sess-1").map(\.handle), [first.handle, third.handle])
        try await sessions.abandon(third.handle, reason: "test")
        XCTAssertEqual(try store.run(third.handle)?.creation, .failed)
    }

    func testAnOKNeverCollectedIsRecoveredOnTheNextOpenBeforeTheAttach() async throws {
        let host = StandIn()
        try host.installRealTmux()
        installAgent(host)
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let store = try RemoteStateStore()
        let first = try plan(await controller(host, store: store).open(request()))
        let client = try tab(host, first)
        let marker = RecordDirectory.marker(from: try XCTUnwrap(store.run(first.handle)).recordPath)!
        let written = await until { host.record(marker) != nil }
        XCTAssertTrue(written)
        client.end()
        // Relaunch: a new controller, the same store; the TMPDIR of this
        // connection differs, and the locator does not depend on it.
        host.extra = ["TMPDIR": host.tree.directory("another-tmp").path]
        let relaunched = controller(host, store: store)
        let attach = try plan(await relaunched.open(request(.resume)))
        XCTAssertFalse(attach.creating, "attach-only: the original may be running")
        XCTAssertEqual(attach.handle, first.handle)
        let run = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(run.creation, .proven)
        XCTAssertEqual(attach.evidenceDirectory, run.directory, "recovered evidence is replayed into the row and tab")
        XCTAssertTrue(attach.argv.last?.contains(run.socketPath ?? "?") == true, "attaches on the pinned socket")
    }

    func testAFailedClientAfterCreationIsUnprovenAndTheNextOpenAttaches() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_STATUS": "1", "STUB_ERR": "open terminal failed: not a terminal"]
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        let first = try plan(await sessions.open(request()))
        try host.runLaunch(try XCTUnwrap(first.argv.last))
        let collected = await sessions.collect(first.handle)
        XCTAssertEqual(collected, .clientFailed("open terminal failed: not a terminal"))
        XCTAssertEqual(try store.run(first.handle)?.creation, .unproven)
        let next = try plan(await sessions.open(request()))
        XCTAssertFalse(next.creating)
        XCTAssertEqual(next.handle, first.handle)
    }

    func testAPaneThatCannotEnterItsFolderFailsTheRunAndTheNextOpenCreates() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_RUN_PANE": "1", "STUB_SOCKET": "/tmp/s"]
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        let first = try plan(await sessions.open(request(directory: "~/nowhere")))
        try host.runLaunch(try XCTUnwrap(first.argv.last))
        let collected = await sessions.collect(first.handle)
        XCTAssertEqual(collected, .failedCD(directory: "~/nowhere"))
        let failed = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(failed.creation, .failed)
        XCTAssertNotNil(failed.endedAt)
        let next = try plan(await sessions.open(request()))
        XCTAssertTrue(next.creating)
    }

    /// A store whose writes fail: the host's answer is never reported as
    /// recorded, and nothing is acknowledged on the host.
    func testACollectWhoseWriteFailsIsAStorageErrorAndKeepsTheRecord() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_RUN_PANE": "1", "STUB_SOCKET": "/tmp/s"]
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        let first = try plan(await sessions.open(request()))
        try host.runLaunch(try XCTUnwrap(first.argv.last))
        let marker = RecordDirectory.marker(from: try XCTUnwrap(store.run(first.handle)).recordPath)!
        XCTAssertNotNil(host.record(marker))
        try store.breakWritesForTests()
        let collected = await sessions.collect(first.handle)
        guard case .storage = collected else { return XCTFail("\(collected)") }
        XCTAssertNotNil(host.record(marker), "not acknowledged: the next Open recovers it")
        try store.mendWritesForTests()
        guard case .ok = await sessions.collect(first.handle) else { return XCTFail() }
    }

    func testAnUnreachableHostLeavesItRunningAndNothingIsRetried() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store)
        let counting = CountingExec()
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store }, resolve: { _ in .resolved([:]) },
                                      makeExec: { _, _ in counting })
        let stop = try await sessions.stop("h1", fromAttachedTab: false)
        guard case .unconfirmed(_, false) = stop.outcome else { return XCTFail("\(stop)") }
        XCTAssertNil(stop.storageError)
        XCTAssertEqual(try store.run("h1")?.leftRunningReason, .hostDidNotAnswer)
        let unnoticed = await sessions.unnoticedLeftRunning()
        XCTAssertEqual(unnoticed.map(\.handle), ["h1"])
        // A later contact only asks; it never stops anything on its own.
        let before = counting.stops
        _ = await sessions.trackedSessions()
        _ = await sessions.contactLeftRunning()
        _ = await sessions.exitCheck("h1")
        XCTAssertEqual(counting.stops, before, "no automatic kill, ever")
        try await sessions.noticeLeftRunning()
        let none = await sessions.unnoticedLeftRunning()
        XCTAssertEqual(none, [])
        try await sessions.keep("h1")
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

    /// An answer that arrived is written even when the waiter has gone; a
    /// query cancelled before any answer writes nothing (its owner records why).
    func testADecodedStopIsWrittenUnderCancellationAndAnUnansweredOneIsNot() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store, handle: "answered")
        try insertRun(store, handle: "silent") { $0.sessionID = "sess-2" }
        let gate = SlowExec()
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store }, resolve: { _ in .resolved([:]) }, makeExec: { _, _ in gate })
        let answered = Task { try await sessions.stop("answered", fromAttachedTab: false) }
        try await Task.sleep(for: .milliseconds(100))
        answered.cancel()   // after the exec answered (SlowExec ignores cancellation)
        _ = try? await answered.value
        XCTAssertEqual(try store.run("answered")?.endEvidence, .killed)

        let silent = Task { try await sessions.stop("silent", fromAttachedTab: false) }
        try await Task.sleep(for: .milliseconds(20))
        gate.cancelNext = true
        silent.cancel()
        do { _ = try await silent.value; XCTFail("cancelled before an answer") } catch is CancellationError {}
        XCTAssertNil(try store.run("silent")?.endedAt)
        XCTAssertNil(try store.run("silent")?.leftRunningAt)
    }

    final class SlowExec: RemoteExec, @unchecked Sendable {
        var cancelNext = false
        func run(script: String, args: [String], deadline: TimeInterval) async throws -> RemoteOutput {
            if script.contains("temple_login_path") {
                return RemoteOutput(status: 3, stdout: "shell /bin/sh\n", stderr: "")
            }
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                if cancelNext { throw CancellationError() }
            }
            return RemoteOutput(status: 0, stdout: "", stderr: "")
        }
    }

    func testOpenOfALeftRunningSessionAttachesAndClearsTheFlag() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store) {
            $0.socketPath = "/tmp/tmux-1000/temple"
            $0.leftRunningAt = Date()
            $0.leftRunningReason = .quitDeadline
        }
        let attach = try plan(await controller(host, store: store).open(request(.resume)))
        XCTAssertFalse(attach.creating)
        XCTAssertFalse(try XCTUnwrap(store.run("h1")).isLeftRunning)
    }

    func testResumeAnywayStartsANewRunAndKeepsTheOldOne() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store, creation: .unproven)
        let sessions = controller(host, store: store)
        let created = try plan(await sessions.open(request(.resume, resumeAnyway: true)))
        XCTAssertTrue(created.creating)
        XCTAssertNotEqual(created.handle, "h1")
        XCTAssertNil(try store.run("h1")?.endedAt, "kept, so Stop can still reach it")
        let live = await sessions.liveRun(sessionID: "sess-1")
        XCTAssertEqual(live?.handle, created.handle)
        XCTAssertEqual(RemoteSessions.manualStopCommand(handle: "h1"), "tmux -L temple kill-session -t temple-h1")
    }

    /// Two Temple processes on one state directory: an ordinary open is one
    /// immediate transaction, so only one of them creates.
    func testFindOrReserveIsAtomicAcrossProcesses() async throws {
        let host = StandIn()
        let directory = host.tree.directory("state")
        let one = try RemoteStateStore(directory: directory)
        let two = try RemoteStateStore(directory: directory)
        let a = controller(host, store: one)
        let b = controller(host, store: two)
        async let first = a.open(request())
        async let second = b.open(request())
        let plans = [try plan(await first), try plan(await second)]
        XCTAssertEqual(plans.filter(\.creating).count, 1)
        XCTAssertEqual(Set(plans.map(\.handle)).count, 1)
        XCTAssertEqual(try one.runs(host: record.host, sessionID: "sess-1").count, 1)
    }

    /// A stopped new session whose conversation was never confirmed is not
    /// resumed blindly; Start a new session reuses the id afresh.
    func testAnUnconfirmedConversationNeedsADecision() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store) { $0.conversation = .unconfirmed; $0.endedAt = Date(); $0.endEvidence = .killed }
        let sessions = controller(host, store: store)
        let outcome = try await sessions.open(request(.resume))
        XCTAssertEqual(outcome, .needsDecision)
        XCTAssertEqual(try store.runs(host: record.host).count, 1, "nothing reserved")
        let fresh = try plan(await sessions.open(request(.resume, startNew: true)))
        XCTAssertTrue(fresh.creating)
        XCTAssertEqual(fresh.agentArgv.suffix(2), ["--session-id", "sess-1"])
        // Discard: no run of the session is attached to or resumed again.
        try await sessions.dismiss(sessionID: "sess-1")
        let live = await sessions.liveRun(sessionID: "sess-1")
        XCTAssertNil(live)
    }

    func testAnAliasRetargetedWhileRunningGetsANewConnectionOnTheNextExplicitOpen() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        var target = "first.example"
        let sessions = controller(host, store: { store }, resolved: { ["hostname": target, "user": "u", "port": "22"] })
        let first = try plan(await sessions.open(request()))
        try await sessions.abandon(first.handle, reason: "test")
        let socket = { (argv: [String]) in argv.first { $0.hasPrefix("ControlPath=") } }
        target = "second.example"
        let second = try plan(await sessions.open(request()))
        XCTAssertNotEqual(socket(first.argv), socket(second.argv), "a new destination never rides the old master")
    }

    func testARetiredHostQueriesNothing() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store)
        let counting = CountingExec()
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store }, resolve: { _ in .resolved([:]) },
                                      makeExec: { _, _ in counting })
        sessions.retire()
        do { _ = try await sessions.open(request()); XCTFail() } catch {}
        let stop = try await sessions.stop("h1", fromAttachedTab: false)
        guard case .unconfirmed(_, false) = stop.outcome else { return XCTFail() }
        XCTAssertEqual(counting.stops, 0)
    }

    func testAStoreThatCannotBeReadRefusesTheOpen() async throws {
        let host = StandIn()
        struct Broken: Error {}
        let sessions = controller(host, store: { throw Broken() })
        do {
            _ = try await sessions.open(request())
            XCTFail("an unreadable store must refuse, never mint")
        } catch RemoteSessions.OpenError.store {}
    }

    func testNewCodexLaunchesWaitForPhase1bButCodexRowsWithAnIDResume() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        var codex = request(.new)
        codex.agent = .codex
        do { _ = try await sessions.open(codex); XCTFail() } catch RemoteSessions.OpenError.refused {}
        codex.mode = .resume
        let resumed = try plan(await sessions.open(codex))
        XCTAssertEqual(resumed.agentArgv, ["codex", "--model", "x", "resume", "sess-1"])
    }
}
