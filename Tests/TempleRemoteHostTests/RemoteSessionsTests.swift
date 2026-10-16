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

    /// Whether Temple's master answers, changeable mid-test.
    final class Flag { var value: Bool; init(_ value: Bool) { self.value = value } }

    private func controller(_ host: StandIn, store: @escaping () throws -> RemoteStateStore, failing: Bool = false,
                            master: Bool = true, masterFlag: Flag? = nil,
                            resolved: @escaping () -> [String: String] = { ["hostname": "box.example", "user": "u", "port": "22"] })
        -> RemoteSessions {
        let environment = host.environment
        return RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                              store: store,
                              resolve: { _ in .resolved(resolved()) },
                              makeExec: { _, path, _ in
                                  failing ? FailingExec() as RemoteExec : LocalShellExec(path: path, environment: environment)
                              },
                              masterCheck: { _ in masterFlag?.value ?? master })
    }

    private func controller(_ host: StandIn, store: RemoteStateStore, failing: Bool = false,
                            masterFlag: Flag? = nil) -> RemoteSessions {
        controller(host, store: { store }, failing: failing, masterFlag: masterFlag)
    }

    struct FailingExec: RemoteExec {
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
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

    private func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
        // Generous under a loaded full suite: the pane starts a real tmux server.
        let collected = await until(15) { if case .ok = await sessions.collect(first.handle) { return true }; return false }
        XCTAssertTrue(collected)
        let proven = try XCTUnwrap(store.run(first.handle))
        XCTAssertEqual(proven.creation, .proven)
        XCTAssertEqual(proven.socketPath, host.tmuxDir + "/tmux-\(getuid())/temple")
        XCTAssertEqual(proven.directory.map { URL(fileURLWithPath: $0).lastPathComponent }, "home")
        XCTAssertNil(host.record(RecordDirectory.marker(from: proven.recordPath)!), "acknowledged once written here")
        // The ok record is written before the pane execs the agent, so the
        // stand-in's argv file can lag it.
        let argvPath = host.home + "/claude-argv"
        let argvWritten = await until { (try? String(contentsOfFile: argvPath, encoding: .utf8))?.hasSuffix("sess-1\n") == true }
        XCTAssertTrue(argvWritten)
        XCTAssertEqual(try String(contentsOfFile: argvPath, encoding: .utf8),
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
        XCTAssertNil(second.launch.agentArgv.first, "an attach runs no pane")
        XCTAssertEqual(second.launch.socket, proven.socketPath)
        XCTAssertLessThanOrEqual(try XCTUnwrap(second.argv.last).utf8.count, LaunchStage.maximumCommandBytes)
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
        XCTAssertEqual(attach.launch.socket, run.socketPath, "attaches on the pinned socket")
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
                                      makeExec: { _, _, _ in counting })
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
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
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
                                      store: { store }, resolve: { _ in .resolved([:]) }, makeExec: { _, _, _ in gate })
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
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
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
        // Both answers are awaited whole: with `async let`, the first
        // failure would cancel the other open and hide what went wrong.
        let first = Task { try await a.open(request()) }
        let second = Task { try await b.open(request()) }
        let results = [await first.result, await second.result]
        let plans = try results.map { try plan($0.get()) }
        XCTAssertEqual(plans.filter(\.creating).count, 1)
        XCTAssertEqual(Set(plans.map(\.handle)).count, 1)
        XCTAssertEqual(try one.runs(host: record.host, sessionID: "sess-1").count, 1)
    }

    /// A stopped new session whose conversation was never confirmed is not
    /// resumed blindly: the host is asked for its transcript (in the config
    /// directory the CLI would use). Absent: Start a new session (the id
    /// afresh) or Discard. Present: resumed, and confirmed.
    func testAnUnconfirmedConversationIsCheckedOnTheHost() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store) {
            $0.conversation = .unconfirmed; $0.endedAt = Date(); $0.endEvidence = .killed
            $0.claudeConfig = .unset; $0.directory = host.home
        }
        let sessions = controller(host, store: store)
        let outcome = try await sessions.open(request(.resume))
        XCTAssertEqual(outcome, .needsDecision(checked: true), "no ~/.claude at all: checked to the end, absent")
        XCTAssertEqual(try store.runs(host: record.host).count, 1, "nothing reserved")
        let fresh = try plan(await sessions.open(request(.resume, startNew: true)))
        XCTAssertTrue(fresh.creating)
        XCTAssertEqual(fresh.agentArgv.suffix(2), ["--session-id", "sess-1"])
        try await sessions.abandon(fresh.handle, reason: "test")

        // The agent ran with a relative config root (as its pane recorded):
        // the check inspects exactly that root, under the folder it ran in.
        try store.update("h1") { $0.claudeConfig = .set("cfg dir\nx") }
        host.tree.write("home/cfg dir\nx/projects/-p/sess-1.jsonl", "{}\n")
        let present = await sessions.conversation(sessionID: "sess-1")
        XCTAssertEqual(present, .present)
        let resumed = try plan(await sessions.open(request(.resume)))
        XCTAssertTrue(resumed.creating)
        XCTAssertEqual(resumed.agentArgv.suffix(2), ["--resume", "sess-1"])
        XCTAssertEqual(try store.run("h1")?.conversation, .confirmed)

        // Discard: no run of the session is attached to or resumed again.
        try await sessions.dismiss(sessionID: "sess-1")
        let live = await sessions.liveRun(sessionID: "sess-1")
        XCTAssertNil(live)
    }

    /// The latest relevant run decides the root: one that left no config
    /// evidence makes the check unknown, never an older run's root.
    func testTheLatestRunDecidesTheConversationRootNeverAnOlderOne() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        let old = Date().addingTimeInterval(-60)
        try insertRun(store, handle: "h1") {
            $0.conversation = .unconfirmed; $0.endedAt = old; $0.endEvidence = .killed; $0.startedAt = old
            $0.claudeConfig = .unset; $0.directory = host.home
        }
        try insertRun(store, handle: "h2") {
            $0.conversation = .unconfirmed; $0.endedAt = Date(); $0.endEvidence = .killed
            $0.claudeConfig = nil; $0.directory = host.home
        }
        // The older root has a transcript; the newer run's root is unknown.
        host.tree.write("home/.claude/projects/-p/sess-1.jsonl", "{}\n")
        let sessions = controller(host, store: store)
        let check = await sessions.conversation(sessionID: "sess-1")
        guard case .unknown = check else { return XCTFail("never an older run's root: \(check)") }
        let outcome = try await sessions.open(request(.resume))
        XCTAssertEqual(outcome, .needsDecision(checked: false))
        // A creation that failed before anything ran is not the latest relevant run.
        try store.update("h2") { $0.creation = .failed }
        let older = await sessions.conversation(sessionID: "sess-1")
        XCTAssertEqual(older, .present)
    }

    /// A resume starts against the root its transcript was verified in
    /// (made absolute against the folder its run was in), not the login
    /// environment's current one.
    func testAResumeStartsAgainstTheRootItsTranscriptWasFoundIn() async throws {
        let host = StandIn()
        host.extra = ["CLAUDE_CONFIG_DIR": "/current/root"]
        let store = try RemoteStateStore()
        try insertRun(store) {
            $0.conversation = .unconfirmed; $0.endedAt = Date(); $0.endEvidence = .killed
            $0.claudeConfig = .set("old root"); $0.directory = host.home
        }
        host.tree.write("home/old root/projects/-p/sess-1.jsonl", "{}\n")
        let sessions = controller(host, store: store)
        let resumed = try plan(await sessions.open(request(.resume)))
        XCTAssertTrue(resumed.creating)
        XCTAssertEqual(resumed.agentArgv.suffix(2), ["--resume", "sess-1"])
        XCTAssertEqual(resumed.launch.claudeConfig, .set(host.home + "/old root"))
        XCTAssertTrue(TmuxKeepAlive().createScript(resumed.launch).contains("cv='\(host.home)/old root'"))
        // A new session still takes the login environment's root.
        try await sessions.abandon(resumed.handle, reason: "test")
        let fresh = try plan(await sessions.open(request(.new)))
        XCTAssertEqual(fresh.launch.claudeConfig, .set("/current/root"))
        try await sessions.abandon(fresh.handle, reason: "test")
    }

    /// First contact: no master when the open is planned, so the tab
    /// connects first (its ssh would authenticate and become the master),
    /// and the launch is staged once the master answers, never through the
    /// terminal. The tab's command is short whatever the launch carries.
    func testFirstContactStagesTheLaunchOnceTheMasterAnswers() async throws {
        let host = StandIn()
        try host.installRealTmux()
        installAgent(host)
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let store = try RemoteStateStore()
        let master = Flag(false)
        let sessions = controller(host, store: store, masterFlag: master)
        let folder = host.tree.directory(String(repeating: "deep folder ", count: 20)).path
        var big = request(directory: folder)
        big.extraArguments = ["--append-system-prompt", String(repeating: "x", count: 5_000)]
        let first = try plan(await sessions.open(big))
        XCTAssertFalse(first.staged)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.argv.last).utf8.count, LaunchStage.maximumCommandBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/" + first.stage))
        let client = try tab(host, first)
        defer { client.end() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(host.record(RecordDirectory.marker(from: try XCTUnwrap(store.run(first.handle)).recordPath)!),
                     "nothing runs before the launch is staged")
        master.value = true
        let staged = await sessions.stage(first.stage)
        XCTAssertEqual(staged, .staged)
        let again = await sessions.stage(first.stage)
        XCTAssertEqual(again, .none, "staged once")
        let collected = await until(15) { if case .ok = await sessions.collect(first.handle) { return true }; return false }
        XCTAssertTrue(collected)
        XCTAssertEqual(try store.run(first.handle)?.directory, canonical(folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/" + first.stage), "read, then gone")
    }

    /// A pending launch keeps the connection planned for its tab: it is
    /// staged over that connection's master only (`.overMaster`), even
    /// after another open re-resolved the alias to another target.
    func testAPendingStageUsesItsTabsOwnConnectionOverTheMasterOnly() async throws {
        final class Log { var execs: [(socket: String, purpose: SSHConnection.Purpose)] = []; var checks: [[String]] = [] }
        final class Target { var hostname = "a.example" }
        let host = StandIn()
        let store = try RemoteStateStore()
        let log = Log(), target = Target(), master = Flag(false)
        let environment = host.environment
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh", store: { store },
                                      resolve: { _ in .resolved(["hostname": target.hostname, "user": "u", "port": "22"]) },
                                      makeExec: { connection, path, purpose in
                                          log.execs.append((connection.controlPath, purpose))
                                          return LocalShellExec(path: path, environment: environment)
                                      },
                                      masterCheck: { argv in log.checks.append(argv); return master.value })
        let first = try plan(await sessions.open(request()))
        XCTAssertFalse(first.staged)
        let socketA = try XCTUnwrap(first.argv.first { $0.hasPrefix("ControlPath=") })
        // Another open re-resolves the alias to another target meanwhile.
        target.hostname = "b.example"
        let other = try plan(await sessions.open(RemoteSessions.OpenRequest(agent: .claude, sessionID: "sess-2", mode: .new,
                                                                            directory: "~")))
        let socketB = try XCTUnwrap(other.argv.first { $0.hasPrefix("ControlPath=") })
        XCTAssertNotEqual(socketA, socketB)
        log.execs.removeAll(); log.checks.removeAll()
        master.value = true
        let staged = await sessions.stage(first.stage)
        XCTAssertEqual(staged, .staged)
        XCTAssertFalse(log.checks.isEmpty)
        XCTAssertTrue(log.checks.allSatisfy { $0.contains(socketA) }, "the master asked about is the tab's own")
        XCTAssertEqual(log.execs.map(\.purpose), [.overMaster], "written over that master and nothing else")
        XCTAssertEqual(log.execs.map { "ControlPath=" + $0.socket }, [socketA])
    }

    /// The failure of a creation that never reached the host is claimed
    /// only once it is written: another attachment meanwhile leaves the
    /// run as it is (and the stop asks the host), and a write that fails
    /// is a storage error, the proof kept for the next try.
    func testANeverSentCreationIsReportedOnlyOnceItsFailureIsWritten() async throws {
        let host = StandIn()
        host.installStub()
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store, masterFlag: Flag(false))
        // Another attachment meanwhile: nothing to claim.
        let raced = try plan(await sessions.open(request()))
        _ = try store.update(raced.handle) { $0.attachment = 2 }
        let reason = try await sessions.markCreationUnproven(raced.handle)
        XCTAssertNil(reason)
        XCTAssertNotEqual(try store.run(raced.handle)?.creation, .failed)
        let stopped = try await sessions.stop(raced.handle, fromAttachedTab: false)
        XCTAssertNotEqual(stopped.outcome, .absent, "not claimed absent without the write")
        XCTAssertFalse(host.calls.isEmpty, "the stop asked the host")

        // Writes failing: a storage error, never a claim; then it is written.
        let fresh = controller(host, store: store, masterFlag: Flag(false))
        let planned = try plan(await fresh.open(RemoteSessions.OpenRequest(agent: .claude, sessionID: "sess-3", mode: .new,
                                                                           directory: "~")))
        try store.breakWritesForTests()
        do {
            _ = try await fresh.markCreationUnproven(planned.handle)
            XCTFail("a write that fails is said")
        } catch {}
        let unrecorded = try await fresh.stop(planned.handle, fromAttachedTab: false)
        XCTAssertNotNil(unrecorded.storageError)
        XCTAssertNotEqual(unrecorded.outcome, .absent)
        try store.mendWritesForTests()
        let written = try await fresh.markCreationUnproven(planned.handle)
        XCTAssertNotNil(written, "the proof was kept for the next try")
        XCTAssertEqual(try store.run(planned.handle)?.creation, .failed)
    }

    /// A launch refused before the spawn whose failure can't be written is
    /// a storage error, not a refusal that leaves the run unresolved.
    func testARefusedStagingWhoseFailureCannotBeWrittenIsAStorageError() async throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        chmod(host.home + "/.temple", 0o777)
        defer { chmod(host.home + "/.temple", 0o700) }
        let store = try RemoteStateStore()
        try store.breakWritesForTests()
        do {
            _ = try await controller(host, store: store).open(request())
            XCTFail("refused")
        } catch let error as RemoteSessions.OpenError {
            guard case .store = error else { return XCTFail("\(error)") }
        }
    }

    /// A creation whose launch never left this Mac cannot have run: when
    /// its tab ends, or is closed, it is failed (the next Open creates),
    /// never unproven or left running.
    func testACreationWhoseLaunchNeverLeftThisMacIsFailed() async throws {
        let host = StandIn()
        host.installStub()
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store, masterFlag: Flag(false))
        let first = try plan(await sessions.open(request()))
        let reason = try await sessions.markCreationUnproven(first.handle)
        XCTAssertNotNil(reason)
        XCTAssertEqual(try store.run(first.handle)?.creation, .failed)
        let next = try plan(await sessions.open(request()))
        XCTAssertTrue(next.creating, "the next Open creates")
        XCTAssertNotEqual(next.handle, first.handle)
        let stopped = try await sessions.stop(next.handle, fromAttachedTab: true)
        XCTAssertEqual(stopped.outcome, .absent)
        XCTAssertEqual(try store.run(next.handle)?.creation, .failed)
        XCTAssertNil(try store.run(next.handle)?.leftRunningAt)
        XCTAssertTrue(host.calls.isEmpty, "nothing was asked of tmux")
    }

    /// A launch the host refuses to stage is never spawned: the open is
    /// refused, with why, and its creation recorded failed.
    func testALaunchThatCannotBeStagedRefusesTheOpen() async throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        chmod(host.home + "/.temple", 0o777)
        defer { chmod(host.home + "/.temple", 0o700) }
        let store = try RemoteStateStore()
        let sessions = controller(host, store: store)
        do {
            _ = try await sessions.open(request())
            XCTFail("refused")
        } catch let error as RemoteSessions.OpenError {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Temple couldn't prepare the session on box:"), error.localizedDescription)
        }
        XCTAssertEqual(try store.runs(host: record.host).map(\.creation), [.failed])
    }

    /// Absent only when the right root was checked to the end: a root Temple
    /// doesn't know, or an ancestor it can't search, is unknown.
    func testAConversationCheckThatCannotSeeTheRootIsUnknown() async throws {
        let host = StandIn()
        let exec = host.exec
        let none = await ConversationCheck.run(sessionID: "s", config: nil, base: host.home, using: exec)
        guard case .unknown = none else { return XCTFail("\(none)") }
        let locked = host.tree.directory("locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o700) }
        let hidden = await ConversationCheck.run(sessionID: "s", config: .set(locked.path + "/cfg"), base: host.home, using: exec)
        guard case .unknown = hidden else { return XCTFail("an unsearchable ancestor proves nothing: \(hidden)") }
        let missing = await ConversationCheck.run(sessionID: "s", config: .set(host.home + "/nothing-here"), base: host.home, using: exec)
        XCTAssertEqual(missing, .absent)
    }

    func testAConversationTemplCantCheckIsUnknown() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        try insertRun(store) {
            $0.conversation = .unconfirmed; $0.endedAt = Date(); $0.endEvidence = .killed
            $0.claudeConfig = .unset; $0.directory = host.home
        }
        let outcome = try await controller(host, store: store, failing: true).open(request(.resume))
        XCTAssertEqual(outcome, .needsDecision(checked: false))
        // Resume, chosen by the user knowing Temple couldn't check.
        var unchecked = request(.resume)
        unchecked.resumeUnconfirmed = true
        let resumed = try plan(await controller(host, store: store).open(unchecked))
        XCTAssertEqual(resumed.agentArgv.suffix(2), ["--resume", "sess-1"])
    }

    /// No server on record: `-L temple`'s "can't find session" is not
    /// proof, in the exit check, the probe or the stop.
    func testWithoutAPinnedSocketNothingIsProvenAbsent() async throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_STATUS": "1", "STUB_ERR": "can't find session: temple-h1"]
        let store = try RemoteStateStore()
        try insertRun(store, creation: nil)
        let sessions = controller(host, store: store)
        guard case .unknown = await sessions.exitCheck("h1") else { return XCTFail() }
        let tracked = await sessions.trackedSessions()
        guard case .unknown = tracked.sessions.first?.state else { return XCTFail("\(tracked)") }
        let stop = try await sessions.stop("h1", fromAttachedTab: false)
        guard case .unconfirmed = stop.outcome else { return XCTFail("\(stop)") }
        XCTAssertNil(try store.run("h1")?.endedAt, "never Ended without its own server's word")
    }

    /// Diagnostics take the pane's output and nothing else: an `ok` whose
    /// write failed stays on the host for the next Open.
    func testDiagnosticsNeverAcknowledgeRecords() async throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        let store = try RemoteStateStore()
        try insertRun(store, creation: nil)
        let ok = "ok\nepoch\t1\npane\t2\t\nserver\t3\t\nsocket\t/tmp/s\ndir\t/x\n"
        try ok.write(toFile: host.recordDirectory + "/r-h1", atomically: true, encoding: .utf8)
        try "boom\n".write(toFile: host.recordDirectory + "/r-h1.out", atomically: true, encoding: .utf8)
        let sessions = controller(host, store: store)
        let words = await sessions.diagnostics("h1")
        XCTAssertEqual(words, "boom\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.recordDirectory + "/r-h1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/r-h1.out"))
    }

    /// A PATH resolved over connection A that answers after the alias moved
    /// to B is not cached for B.
    func testAPathResolvedForAnOldConnectionIsNotCached() async throws {
        let host = StandIn()
        let store = try RemoteStateStore()
        var target = "a.example"
        let gate = HeldEnvironmentExec()
        let sessions = RemoteSessions(record: record, stateDirectory: host.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store },
                                      resolve: { _ in .resolved(["hostname": target, "user": "u", "port": "22"]) },
                                      makeExec: { _, _, _ in gate })
        let first = Task { try await sessions.queryExec() }
        try await Task.sleep(for: .milliseconds(50))
        target = "b.example"
        _ = try await sessions.resolvedConnection(refresh: true)
        gate.release()
        _ = try await first.value
        XCTAssertEqual(sessions.pathState, .unresolved)
    }

    final class HeldEnvironmentExec: RemoteExec, @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func release() { lock.withLock { released = true } }
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
            while !lock.withLock({ released }) { try await Task.sleep(nanoseconds: 10_000_000) }
            return RemoteOutput(status: 0, stdout: "shell /bin/sh\n\(args[0])\n/A/bin:/usr/bin\n\(args[0]).cfg\n\(args[0])\n", stderr: "")
        }
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
                                      makeExec: { _, _, _ in counting })
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
