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

        var recordDirectory: String { home + "/.temple/launch" }

        /// The record directory as the launch makes it: private, this user's.
        func makeRecordDirectory() throws {
            try FileManager.default.createDirectory(atPath: recordDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            chmod(home + "/.temple", 0o700)
            chmod(recordDirectory, 0o700)
        }

        var exec: LocalShellExec { LocalShellExec(path: nil, environment: environment) }

        /// The stub: logs its argv (tab-separated, one call per line), runs
        /// the pane like a server would when asked, then fails as told.
        func installStub() {
            tree.write("bin/tmux", #"""
            #!/bin/sh
            { printf 'call'; for a in "$@"; do printf '\t%s' "$(printf '%s' "$a" | tr '\n' '\036')"; done; printf '\n'; } >> "$STUB_LOG"
            rec=; pane=; prev=; ppath=$PATH; cfg=; cfgv=; cdx=; cdxv=
            for a in "$@"; do
              case $prev in -e) case $a in TEMPLE_RECORD=*) rec=${a#TEMPLE_RECORD=};; PATH=*) ppath=${a#PATH=};;
                TEMPLE_CFG=*) cfg=${a#TEMPLE_CFG=};; TEMPLE_CFG_VALUE=*) cfgv=${a#TEMPLE_CFG_VALUE=};;
                TEMPLE_CDX=*) cdx=${a#TEMPLE_CDX=};; TEMPLE_CDX_VALUE=*) cdxv=${a#TEMPLE_CDX_VALUE=};; esac;; esac
              prev=$a; pane=$a
            done
            case " $* " in *" new-session "*) [ -n "$STUB_RUN_PANE" ] && TEMPLE_RECORD=$rec TEMPLE_CFG=$cfg TEMPLE_CFG_VALUE=$cfgv TEMPLE_CDX=$cdx TEMPLE_CDX_VALUE=$cdxv TMUX="$STUB_SOCKET,4242,0" PATH=$ppath /bin/sh -c "$pane" ;; esac
            [ -n "$STUB_ERR" ] && printf '%s\n' "$STUB_ERR" >&2
            exit ${STUB_STATUS:-0}
            """#, executable: true)
        }

        func installRealTmux() throws {
            guard let tmux = installedTmux() else { throw XCTSkip("no tmux installed on this Mac") }
            try FileManager.default.createSymbolicLink(atPath: bin + "/tmux", withDestinationPath: tmux)
        }

        /// A launch script staged as Temple leaves it (`~/.temple/launch/
        /// <name>`, 0600; the directory made private only when missing, so a
        /// test's unsafe one stays unsafe), and the tab's short command
        /// that runs it. `LaunchStage.write` itself is tested on its own.
        func staged(_ script: String) -> String {
            let name = "st-" + RemoteQuoting.nonce()
            let directory = (environment["HOME"] ?? home) + "/.temple/launch"
            if !FileManager.default.fileExists(atPath: directory) {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                chmod((environment["HOME"] ?? home) + "/.temple", 0o700)
            }
            let file = directory + "/" + name
            FileManager.default.createFile(atPath: file, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600])
            return LaunchStage.command(stage: name)
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

        func tmuxFreeRun(_ executable: String, _ args: [String]) throws -> RemoteOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return RemoteOutput(status: process.terminationStatus,
                                stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), stderr: "")
        }

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
        private var ended = false
        func end() {
            guard !ended else { return }
            ended = true
            // `script` can sit out a SIGTERM; a SIGKILL closes the pty all the
            // same, and the client on it is hung up. `isRunning` is polled:
            // `waitUntilExit` off the main thread can wait for a notification
            // that never comes.
            if process.isRunning { process.terminate() }
            var deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            try? input.fileHandleForWriting.close()
        }
        deinit { end() }
    }

    private func plan(_ host: StandIn, handle: String = "h1", marker: String = "m1", directory: String? = nil,
                      argv: [String]? = nil, path: RemoteLaunchPlan.Path? = nil, socket: String? = nil) -> RemoteLaunchPlan {
        RemoteLaunchPlan(handle: handle, marker: marker, directory: directory ?? host.home,
                         agentArgv: argv ?? ["/bin/sh", "-c", "sleep 30"],
                         path: path ?? .resolved(host.path), socket: socket)
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

    // MARK: Staging (LaunchStage)

    /// The staging query takes the script on stdin, puts it in the private
    /// record directory whole (0600), never over an existing name, and
    /// refuses a short payload or an unsafe directory with nothing left
    /// behind.
    func testALaunchIsStagedWholeFromStdinOrRefused() async throws {
        let host = StandIn()
        let script = "echo staged\n# " + String(repeating: "é'\"$x\\", count: 4000) + "\n"
        let name = "r-abc.s-c" + RemoteQuoting.nonce()
        let staged = await LaunchStage.write(stage: name, script: script, using: host.exec)
        XCTAssertEqual(staged, .staged)
        let file = host.recordDirectory + "/" + name
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), script)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        guard case .refused(let again) = await LaunchStage.write(stage: name, script: "other", using: host.exec) else {
            return XCTFail("never over an existing name")
        }
        XCTAssertTrue(again.contains("already exists"), again)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), script)
        // A payload cut short in transit is refused, and nothing is left.
        let short = try await host.exec.run(script: LaunchStage.writeScript, args: ["r-abc.s-cshort", "99999"],
                                            input: Data("partial".utf8), deadline: 5)
        XCTAssertTrue(short.stdout.contains("temple-stage-refused only 7 of 99999 bytes arrived"), short.stdout)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: host.recordDirectory).sorted(), [name])
        // A directory others can write to is no place for a launch.
        chmod(host.home + "/.temple", 0o777)
        defer { chmod(host.home + "/.temple", 0o700) }
        guard case .refused = await LaunchStage.write(stage: "r-abc.s-cunsafe", script: script, using: host.exec) else {
            return XCTFail("an unsafe directory refuses")
        }
    }

    /// The tab's command finds its staged launch, deletes it, and runs it;
    /// one that never comes is said in the tab, with nothing run.
    func testTheTabsCommandRunsItsStagedLaunchOnceOrSaysItIsMissing() async throws {
        let host = StandIn()
        let out = host.tree.path + "/ran"
        let name = "r-abc.s-c" + RemoteQuoting.nonce()
        _ = await LaunchStage.write(stage: name, script: "printf '%s' \"$0 ran\" > \(RemoteQuoting.quote(out))\n",
                                    using: host.exec)
        let run = try host.runLaunch(LaunchStage.command(stage: name, wait: 2))
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "temple-launch ran")
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/" + name), "read once, then gone")
        let missing = try host.runLaunch(LaunchStage.command(stage: "r-abc.s-cnever", wait: 1))
        XCTAssertEqual(missing.status, 125)
        XCTAssertTrue(missing.stderr.contains("Temple couldn't find a safely stored launch"), missing.stderr)
    }

    /// The executor checks the private chain and the file itself before it
    /// reads anything, and takes the file by renaming it inside the
    /// checked directory: each unsafe case is refused by the executor
    /// itself (status 125, said in the tab), and nothing runs. (A file or
    /// directory owned by another account needs a second account to set
    /// up; the same `-user` check covers it.)
    func testTheExecutorRefusesAnythingButAPrivateStagedFile() throws {
        enum Case: CaseIterable {
            case fine, fileWritableByOthers, fileNot0600, fileIsALink, fileIsADirectory
            case templeWritableByGroup, templeIsALink, launchNot0700, launchIsALink
        }
        for setup in Case.allCases {
            let host = StandIn()
            let ran = host.tree.path + "/ran"
            let script = "touch \(RemoteQuoting.quote(ran))\n"
            let temple = host.home + "/.temple", launch = temple + "/launch", name = "st-case"
            let elsewhere = host.tree.directory("elsewhere").path
            chmod(elsewhere, 0o700)
            switch setup {
            case .templeIsALink:
                try FileManager.default.createDirectory(atPath: elsewhere + "/launch", withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(atPath: temple, withDestinationPath: elsewhere)
            case .launchIsALink:
                try FileManager.default.createDirectory(atPath: temple, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(atPath: launch, withDestinationPath: elsewhere)
            default:
                try host.makeRecordDirectory()
            }
            let file = launch + "/" + name
            if setup == .fileIsALink {
                FileManager.default.createFile(atPath: elsewhere + "/real", contents: Data(script.utf8),
                                               attributes: [.posixPermissions: 0o600])
                try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: elsewhere + "/real")
            } else if setup == .fileIsADirectory {
                try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } else {
                FileManager.default.createFile(atPath: file, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600])
            }
            switch setup {
            case .fileWritableByOthers: chmod(file, 0o622)
            case .fileNot0600: chmod(file, 0o644)
            case .templeWritableByGroup: chmod(temple, 0o770)
            case .launchNot0700: chmod(launch, 0o755)
            default: break
            }
            let result = try host.runLaunch(LaunchStage.command(stage: name, wait: 1))
            if setup == .fine {
                XCTAssertEqual(result.status, 0, result.stderr)
                XCTAssertTrue(FileManager.default.fileExists(atPath: ran))
                XCTAssertFalse(FileManager.default.fileExists(atPath: file), "taken, then gone")
            } else {
                XCTAssertEqual(result.status, 125, "\(setup): \(result.stderr)")
                XCTAssertTrue(result.stderr.contains("Temple couldn't find a safely stored launch"), "\(setup)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: ran), "\(setup): nothing ran")
                switch setup {
                case .fileWritableByOthers, .fileNot0600, .fileIsALink, .fileIsADirectory:
                    // Taken from a private directory, refused, and removed
                    // whole (a link without its target); nothing retained.
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: launch), [], "\(setup): nothing retained")
                    if setup == .fileIsALink {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere + "/real"), "the link's target is untouched")
                    }
                default:
                    // An unsafe directory is not acted in at all.
                    break
                }
            }
            chmod(temple, 0o700)
        }
    }

    /// What an executor killed midway left (`.run-*`, a file or a
    /// directory) goes with the launch's 24-hour sweep; a fresh one stays.
    func testTheSweepRemovesStaleTakes() throws {
        let host = StandIn()
        host.installStub()
        try host.makeRecordDirectory()
        let staleFile = host.recordDirectory + "/.run-r-a.s-cx-41", staleDirectory = host.recordDirectory + "/.run-r-b.s-cx-42"
        let fresh = host.recordDirectory + "/.run-r-c.s-cx-43"
        FileManager.default.createFile(atPath: staleFile, contents: Data("x".utf8))
        try FileManager.default.createDirectory(atPath: staleDirectory + "/inner", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fresh, contents: Data("x".utf8))
        let old = Date().addingTimeInterval(-90_000)
        for path in [staleFile, staleDirectory, staleDirectory + "/inner"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }

    /// Two Temple operations creating the record directory at once: the one
    /// whose mkdir loses (EEXIST) accepts what the other made, after the
    /// same checks; what the other made wrongly is still refused.
    func testAConcurrentColdMkdirIsAcceptedAfterTheSameChecks() async throws {
        for winnerMode in ["700", "755"] {
            let host = StandIn()
            // A mkdir that loses the race: the directory appears (as the
            // winner made it), and this one fails as EEXIST would.
            host.tree.write("bin/mkdir", "#!/bin/sh\nfor a in \"$@\"; do d=$a; done\n/bin/mkdir -m \(winnerMode) \"$d\"\n"
                            + "echo \"mkdir: $d: File exists\" >&2\nexit 1\n", executable: true)
            let outcome = await LaunchStage.write(stage: "r-abc.s-ccold", script: "true\n", using: host.exec)
            if winnerMode == "700" {
                XCTAssertEqual(outcome, .staged)
            } else {
                guard case .refused = outcome else { return XCTFail("a directory made 0755 is still refused: \(outcome)") }
            }
        }
        // And for real: several cold stagings at once, all in place.
        let host = StandIn()
        let names = (0..<8).map { "r-abc.s-cpar\($0)" }
        let outcomes = await withTaskGroup(of: LaunchStage.WriteResult.self) { group in
            for name in names { group.addTask { await LaunchStage.write(stage: name, script: "true\n", using: host.exec) } }
            var all: [LaunchStage.WriteResult] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(outcomes, Array(repeating: .staged, count: names.count))
    }

    /// Every interactive command Temple builds stays far below the sizes
    /// where macOS's ssh can't hand a session to its master (design note
    /// 21): a payload inlined into one again fails here.
    func testInteractiveCommandsStayShort() {
        let longest = LaunchStage.attachName(marker: "r-" + String(repeating: "f", count: 16),
                                             nonce: String(repeating: "f", count: 16))
        XCTAssertLessThanOrEqual(LaunchStage.command(stage: longest).utf8.count, LaunchStage.maximumCommandBytes)
        XCTAssertLessThanOrEqual(LaunchStage.maximumCommandBytes, 1024, "about 7 KiB left for the forwarded environment")
    }

    // MARK: The wrapper (stub tmux)

    func testCreationIsOneClientInvocationConfiguringThenCreating() throws {
        let host = StandIn()
        host.installStub()
        let keepAlive = TmuxKeepAlive()
        try host.runLaunch(host.staged(keepAlive.createScript(plan(host))))
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
                       ["new-session", "-s", "temple-h1", "-c", "/", "-e", "PATH=\(host.path)",
                        "-e", "TEMPLE_RECORD=\(host.recordDirectory)/m1"])
        XCTAssertFalse(argv.contains("-A"), "a duplicate is a loud failure, never an attach")
        XCTAssertTrue(argv.last?.hasPrefix("exec 'sh' '-c' ") == true, "\(argv.last ?? "")")
    }

    func testAttachUsesThePinnedSocketRunsNoPaneAndWritesNoRecord() throws {
        let host = StandIn()
        host.installStub()
        let keepAlive = TmuxKeepAlive()
        try host.runLaunch(host.staged(keepAlive.attachScript(plan(host, socket: "/tmp/tmux-1000/temple"))))
        try host.runLaunch(host.staged(keepAlive.attachScript(plan(host, socket: nil))))
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
        let result = try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host, argv: ["/bin/sh", "-c", "exit 0"]))))
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
        try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host, path: .unresolved))))
        let argv = try XCTUnwrap(host.calls.first)
        XCTAssertTrue(argv.contains("PATH=\(host.bin):/login/only/bin:/usr/bin:/bin"), "\(argv)")
    }

    /// One budget for the whole resolution, enforced on the resolver's
    /// process group: a login shell that hangs is abandoned in about six
    /// seconds, and the launch falls back. (GNU `timeout`, which would move
    /// the shell into a group of its own, is not used; the Linux acceptance
    /// repeats this on both boxes.)
    func testAHangingLoginShellIsAbandonedWithinTheBudgetAndLeavesNothing() async throws {
        let host = StandIn()
        let mark = "61.\(Int.random(in: 1000...9999))"
        // A shell that ignores TERM and leaves a child of its own.
        host.tree.write("bin/hangshell", "#!/bin/sh\ntrap '' TERM\nsleep \(mark) &\nsleep \(mark)\n", executable: true)
        host.extra = ["SHELL": host.bin + "/hangshell"]
        let started = Date()
        let resolved = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNil(resolved.path)
        XCTAssertLessThan(elapsed, 8.5, "bounded by the budget, not by the outer deadline alone")
        XCTAssertFalse(RemoteEnvironment.loginScript.contains("timeout"), "the group watchdog is the only bound")
        try await Task.sleep(for: .milliseconds(300))
        let left = try host.tmuxFreeRun("/usr/bin/pgrep", ["-f", "sleep \(mark)"])
        XCTAssertEqual(left.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "no login shell or descendant left")
    }

    /// One login query gives PATH and Claude's config root, framed so a
    /// newline or a relative value survives whole.
    func testTheLoginEnvironmentKeepsTheConfigRootExactly() async throws {
        let host = StandIn()
        host.tree.write("bin/cfgshell", "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\nPATH=/login/bin:/usr/bin:/bin; export PATH\n"
                        + "CLAUDE_CONFIG_DIR='rel dir\nwith newline'; export CLAUDE_CONFIG_DIR\neval \"$1\"\n", executable: true)
        host.extra = ["SHELL": host.bin + "/cfgshell"]
        let resolved = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        XCTAssertEqual(resolved.path, "/login/bin:/usr/bin:/bin")
        XCTAssertEqual(resolved.claudeConfig, .set("rel dir\nwith newline"))
        host.tree.write("bin/plainshell", "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\nunset CLAUDE_CONFIG_DIR\neval \"$1\"\n",
                        executable: true)
        host.extra = ["SHELL": host.bin + "/plainshell"]
        let plain = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        XCTAssertEqual(plain.claudeConfig, .unset)
    }

    /// The pane applies the launch's config root (so an older tmux server's
    /// value can't win) and records the root the agent has; told nothing,
    /// it refuses to start the agent, visibly, and records why.
    func testThePaneAppliesAndRecordsTheConfigRoot() throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
        let seen = host.tree.path + "/seen"
        var environment = host.environment
        environment["CLAUDE_CONFIG_DIR"] = "/stale/server/value"
        XCTAssertEqual(try runPane(host, directory: host.home,
                                   argv: ["/bin/sh", "-c", "printf '%s' \"$CLAUDE_CONFIG_DIR\" > \"$0\"", seen],
                                   record: record, environment: environment, config: ("set", "/cfg/with\nnewline")), 0)
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), "/cfg/with\nnewline")
        guard case .ok(let evidence) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(evidence.claudeConfig, .set("/cfg/with\nnewline"))
        // Unset: the stale value is removed, and recorded as unset.
        XCTAssertEqual(try runPane(host, directory: host.home,
                                   argv: ["/bin/sh", "-c", "printf '%s' \"${CLAUDE_CONFIG_DIR-none}\" > \"$0\"", seen],
                                   record: record, environment: environment, config: ("unset", "")), 0)
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), "none")
        guard case .ok(let unset) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(unset.claudeConfig, .unset)
        // Told nothing (or nonsense): no agent, a record that says why, and
        // never the server's stale value.
        for config in [nil, ("maybe", "/x")] as [(state: String, value: String)?] {
            try? FileManager.default.removeItem(atPath: seen)
            XCTAssertNotEqual(try runPane(host, directory: host.home, argv: ["/bin/sh", "-c", "echo ran > \"$0\"", seen],
                                          record: record, environment: environment, config: config), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: seen), "no agent ran")
            XCTAssertEqual(LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)),
                           .failedLaunch(PaneRecord.configRefusal))
        }
    }

    /// Codex's home the same way: applied over a stale server value,
    /// recorded as the agent has it, and a launch that says nothing starts
    /// no agent and records why.
    func testThePaneAppliesAndRecordsTheCodexHome() throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
        let seen = host.tree.path + "/seen"
        var environment = host.environment
        environment["CODEX_HOME"] = "/stale/server/value"
        XCTAssertEqual(try runPane(host, directory: host.home,
                                   argv: ["/bin/sh", "-c", "printf '%s' \"$CODEX_HOME\" > \"$0\"", seen],
                                   record: record, environment: environment, codexHome: ("set", "rel home")), 0)
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), "rel home")
        guard case .ok(let evidence) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(evidence.codexHome, .set("rel home"))
        XCTAssertEqual(try runPane(host, directory: host.home,
                                   argv: ["/bin/sh", "-c", "printf '%s' \"${CODEX_HOME-none}\" > \"$0\"", seen],
                                   record: record, environment: environment), 0)
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), "none")
        guard case .ok(let unset) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(unset.codexHome, .unset)
        for home in [nil, ("maybe", "/x")] as [(state: String, value: String)?] {
            try? FileManager.default.removeItem(atPath: seen)
            XCTAssertNotEqual(try runPane(host, directory: host.home, argv: ["/bin/sh", "-c", "echo ran > \"$0\"", seen],
                                          record: record, environment: environment, codexHome: home), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: seen), "no agent ran")
            XCTAssertEqual(LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)),
                           .failedLaunch(PaneRecord.codexHomeRefusal))
        }
    }

    /// The login query gives Codex's home beside Claude's root, set (even
    /// to the empty string) or unset; the launch resolver reads it the same
    /// way, and hands it to the pane explicitly.
    func testTheLoginEnvironmentKeepsTheCodexHomeExactly() async throws {
        let host = StandIn()
        host.tree.write("bin/cdxshell", "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\nPATH=/login/bin:/usr/bin:/bin; export PATH\n"
                        + "unset CLAUDE_CONFIG_DIR; CODEX_HOME='/codex\nhome'; export CODEX_HOME\neval \"$1\"\n", executable: true)
        host.extra = ["SHELL": host.bin + "/cdxshell"]
        let resolved = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        XCTAssertEqual(resolved.path, "/login/bin:/usr/bin:/bin")
        XCTAssertEqual(resolved.claudeConfig, .unset)
        XCTAssertEqual(resolved.codexHome, .set("/codex\nhome"))
        host.tree.write("bin/emptyshell", "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\n"
                        + "CLAUDE_CONFIG_DIR=; export CLAUDE_CONFIG_DIR; CODEX_HOME=; export CODEX_HOME\neval \"$1\"\n", executable: true)
        host.extra = ["SHELL": host.bin + "/emptyshell"]
        let empty = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        XCTAssertEqual(empty.claudeConfig, .set(""))
        XCTAssertEqual(empty.codexHome, .set(""))
        host.tree.write("bin/plainshell", "#!/bin/sh\nwhile [ $# -gt 1 ]; do shift; done\nunset CODEX_HOME CLAUDE_CONFIG_DIR\neval \"$1\"\n",
                        executable: true)
        host.extra = ["SHELL": host.bin + "/plainshell"]
        let plain = await RemoteEnvironment.resolve(using: LocalShellExec(path: nil, environment: host.environment))
        XCTAssertEqual(plain.codexHome, .unset)
        // The launch's own resolver (unresolved PATH) sets the same values.
        let probe = host.tree.write("probe.sh", RemoteEnvironment.resolverFunction + "\n"
            + #"e=$(temple_bounded m1) && temple_parse_env "$e" m1 && printf '%s|%s|%s|%s' "$TEMPLE_ENV_CFG" "$TEMPLE_ENV_CFG_VALUE" "$TEMPLE_ENV_CDX" "$TEMPLE_ENV_CDX_VALUE""#)
        for (shell, expected) in [("cdxshell", "unset||set|/codex\nhome"), ("emptyshell", "set||set|"), ("plainshell", "unset||unset|")] {
            host.extra = ["SHELL": host.bin + "/" + shell]
            let out = try await LocalShellExec(path: nil, environment: host.environment)
                .run(script: "sh \"$1\"", args: [probe.path], deadline: 10)
            XCTAssertEqual(out.stdout, expected, shell)
        }
    }

    /// The pane's recorded root is decoded strictly: malformed hex, odd
    /// digits, signs, extra fields or invalid UTF-8 are no evidence (nil);
    /// a valid encoded empty value is `.set("")`.
    func testRecordedConfigIsDecodedStrictly() {
        func config(_ line: String) -> RemoteEnvironment.ClaudeConfig?? {
            guard case .ok(let evidence) = LaunchRecords.parsePane(
                "ok\nepoch\t1\npane\t2\t3\nserver\t4\t5\nsocket\t/s\n\(line)\ndir\t/d\n") else { return .none }
            return .some(evidence.claudeConfig)
        }
        XCTAssertEqual(config("cfg\tunset"), .some(.unset))
        XCTAssertEqual(config("cfg\tset\t2f78"), .some(.set("/x")))
        XCTAssertEqual(config("cfg\tset\t2F78"), .some(.set("/x")))
        XCTAssertEqual(config("cfg\tset\t"), .some(.set("")), "a valid, encoded empty value")
        for malformed in ["cfg\tset", "cfg\tset\t2f7", "cfg\tset\t+f", "cfg\tset\tzz", "cfg\tset\t2f\textra",
                          "cfg\tset\tff", "cfg\tset\tc328", "cfg\tmaybe", "cfg\tunset\tx", "cfg"] {
            XCTAssertEqual(config(malformed), .some(nil), malformed)
        }
    }

    func testStaleRecordsAreSweptByTheNextLaunch() throws {
        let host = StandIn()
        host.installStub()
        try host.makeRecordDirectory()
        let old = host.recordDirectory + "/old", fresh = host.recordDirectory + "/fresh"
        FileManager.default.createFile(atPath: old, contents: Data("ok\n".utf8))
        FileManager.default.createFile(atPath: fresh, contents: Data("ok\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old)
        try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
    }

    func testTheRecordDirectoryIsPrivate() throws {
        let host = StandIn()
        host.installStub()
        try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host))))
        var info = stat()
        XCTAssertEqual(stat(host.recordDirectory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testARecordDirectoryThatIsALinkOrNotPrivateIsNeverUsed() async throws {
        for setup in ["link", "mode"] {
            let host = StandIn()
            host.installStub()
            let elsewhere = host.tree.directory("elsewhere")
            try FileManager.default.createDirectory(atPath: host.home + "/.temple", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if setup == "link" {
                try FileManager.default.createSymbolicLink(atPath: host.recordDirectory, withDestinationPath: elsewhere.path)
            } else {
                try FileManager.default.createDirectory(atPath: host.recordDirectory, withIntermediateDirectories: true)
                chmod(host.recordDirectory, 0o755)
            }
            // The launch script's own check, run directly (the executor
            // refuses such a directory before any script runs; tested apart).
            try host.runLaunch(RemoteQuoting.command(["sh", "-c", TmuxKeepAlive().createScript(plan(host)), "temple-launch"]))
            let argv = try XCTUnwrap(host.calls.first)
            XCTAssertTrue(argv.contains("TEMPLE_RECORD="), "\(setup): no record path is handed to the pane")
            do {
                _ = try await LaunchRecords.fetch(marker: "m1", using: host.exec)
                XCTFail("\(setup): a fetch refuses the directory")
            } catch LaunchRecords.FetchError.unsafeDirectory {}
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [], setup)
        }
    }

    // MARK: The pane

    /// `config`: the `-e TEMPLE_CFG` / `TEMPLE_CFG_VALUE` the launch hands
    /// the pane; nil hands it none.
    private func runPane(_ host: StandIn, directory: String, argv: [String], record: String,
                         tmux: String = "/tmp/tmux-1000/te,mp le,77,3", environment base: [String: String]? = nil,
                         config: (state: String, value: String)? = ("unset", ""),
                         codexHome: (state: String, value: String)? = ("unset", "")) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // As tmux would run it: the server's /bin/sh -c '<pane command>'.
        process.arguments = ["-c", TmuxKeepAlive.paneCommand(directory: directory, agentArgv: argv)]
        var environment = base ?? host.environment
        environment["TEMPLE_RECORD"] = record
        if let config {
            environment["TEMPLE_CFG"] = config.state
            environment["TEMPLE_CFG_VALUE"] = config.value
        }
        if let codexHome {
            environment["TEMPLE_CDX"] = codexHome.state
            environment["TEMPLE_CDX_VALUE"] = codexHome.value
        }
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
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
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
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
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

    func testAFolderWhoseNameEndsInANewlineKeepsIt() async throws {
        let host = StandIn()
        let odd = host.tree.directory("home/ends-in-newline\n")
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
        XCTAssertEqual(try runPane(host, directory: odd.path, argv: ["/usr/bin/true"], record: record), 0)
        guard case .ok(let evidence) = LaunchRecords.parsePane(try String(contentsOfFile: record, encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(evidence.directory, canonical(odd.path))
        XCTAssertTrue(evidence.directory.hasSuffix("\n"))
        let checked = await FolderCheck.run(odd.path, using: host.exec)
        XCTAssertEqual(checked, .exists(resolved: canonical(odd.path)))
    }

    func testThePaneThatCannotEnterItsFolderRecordsFailedAndRunsNothing() throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        let record = host.recordDirectory + "/rec"
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
        try host.runLaunch(host.staged(TmuxKeepAlive().createScript(plan(host, directory: folder.path, argv: args))))
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "a'b|c\\d|$HOME|e f|")
        guard case .ok(let evidence)? = host.record("m1").map(LaunchRecords.parsePane) else { return XCTFail() }
        XCTAssertEqual(evidence.directory, canonical(folder.path))
    }

    // MARK: Records over the exec seam

    func testFetchRecoversByNameThenAcknowledgeDeletes() async throws {
        let host = StandIn()
        try host.makeRecordDirectory()
        let dir = "/srv/a folder\twith a tab"
        let ok = "ok\nepoch\t1700000000\npane\t4321\t998877\nserver\t4000\t12\nsocket\t/tmp/tmux-1000/temple\ndir\t\(dir)\n"
        try ok.write(toFile: host.recordDirectory + "/mk", atomically: true, encoding: .utf8)
        // The creating client's stderr, left by a client hung up while attached.
        try "".write(toFile: host.recordDirectory + "/mk.err", atomically: true, encoding: .utf8)
        let fetched = try await LaunchRecords.fetch(marker: "mk", using: host.exec)
        XCTAssertEqual(fetched.pane, .ok(LaunchEvidence(epoch: 1_700_000_000, directory: dir, panePID: 4321, paneStart: "998877",
                                                        socketPath: "/tmp/tmux-1000/temple", serverPID: 4000, serverStart: "12")))
        XCTAssertNil(fetched.client)
        await LaunchRecords.acknowledge(marker: "mk", using: host.exec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/mk"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.recordDirectory + "/mk.err"))
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
        XCTAssertEqual(Liveness.classify(out(0, ""), session: "temple-h1"), .present)
        XCTAssertEqual(Liveness.classify(out(1, "can't find session: temple-h1\n"), session: "temple-h1"), .absent)
        XCTAssertEqual(Liveness.classify(out(1, "no server running on /tmp/tmux-1000/temple\n"), session: "temple-h1"),
                       .unknown(reason: "no server running on /tmp/tmux-1000/temple", socketMissing: true))
        // tmux 3.2a's socket-missing words.
        XCTAssertEqual(Liveness.classify(out(1, "error connecting to /tmp/tmux-1000/temple (No such file or directory)\n"), session: "temple-h1"),
                       .unknown(reason: "error connecting to /tmp/tmux-1000/temple (No such file or directory)", socketMissing: true))
        XCTAssertEqual(Liveness.classify(out(1, "error connecting to /tmp/x (Permission denied)\n"), session: "temple-h1"),
                       .unknown(reason: "error connecting to /tmp/x (Permission denied)", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(1, "protocol version mismatch (client 8, server 7)\n"), session: "temple-h1"),
                       .unknown(reason: "protocol version mismatch (client 8, server 7)", socketMissing: false))
        // Only tmux's exact words for this session prove absence.
        XCTAssertEqual(Liveness.classify(out(1, "error connecting to /tmp/can't find session: temple-h1 (No such file or directory)\n"),
                                         session: "temple-h1"),
                       .unknown(reason: "error connecting to /tmp/can't find session: temple-h1 (No such file or directory)",
                                socketMissing: true))
        XCTAssertEqual(Liveness.classify(out(1, "can't find session: temple-h10\n"), session: "temple-h1"),
                       .unknown(reason: "can't find session: temple-h10", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(127, ""), session: "temple-h1"), .unknown(reason: "tmux is not on PATH", socketMissing: false))
        XCTAssertEqual(Liveness.classify(out(255, "ssh: connect to host x port 22: Connection refused", reached: false), session: "temple-h1"),
                       .unknown(reason: "ssh: connect to host x port 22: Connection refused", socketMissing: false))
    }

    func testOneDecodedStopOutcome() {
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 1, stdout: "", stderr: "can't find session: temple-h10"),
                                          session: "temple-h1"),
                       .unconfirmed(reason: "can't find session: temple-h10", reachedHost: true))
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 0, stdout: "", stderr: ""), session: "temple-h1"), .killed)
        // The false branch exits 0 too: the marker decides, never the status.
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 0, stdout: "temple-not-killed\n", stderr: ""), session: "temple-h1"), .refused)
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 1, stdout: "", stderr: "can't find session: temple-h1"), session: "temple-h1"), .absent)
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 1, stdout: "", stderr: "no server running on /tmp/s"), session: "temple-h1"),
                       .unconfirmed(reason: "no server running on /tmp/s", reachedHost: true))
        XCTAssertEqual(StopOutcome.decode(RemoteOutput(status: 255, stdout: "", stderr: "Connection timed out", reachedCommand: false), session: "temple-h1"),
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
        let a = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "ha", marker: "ma"))))
        XCTAssertTrue(try waitFor { host.record("ma") != nil })
        guard case .ok(let evidence)? = host.record("ma").map(LaunchRecords.parsePane) else { return XCTFail() }
        XCTAssertEqual(evidence.socketPath, host.tmuxDir + "/tmux-\(getuid())/temple")
        XCTAssertEqual(try attachedCount(host, "temple-ha"), 1)
        // The chain's configuration took.
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "status"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "off")
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "prefix"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "None")

        // A second launch against the running server, in the same folder.
        let b = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "hb", marker: "mb"))))
        XCTAssertTrue(try waitFor { host.record("mb") != nil })

        // An attach, on the pinned socket, writes no record.
        let pinned = evidence.socketPath
        let records = try FileManager.default.contentsOfDirectory(atPath: host.recordDirectory).sorted()
        let second = try launchClient(host, host.staged(keepAlive.attachScript(plan(host, handle: "ha", marker: "mz", socket: pinned))))
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-ha") == 2 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: host.recordDirectory).sorted(), records)

        let exec = host.exec
        let present = await keepAlive.liveness(session: "temple-ha", socket: pinned, using: exec)
        XCTAssertEqual(present, .present)

        // Temple's own client goes first; another is still attached: refused.
        a.end()
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-ha") == 1 })
        let refused = try await keepAlive.stop(session: "temple-ha", socket: pinned, waitTenths: 5, using: exec)
        XCTAssertEqual(refused, .refused)
        XCTAssertEqual(try attachedCount(host, "temple-ha"), 1, "nothing killed")

        // No one attached: killed, and the acknowledgement is the evidence.
        second.end()
        let killed = try await keepAlive.stop(session: "temple-ha", socket: pinned, waitTenths: 30, using: exec)
        XCTAssertEqual(killed, .killed)
        let absent = await keepAlive.liveness(session: "temple-ha", socket: pinned, using: exec)
        XCTAssertEqual(absent, .absent, "the server lives on for hb and answers")

        // A probe answers for one tracked session, with its attached count.
        let probed = await keepAlive.probe(session: "temple-hb", socket: pinned, using: exec)
        XCTAssertEqual(probed, .present(attached: 1))
        let gone = await keepAlive.probe(session: "temple-ha", socket: pinned, using: exec)
        XCTAssertEqual(gone, .absent)

        // The last session: stopped, the server exits, and a later check
        // reads "no server running", which is unknown in v1.
        b.end()
        let last = try await keepAlive.stop(session: "temple-hb", socket: pinned, waitTenths: 30, using: exec)
        XCTAssertEqual(last, .killed)
        let after = await keepAlive.liveness(session: "temple-hb", socket: pinned, using: exec)
        guard case .unknown(_, true) = after else { return XCTFail("\(after)") }
        guard case .unknown(_, true) = await keepAlive.probe(session: "temple-hb", socket: pinned, using: exec) else {
            return XCTFail("a missing server is unknown, never absent")
        }

        // A socket Temple may not reach is unknown, never absent.
        let locked = host.tree.directory("locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o700) }
        let denied = await keepAlive.liveness(session: "temple-hb", socket: locked.path + "/sock", using: exec)
        guard case .unknown(_, false) = denied else { return XCTFail("\(denied)") }
    }

    func testRealTmuxStopOfAGoneSessionIsAbsentNeverRefused() async throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        _ = try host.tmux(["-L", "temple", "-f", "/dev/null", "new-session", "-d", "-s", "temple-keep", "sleep 30"])
        // `if-shell -t =name:` on a missing session would print the refusal
        // with status 0; has-session in the same queue answers first.
        let pinned = host.tmuxDir + "/tmux-\(getuid())/temple"
        let outcome = try await keepAlive.stop(session: "temple-gone", socket: pinned, waitTenths: 0, using: host.exec)
        XCTAssertEqual(outcome, .absent)
        let probe = await keepAlive.probe(session: "temple-gone", socket: pinned, using: host.exec)
        XCTAssertEqual(probe, .absent)
        // Without a pinned socket, the same words prove nothing.
        guard case .unconfirmed = try await keepAlive.stop(session: "temple-gone", socket: nil, waitTenths: 0, using: host.exec),
              case .unknown = await keepAlive.probe(session: "temple-gone", socket: nil, using: host.exec),
              case .unknown = await keepAlive.liveness(session: "temple-gone", socket: nil, using: host.exec) else {
            return XCTFail("unpinned absence must stay unknown")
        }
    }

    /// A home whose path tmux would read as a format, and a quote: `-c /`
    /// keeps it out of tmux, and the pane's diagnostics land exactly there,
    /// with the agent still the pane's own process.
    func testRealTmuxDiagnosticsAndAnOddHome() async throws {
        let host = StandIn()
        try host.installRealTmux()
        let oddHome = host.tree.directory("h#{session_name}'q #(touch pwned)").path
        host.extra = ["HOME": oddHome]
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let client = try PTYClient(host.staged(keepAlive.createScript(plan(host, directory: "~",
            argv: ["/bin/sh", "-c", "echo \"agent $$\"; echo 'No conversation found with session ID: x' >&2; sleep 1; exit 3"]))),
                                   environment: host.environment)
        defer { client.end() }
        let records = oddHome + "/.temple/launch"
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: records + "/m1") })
        XCTAssertTrue(try waitFor { ((try? String(contentsOfFile: records + "/m1.out", encoding: .utf8)) ?? "").contains("No conversation") })
        guard case .ok(let evidence) = LaunchRecords.parsePane(try String(contentsOfFile: records + "/m1", encoding: .utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(evidence.directory, canonical(oddHome))
        let output = try String(contentsOfFile: records + "/m1.out", encoding: .utf8)
        XCTAssertTrue(output.contains("agent \(evidence.panePID)"), "the agent is the pane's process: \(output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.tree.path + "/pwned"))
        // Private, whatever the server's umask: only this account reads
        // what the agent showed.
        let mode = try FileManager.default.attributesOfItem(atPath: records + "/m1.out")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the pane's output is created 0600")
        let fetched = try await LaunchRecords.fetch(marker: "m1", using: host.exec)
        XCTAssertTrue(fetched.output?.contains("No conversation found") == true)
        // The run's end is proven: its output goes with its staged launches,
        // and what it held is handed back once.
        let taken = await LaunchStage.discardAll(marker: "m1", using: host.exec)
        XCTAssertTrue(taken?.contains("No conversation found") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: records + "/m1.out"))
    }

    func testRealTmuxStopRefusesWhenTemplesClientWasReplacedBeforeItRan() async throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let ours = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "hr", marker: "mr"))))
        XCTAssertTrue(try waitFor { host.record("mr") != nil })
        // Temple detaches its own client, and before the stop runs, someone
        // else attaches: the count is 1 again, but it is not Temple's.
        ours.end()
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-hr") == 0 })
        let other = try launchClient(host, "tmux -L temple attach-session -t =temple-hr")
        defer { other.end() }
        XCTAssertTrue(try waitFor { try self.attachedCount(host, "temple-hr") == 1 })
        let outcome = try await keepAlive.stop(session: "temple-hr", socket: nil, waitTenths: 5, using: host.exec)
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
        let first = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "h1", marker: "m1",
                                                                        argv: ["/bin/sh", "-c", "exit 0"]))))
        XCTAssertTrue(try waitFor { !first.process.isRunning })
        // The next launch configures a fresh server in the same queue.
        let second = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "h2", marker: "m2",
            argv: ["/bin/sh", "-c", "printf '%s\\n' \"$PATH\" > \(out)/p2; printf '%s\\n' \"$TERM\" > \(out)/t2; sleep 30"],
            path: .resolved("\(host.bin):/first/path:/usr/bin:/bin")))))
        defer { second.end() }
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/t2") })
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "status"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "off")
        // A server started with one PATH: -e hands the next pane its own.
        let third = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "h3", marker: "m3",
            argv: ["/bin/sh", "-c", "printf '%s\\n' \"$PATH\" > \(out)/p3; sleep 30"],
            path: .resolved("\(host.bin):/third/path:/usr/bin:/bin")))))
        defer { third.end() }
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/p3") })
        XCTAssertEqual(try String(contentsOfFile: out + "/p2", encoding: .utf8), "\(host.bin):/first/path:/usr/bin:/bin\n")
        XCTAssertEqual(try String(contentsOfFile: out + "/p3", encoding: .utf8), "\(host.bin):/third/path:/usr/bin:/bin\n")
        // The attached client is xterm-256color outside, tmux-256color in the pane.
        XCTAssertEqual(try String(contentsOfFile: out + "/t2", encoding: .utf8), "tmux-256color\n")
        let clients = try host.tmux(["-L", "temple", "list-clients", "-t", "=temple-h2", "-F", "#{client_termname}"])
        XCTAssertEqual(clients.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "xterm-256color")
    }

    /// The tab's title is the agent's (B1): tmux titles a fresh pane with
    /// the host's name, and the title Temple's chain hands the outer
    /// terminal is empty until the agent sets its own (then exactly that).
    func testRealTmuxTitleIsTheAgentsAndNeverTheHostName() throws {
        let host = StandIn()
        try host.installRealTmux()
        let keepAlive = TmuxKeepAlive()
        defer { _ = try? host.tmux(["-L", "temple", "kill-server"]) }
        let out = host.tree.path
        let client = try launchClient(host, host.staged(keepAlive.createScript(plan(host, handle: "ht", marker: "mt",
            argv: ["/bin/sh", "-c", "touch \(out)/ready; while [ ! -e \(out)/go ]; do sleep 0.05; done; "
                   + "printf '\\033]2;Agent, title\\033\\\\'; touch \(out)/set; sleep 30"]))))
        defer { client.end() }
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/ready") })
        func outer() throws -> String {
            try host.tmux(["-L", "temple", "display-message", "-p", "-t", "=temple-ht:", "#{T:set-titles-string}"])
                .stdout.trimmingCharacters(in: .newlines)
        }
        let paneTitle = try host.tmux(["-L", "temple", "display-message", "-p", "-t", "=temple-ht:", "#{pane_title}"])
            .stdout.trimmingCharacters(in: .newlines)
        let hostName = try host.tmux(["-L", "temple", "display-message", "-p", "#{host}"]).stdout.trimmingCharacters(in: .newlines)
        XCTAssertEqual(paneTitle, hostName, "tmux's own default: the host's name")
        XCTAssertEqual(try outer(), "", "nothing until the agent says")
        XCTAssertEqual(try host.tmux(["-L", "temple", "show", "-gv", "set-titles"]).stdout.trimmingCharacters(in: .newlines), "on")
        FileManager.default.createFile(atPath: out + "/go", contents: nil)
        XCTAssertTrue(try waitFor { FileManager.default.fileExists(atPath: out + "/set") })
        XCTAssertTrue(try waitFor { try outer() == "Agent, title" })
    }

}
