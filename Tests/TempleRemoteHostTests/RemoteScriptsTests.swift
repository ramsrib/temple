import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// The launch wrapper, the pane, the record fetch and the queries, executed
/// under `/bin/sh` against a temp `HOME` (docs/designs/remote-ssh.md section
/// 11): first with a stub `tmux` that records its argv, then, where a real
/// tmux is installed, against a private server under the test's own
/// `TMUX_TMPDIR`, never the user's.
final class RemoteScriptsTests: XCTestCase {
    // MARK: A stand-in host

    /// A temp HOME, TMPDIR and TMUX_TMPDIR, and a `bin` on PATH.
    final class StandIn {
        let tree = TempTree("temple-scripts")
        var home: String { tree.path + "/home" }
        var bin: String { tree.path + "/bin" }
        var tmuxDir: String { tree.path + "/tmux" }
        var log: String { tree.path + "/tmux.log" }
        var extra: [String: String] = [:]

        init() {
            _ = tree.directory("home")
            _ = tree.directory("bin")
            _ = tree.directory("tmux")
        }

        var path: String { "\(bin):/usr/bin:/bin" }

        var environment: [String: String] {
            var environment = hostEnvironment(home: home, path: path,
                                              extra: ["TMUX_TMPDIR": tmuxDir, "STUB_LOG": log, "TERM": "xterm-256color"])
            environment.merge(extra) { $1 }
            return environment
        }

        var recordDirectory: String { home + "/tmp/temple-launch-\(getuid())" }

        var exec: LocalShellExec { LocalShellExec(path: nil, environment: environment) }

        /// The stub: logs its argv (tab-separated, one call per line), runs
        /// the pane like a server would when asked, then fails as told.
        func installStub() {
            tree.write("bin/tmux", #"""
            #!/bin/sh
            { printf 'call'; for a in "$@"; do printf '\t%s' "$(printf '%s' "$a" | tr '\n' '\036')"; done; printf '\n'; } >> "$STUB_LOG"
            rec=; pane=; prev=; ppath=$PATH
            for a in "$@"; do
              case $prev in -e) case $a in TEMPLE_RECORD=*) rec=${a#TEMPLE_RECORD=};; PATH=*) ppath=${a#PATH=};; esac;; esac
              prev=$a; pane=$a
            done
            case " $* " in *" new-session "*) [ -n "$STUB_RUN_PANE" ] && TEMPLE_RECORD=$rec TMUX="$STUB_SOCKET,4242,0" PATH=$ppath /bin/sh -c "$pane" ;; esac
            [ -n "$STUB_ERR" ] && printf '%s\n' "$STUB_ERR" >&2
            exit ${STUB_STATUS:-0}
            """#, executable: true)
        }

        func installRealTmux() throws {
            guard let tmux = installedTmux() else { throw XCTSkip("no tmux installed on this Mac") }
            try FileManager.default.createSymbolicLink(atPath: bin + "/tmux", withDestinationPath: tmux)
        }

        /// Runs a remote command the way the host's login shell would.
        @discardableResult
        func runLaunch(_ command: String) throws -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = environment
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        var calls: [[String]] {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map {
                $0.split(separator: "\t", omittingEmptySubsequences: false).map {
                    String($0).replacingOccurrences(of: "\u{1e}", with: "\n")
                }
            }
        }

        func record(_ marker: String) -> String? { try? String(contentsOfFile: recordDirectory + "/" + marker, encoding: .utf8) }

        func tmux(_ args: [String]) throws -> RemoteOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin + "/tmux")
            process.arguments = args
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            return RemoteOutput(status: process.terminationStatus,
                                stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                                stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    /// A tmux client on a pty, as the tab's ssh gives it one: `script`
    /// with a stdin that stays open (on EOF it would end the client).
    final class PTYClient {
        let process = Process()
        private let input = Pipe()
        init(_ command: String, environment: [String: String]) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
            process.environment = environment
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        /// Temple's Detach: the local client goes; the agent stays.
        func end() {
            // `script` can sit out a SIGTERM; a SIGKILL closes the pty all the
            // same, and the client on it is hung up.
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        deinit { end() }
    }

    private func plan(_ host: StandIn, handle: String = "h1", marker: String = "m1", directory: String? = nil,
                      argv: [String]? = nil, path: String?? = .none, socket: String? = nil) -> RemoteLaunchPlan {
        RemoteLaunchPlan(handle: handle, marker: marker, directory: directory ?? host.home,
                         agentArgv: argv ?? ["/bin/sh", "-c", "sleep 30"],
                         path: path ?? host.path, socket: socket)
    }

    /// `realpath`: Foundation's symlink resolution turns /private/tmp into
    /// /tmp, which is not what `pwd -P` says.
    private func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try condition()
    }

    // MARK: The wrapper (stub tmux)

    func testCreationIsOneClientInvocationConfiguringThenCreating() throws {
        let host = StandIn()
        host.installStub()
        let keepAlive = TmuxKeepAlive()
        try host.runLaunch(keepAlive.createCommand(plan(host)))
        let calls = host.calls
        XCTAssertEqual(calls.count, 1, "one command queue, one client")
        let argv = Array(calls[0].dropFirst())
        XCTAssertEqual(Array(argv.prefix(5)), ["-L", "temple", "-f", "/dev/null", "start-server"])
        // Every configure command, in order, before new-session.
        let joined = argv.joined(separator: " ")
        var cursor = joined.startIndex
        for command in TmuxChain.configure {
            let words = command.words.replacingOccurrences(of: "'", with: "")
            let range = try XCTUnwrap(joined.range(of: words, range: cursor..<joined.endIndex), command.name)
            cursor = range.upperBound
        }
        let newSession = try XCTUnwrap(argv.firstIndex(of: "new-session"))
        XCTAssertGreaterThan(newSession, 5)
        XCTAssertEqual(Array(argv[newSession...].prefix(9)),
                       ["new-session", "-s", "temple-h1", "-c", host.home, "-e", "PATH=\(host.path)",
                        "-e", "TEMPLE_RECORD=\(host.recordDirectory)/m1"])
        XCTAssertFalse(argv.contains("-A"), "a duplicate is a loud failure, never an attach")
        XCTAssertTrue(argv.last?.hasPrefix("exec 'sh' '-c' ") == true, "\(argv.last ?? "")")
    }

    func testAttachUsesThePinnedSocketRunsNoPaneAndWritesNoRecord() throws {
        let host = StandIn()
        host.installStub()
        let keepAlive = TmuxKeepAlive()
        try host.runLaunch(keepAlive.attachCommand(plan(host, socket: "/tmp/tmux-1000/temple")))
        try host.runLaunch(keepAlive.attachCommand(plan(host, socket: nil)))
        XCTAssertEqual(host.calls.map { Array($0.dropFirst()) }, [
            ["-S", "/tmp/tmux-1000/temple", "attach-session", "-t", "=temple-h1"],
            ["-L", "temple", "attach-session", "-t", "=temple-h1"],
        ])
        let records = (try? FileManager.default.contentsOfDirectory(atPath: host.recordDirectory)) ?? []
        XCTAssertEqual(records, [])
    }

    func testAFailedClientGoesToItsOwnRecordAndNeverOverwritesThePanesOK() throws {
        let host = StandIn()
        host.installStub()
        // The session and pane exist, then the client fails.
        host.extra = ["STUB_RUN_PANE": "1", "STUB_SOCKET": "/tmp/tmux-1000/temple", "STUB_STATUS": "1",
                      "STUB_ERR": "open terminal failed: missing or unsuitable terminal: xterm-ghostty"]
        let result = try host.runLaunch(TmuxKeepAlive().createCommand(plan(host, argv: ["/bin/sh", "-c", "exit 0"])))
        XCTAssertEqual(result.status, 1)
        let pane = try XCTUnwrap(host.record("m1"))
        XCTAssertTrue(pane.hasPrefix("ok\n"), pane)
        let client = try XCTUnwrap(host.record("m1.client"))
        XCTAssertEqual(client, "failed\ttmux\t1\topen terminal failed: missing or unsuitable terminal: xterm-ghostty\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/m1.err"))
        let collected = try LaunchRecords.parseFetch(Data("pane \(pane.utf8.count)\n\(pane)client \(client.utf8.count)\n\(client)end\n".utf8))
        guard case .ok = collected.pane else { return XCTFail("\(collected)") }
        XCTAssertEqual(collected.client, ClientFailure(status: 1, line: "open terminal failed: missing or unsuitable terminal: xterm-ghostty"))
    }

    func testWithoutAResolvedPathTheLaunchAsksTheLoginShell() throws {
        let host = StandIn()
        host.installStub()
        host.tree.write("bin/fakeshell", """
        #!/bin/sh
        while [ $# -gt 1 ]; do shift; done
        echo 'motd chatter'
        PATH=\(host.bin):/login/only/bin:/usr/bin:/bin; export PATH
        eval "$1"
        """, executable: true)
        host.extra = ["SHELL": host.bin + "/fakeshell"]
        try host.runLaunch(TmuxKeepAlive().createCommand(plan(host, path: .some(nil))))
        let argv = try XCTUnwrap(host.calls.first)
        XCTAssertTrue(argv.contains("PATH=\(host.bin):/login/only/bin:/usr/bin:/bin"), "\(argv)")
    }

    func testStaleRecordsAreSweptByTheNextLaunch() throws {
        let host = StandIn()
        host.installStub()
        try FileManager.default.createDirectory(atPath: host.recordDirectory, withIntermediateDirectories: true)
        let old = host.recordDirectory + "/old", fresh = host.recordDirectory + "/fresh"
        FileManager.default.createFile(atPath: old, contents: Data("ok\n".utf8))
        FileManager.default.createFile(atPath: fresh, contents: Data("ok\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old)
        try host.runLaunch(TmuxKeepAlive().createCommand(plan(host)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }

    func testTheRecordDirectoryIsPrivate() throws {
        let host = StandIn()
        host.installStub()
        try host.runLaunch(TmuxKeepAlive().createCommand(plan(host)))
        var info = stat()
        XCTAssertEqual(stat(host.recordDirectory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    // MARK: The pane

    private func runPane(_ host: StandIn, directory: String, argv: [String], record: String,
                         tmux: String = "/tmp/tmux-1000/te,mp le,77,3") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // As tmux would run it: the server's /bin/sh -c '<pane command>'.
        process.arguments = ["-c", TmuxKeepAlive.paneCommand(directory: directory, agentArgv: argv)]
        var environment = host.environment
        environment["TEMPLE_RECORD"] = record
        environment["TMUX"] = tmux
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testThePaneRecordsOKThenExecsTheAgentAsItsOwnPid() throws {
        let host = StandIn()
        let record = host.tree.path + "/rec"
        let pidFile = host.tree.path + "/agent.pid"
        let status = try runPane(host, directory: host.home, argv: ["/bin/sh", "-c", "echo $$ > \"$1\"; echo \"$TEMPLE_RECORD\" > \"$1.env\"", "agent", pidFile], record: record)
        XCTAssertEqual(status, 0)
        let text = try String(contentsOfFile: record, encoding: .utf8)
        guard case .ok(let evidence) = LaunchRecords.parsePane(text) else { return XCTFail(text) }
        let agentPID = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(String(evidence.panePID), agentPID, "the pane execs the agent")
        XCTAssertEqual(evidence.directory, canonical(host.home))
        // $TMUX parsed from the right: a socket path may hold commas.
        XCTAssertEqual(evidence.socketPath, "/tmp/tmux-1000/te,mp le")
        XCTAssertEqual(evidence.serverPID, 77)
        XCTAssertLessThan(abs(evidence.epoch - Int(Date().timeIntervalSince1970)), 60)
        XCTAssertNil(evidence.paneStart, "no /proc on this Mac")
        XCTAssertEqual(try String(contentsOfFile: pidFile + ".env", encoding: .utf8), "\n", "the agent never sees the record path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record + ".tmp"), "atomic: written beside, then moved")
    }

    func testThePaneExpandsTildeItselfAndRecordsTheCanonicalFolder() throws {
        let host = StandIn()
        let real = host.tree.directory("real/it's a \"project\"")
        try FileManager.default.createSymbolicLink(atPath: host.home + "/link", withDestinationPath: real.path)
        let record = host.tree.path + "/rec"
        XCTAssertEqual(try runPane(host, directory: "~/link", argv: ["/usr/bin/true"], record: record), 0)
        guard case .ok(let evidence) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(evidence.directory, canonical(real.path))
        XCTAssertEqual(try runPane(host, directory: "~", argv: ["/usr/bin/true"], record: record), 0)
        guard case .ok(let home) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(home.directory, canonical(host.home))
    }

    func testThePaneThatCannotEnterItsFolderRecordsFailedAndRunsNothing() throws {
        let host = StandIn()
        let record = host.tree.path + "/rec"
        let ran = host.tree.path + "/ran"
        let status = try runPane(host, directory: host.home + "/gone", argv: ["/usr/bin/touch", ran], record: record)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)), .failedCD(status: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran))
    }

    func testQuotingSurvivesTheWholeChain() throws {
        let host = StandIn()
        host.installStub()
        host.extra = ["STUB_RUN_PANE": "1", "STUB_SOCKET": "/tmp/s"]
        let odd = "it's \\ a 'quoted' \"dir\"\nwith a newline $(id) `id` ${HOME}"
        let folder = host.tree.directory("home/" + odd)
        let out = host.tree.path + "/argv"
        let args = ["/bin/sh", "-c", "for a in \"$@\"; do printf '%s|' \"$a\"; done > \"$0\"", out, "a'b", "c\\d", "$HOME", "e f"]
        try host.runLaunch(TmuxKeepAlive().createCommand(plan(host, directory: folder.path, argv: args)))
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "a'b|c\\d|$HOME|e f|")
        guard case .ok(let evidence)? = host.record("m1").map(LaunchRecords.parsePane) else { return XCTFail() }
        XCTAssertEqual(evidence.directory, canonical(folder.path))
    }

    // MARK: Records over the exec seam

    func testFetchRecoversByNameThenAcknowledgeDeletes() async throws {
        let host = StandIn()
        try FileManager.default.createDirectory(atPath: host.recordDirectory, withIntermediateDirectories: true)
        let dir = "/srv/a folder\twith a tab"
        let ok = "ok\nepoch\t1700000000\npane\t4321\t998877\nserver\t4000\t12\nsocket\t/tmp/tmux-1000/temple\ndir\t\(dir)\n"
        try ok.write(toFile: host.recordDirectory + "/mk", atomically: true, encoding: .utf8)
        let fetched = try await LaunchRecords.fetch(marker: "mk", using: host.exec)
        XCTAssertEqual(fetched.pane, .ok(LaunchEvidence(epoch: 1_700_000_000, directory: dir, panePID: 4321, paneStart: "998877",
                                                        socketPath: "/tmp/tmux-1000/temple", serverPID: 4000, serverStart: "12")))
        XCTAssertNil(fetched.client)
        await LaunchRecords.acknowledge(marker: "mk", using: host.exec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/mk"))
        let none = try await LaunchRecords.fetch(marker: "mk", using: host.exec)
        XCTAssertTrue(none.isEmpty)
    }

    func testFolderCheckResolvesAndSaysWhenItIsMissing() async throws {
        let host = StandIn()
        let real = host.tree.directory("home/Projects/x")
        try FileManager.default.createSymbolicLink(atPath: host.home + "/px", withDestinationPath: real.path)
        let resolved = await FolderCheck.run("~/px", using: host.exec)
        XCTAssertEqual(resolved, .exists(resolved: canonical(real.path)))
        let missing = await FolderCheck.run("~/nope", using: host.exec)
        XCTAssertEqual(missing, .missing)
    }

    // MARK: Decoding

    func testLivenessContract() {
        func out(_ status: Int32, _ stderr: String, reached: Bool = true) -> RemoteOutput {
            RemoteOutput(status: status, stdout: "", stderr: stderr, reachedCommand: reached)
        }
        XCTAssertEqual(Liveness.classify(out(0, "")), .present)
        XCTAssertEqual(Liveness.classify(out(1, "can't find session: temple-h1\n")), .absent)
        XCTAssertEqual(Liveness.classify(out(1, "no server running on /tmp/tmux-1000/temple\n")),
                       .unknown(reason: "no server running on /tmp/tmux-1000/temple", socketMissing: true))
        // tmux 3.2a's socket-missing words.
        XCTAssertEqual(Liveness.classify(out(1, "error connecting to /tmp/tmux-1000/temple (No such file or directory)\n")),
                       .unknown(reason: "error connecting to /tmp/tmux-1000/temple (No such file or directory)", socketMissing: true))
        XCTAssertEqual(Liveness.classify(out(1, "error connecting to /tmp/x (Permission denied)\n")),
                       .unknown(reason: "error connecting to /tmp/x (Permission denied)", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(1, "protocol version mismatch (client 8, server 7)\n")),
                       .unknown(reason: "protocol version mismatch (client 8, server 7)", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(127, "")), .unknown(reason: "tmux is not on PATH", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(255, "ssh: connect to host x port 22: Connection refused", reached: false)),
                       .unknown(reason: "ssh: connect to host x port 22: Connection refused", socketMissing: false))
    }

    func testOneDecodedStopOutcome() {
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 0, stdout: "", stderr: "")), .killed)
        // The false branch exits 0 too: the marker decides, never the status.
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 0, stdout: "temple-not-killed\n", stderr: "")), .refused)
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 1, stdout: "", stderr: "can't find session: temple-h1")), .absent)
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 1, stdout: "", stderr: "no server running on /tmp/s")),
                       .unconfirmed(reason: "no server running on /tmp/s", reachedHost: true))
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 255, stdout: "", stderr: "Connection timed out", reachedCommand: false)),
                       .unconfirmed(reason: "Connection timed out", reachedHost: false))
        XCTAssertEqual(StopOutcome.failed(RemoteExecError.deadline(seconds: 10)),
                       .unconfirmed(reason: "Didn't answer within 10 seconds.", reachedHost: true))
    }

    // MARK: Real tmux

    private func launchClient(_ host: StandIn, _ command: String) throws -> PTYClient {
        try PTYClient(command, environment: host.environment)
    }

    private func attachedCount(_ host: StandIn, _ session: String) throws -> Int? {
        let out = try host.tmux(["-L", "temple", "display-message", "-p", "-t", "=\(session):", "#{session_attached}"])
        return out.status == 0 ? Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    func testRealTmuxLifecycle() async throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }

        // First launch: no server yet.
        let a = try launchClient(host, keepAlive.createCommand(plan(host, handle: "ha", marker: "ma")))
        XCTAssertTrue(try waitFor { host.record("ma") != nil })
        guard case .ok(let evidence)? = host.record("ma").map(LaunchRecords.parsePane) else { return XCTFail() }
        XCTAssertEqual(evidence.socketPath, host.tmuxDir + "/tmux-\(getuid())/temple")
        XCTAssertEqual(try attachedCount(host, "temple-ha"), 1)
        // The chain's configuration took.
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "status"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "off")
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "prefix"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "None")

        // A second launch against the running server, in the same folder.
        let b = try launchClient(host, keepAlive.createCommand(plan(host, handle: "hb", marker: "mb")))
        XCTAssertTrue(try waitFor { host.record("mb") != nil })

        // An attach, on the pinned socket, writes no record.
        let pinned = evidence.socketPath
        let records = try FileManager.default.contentsOfDirectory(atPath: host.recordDirectory).sorted()
        let second = try launchClient(host, keepAlive.attachCommand(plan(host, handle: "ha", marker: "mz", socket: pinned)))
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-ha") == 2 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: host.recordDirectory).sorted(), records)

        let exec = host.exec
        let present = await keepAlive.liveness(session: "temple-ha", socket: pinned, using: exec)
        XCTAssertEqual(present, .present)

        // Temple's own client goes first; another is still attached: refused.
        a.end()
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-ha") == 1 })
        let refused = await keepAlive.stop(session: "temple-ha", socket: pinned, waitTenths: 5, using: exec)
        XCTAssertEqual(refused, .refused)
        XCTAssertEqual(try attachedCount(host, "temple-ha"), 1, "nothing killed")

        // No one attached: killed, and the acknowledgement is the evidence.
        second.end()
        let killed = await keepAlive.stop(session: "temple-ha", socket: pinned, waitTenths: 30, using: exec)
        XCTAssertEqual(killed, .killed)
        let absent = await keepAlive.liveness(session: "temple-ha", socket: pinned, using: exec)
        XCTAssertEqual(absent, .absent, "the server lives on for hb and answers")

        // A listing names what is there.
        let listing = await keepAlive.list(using: exec)
        XCTAssertEqual(listing, .listed([SessionListing.Entry(name: "temple-hb", attached: 1)]))

        // The last session: stopped, the server exits, and a later check
        // reads "no server running", which is unknown in v1.
        b.end()
        let last = await keepAlive.stop(session: "temple-hb", socket: pinned, waitTenths: 30, using: exec)
        XCTAssertEqual(last, .killed)
        let after = await keepAlive.liveness(session: "temple-hb", socket: pinned, using: exec)
        guard case .unknown(_, true) = after else { return XCTFail("\(after)") }
        let noServer = await keepAlive.list(using: exec)
        XCTAssertEqual(noServer, .noServer)

        // A socket Temple may not reach is unknown, never absent.
        let locked = host.tree.directory("locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o700) }
        let denied = await keepAlive.liveness(session: "temple-hb", socket: locked.path + "/sock", using: exec)
        guard case .unknown(_, false) = denied else { return XCTFail("\(denied)") }
    }

    func testRealTmuxStopRefusesWhenTemplesClientWasReplacedBeforeItRan() async throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let ours = try launchClient(host, keepAlive.createCommand(plan(host, handle: "hr", marker: "mr")))
        XCTAssertTrue(try waitFor { host.record("mr") != nil })
        // Temple detaches its own client, and before the stop runs, someone
        // else attaches: the count is 1 again, but it is not Temple's.
        ours.end()
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-hr") == 0 })
        let other = try launchClient(host, "tmux -L temple attach-session -t =temple-hr")
        defer { other.end() }
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-hr") == 1 })
        let outcome = await keepAlive.stop(session: "temple-hr", socket: nil, waitTenths: 5, using: host.exec)
        XCTAssertEqual(outcome, .refused)
        let present = await keepAlive.liveness(session: "temple-hr", socket: nil, using: host.exec)
        XCTAssertEqual(present, .present)
    }

    func testRealTmuxFirstLaunchAfterTheLastSessionExitedAndPathFromTheClient() throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let out = host.tree.path
        // A session whose agent exits at once: the server goes with it.
        let first = try launchClient(host, keepAlive.createCommand(plan(host, handle: "h1", marker: "m1",
                                                                        argv: ["/bin/sh", "-c", "exit 0"])))
        XCTAssertTrue(try waitFor { !first.process.isRunning })
        // The next launch configures a fresh server in the same queue.
        let second = try launchClient(host, keepAlive.createCommand(plan(host, handle: "h2", marker: "m2",
            argv: ["/bin/sh", "-c", "printf '%s\\n' \"$PATH\" > \(out)/p2; printf '%s\\n' \"$TERM\" > \(out)/t2; sleep 30"],
            path: .some("\(host.bin):/first/path:/usr/bin:/bin"))))
        defer { second.end() }
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/t2") })
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "status"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "off")
        // A server started with one PATH: -e hands the next pane its own.
        let third = try launchClient(host, keepAlive.createCommand(plan(host, handle: "h3", marker: "m3",
            argv: ["/bin/sh", "-c", "printf '%s\\n' \"$PATH\" > \(out)/p3; sleep 30"],
            path: .some("\(host.bin):/third/path:/usr/bin:/bin"))))
        defer { third.end() }
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/p3") })
        XCTAssertEqual(try String(contentsOfFile: out + "/p2", encoding: .utf8), "\(host.bin):/first/path:/usr/bin:/bin\n")
        XCTAssertEqual(try String(contentsOfFile: out + "/p3", encoding: .utf8), "\(host.bin):/third/path:/usr/bin:/bin\n")
        // The attached client is xterm-256color outside, tmux-256color in the pane.
        XCTAssertEqual(try String(contentsOfFile: out + "/t2", encoding: .utf8), "tmux-256color\n")
        let clients = try host.tmux(["-L", "temple", "list-clients", "-t", "=temple-h2", "-F", "#{client_termname}"])
        XCTAssertEqual(clients.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "xterm-256color")
    }
}
