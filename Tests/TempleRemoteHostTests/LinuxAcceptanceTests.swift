import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Linux acceptance of the exec layer and the Test connection's checks,
/// against real hosts. Opt-in, so the normal suite never touches the
/// network:
///
///     TEMPLE_REMOTE_ACCEPTANCE=masterblaster-mentes,jetson-mentes swift test --filter LinuxAcceptanceTests
///
/// Each name is an `~/.ssh/config` alias reachable without a prompt
/// (`BatchMode`). Read-only on the host except a throwaway tmux socket and
/// the check's record files, all removed: the environment, `claude
/// --version`, `codex --version`, `tmux -V`, the launch chain detached on a
/// throwaway socket, logind. The phase-0 check starts no agent session;
/// `testPhase1aClaudeLifecycleOnEachHost` (below) does, in a temp folder
/// it creates and removes, with the attached client under
/// `xterm-256color` and a `tmux-256color` pane. The connect creates a master on a
/// socket under a temp state directory, as the Test sheet does, and the
/// queries ride it; the test ends that master itself when done (Temple
/// never does).
final class LinuxAcceptanceTests: XCTestCase {
    private var hosts: [String] {
        (ProcessInfo.processInfo.environment["TEMPLE_REMOTE_ACCEPTANCE"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func testEveryCheckOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        let state = TempTree("acceptance-state")
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            try await check(name, stateDirectory: state.url)
        }
    }

    private func check(_ name: String, stateDirectory: URL) async throws {
        // As the Test sheet builds it: keyed by where ssh -G resolves it.
        let provisional = SSHConnection(record: .config(name), stateDirectory: stateDirectory, sshPath: "/usr/bin/ssh")
        guard case .resolved(let resolved) = await ConnectionTest.sshResolve(provisional.resolutionArgv) else {
            return XCTFail("\(name): ssh -G failed")
        }
        let connection = SSHConnection(record: .config(name), stateDirectory: stateDirectory, sshPath: "/usr/bin/ssh",
                                       resolved: resolved)
        var lines: [String] = ["== \(name)"]

        // The Test connection's evidence: no master before the connect,
        // one after it (the sheet's terminal runs these same arguments; `-T`
        // here only because there is no terminal; the keys need no answer).
        try connection.prepareSocketDirectory()
        let check = connection.masterCheckArgv
        let before = try await ProcessRunner.run(check[0], Array(check.dropFirst()), deadline: 5)
        XCTAssertNotEqual(before.status, 0, "\(name): no master yet")
        let connect = connection.argv(.interactive, remoteCommand: "true").map { $0 == "-t" ? "-T" : $0 }
        let connected = try await ProcessRunner.run(connect[0], Array(connect.dropFirst()) + [], deadline: 30)
        XCTAssertEqual(connected.status, 0, "\(name): \(connected.stderr)")
        let after = try await ProcessRunner.run(check[0], Array(check.dropFirst()), deadline: 5)
        XCTAssertEqual(after.status, 0, "\(name): the connect left a master")
        lines.append("Master after connect: \(after.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        defer {
            // Test cleanup only: Temple itself never ends a master. This one
            // is the test's own, on a socket in a directory it removes.
            let exit = [check[0], check[1], check[2]] + SSHConnection.helperOptions + ["-O", "exit", "--", name]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exit[0])
            process.arguments = Array(exit.dropFirst())
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }

        // Every check rides the master and nothing else, as in the sheet.
        let environment = await RemoteEnvironment.resolve(using: SSHExec(connection: connection, path: nil, purpose: .overMaster))
        XCTAssertTrue(environment.reachedHost, "\(name): the first query over the master reached the host")
        XCTAssertNil(environment.problem, name)
        let path = try XCTUnwrap(environment.path, name)
        lines.append("Login shell: \(environment.shell), PATH read.")
        lines.append("  PATH=\(path)")
        // ssh's default command environment, for comparison only.
        let defaultPath = try await SSHExec(connection: connection, path: nil)
            .run(script: "printf '%s\\n' \"$PATH\"", args: [], deadline: 10).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("  ssh default PATH=\(defaultPath)")

        let exec = SSHExec(connection: connection, path: path, purpose: .overMaster)
        let claude = await ToolCheck.run("claude", using: exec)
        let codex = await ToolCheck.run("codex", using: exec)
        for (binary, check) in [("claude", claude), ("codex", codex)] {
            lines.append(ConnectionTest.row(binary, check).line)
            guard case .runs(let found, _, _) = check else { XCTFail("\(name): \(binary) \(check)"); continue }
            XCTAssertTrue(found.hasSuffix("/.local/bin/\(binary)"), "\(name): \(found)")
        }

        let tmux = await TmuxCheck.run(nonce: RemoteQuoting.nonce(), using: exec)
        lines.append(ConnectionTest.row(tmux).line)
        guard case .accepted = tmux else { XCTFail("\(name): \(tmux)"); return }

        let logind = await LogindCheck.run(using: exec)
        lines.append(ConnectionTest.row(logind).line)

        // The identity the socket was keyed by.
        let identity = connection.resolved
        let summary = HostTestSummary(connectedAs: identity["user"].flatMap { user in identity["hostname"].map { "\(user)@\($0)" } },
                                      environment: environment, claude: claude, codex: codex, tmux: tmux, logind: logind)
        lines.append("Status: \(summary.statusLine)")

        // Nothing left behind: no throwaway socket.
        let leftovers = try await exec.run(script: """
            ls "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" 2>/dev/null | grep '^temple-check-' || true
            """, args: [], deadline: 10)
        XCTAssertEqual(leftovers.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "\(name) leftovers")
        print(lines.joined(separator: "\n"))
    }

    // MARK: Phase 1a

    /// The durable slice on each box (section 11): a real Claude session
    /// created in a temp folder Temple makes under /tmp there, through the
    /// tab's own launch (the user's ssh on a pty, `TERM=xterm-256color`
    /// outside, `tmux-256color` in the pane); a throwaway prompt; detach,
    /// reattach, the one-command stop decoded as killed, a resume with
    /// `claude --resume` that brings the conversation back, and the stop
    /// again. The socket-missing message is observed on a throwaway server.
    /// Everything it created is removed: its tmux sessions, its temp
    /// folder, its records and that folder's transcript directory. The
    /// user's own tmux, and any session it did not create, are never
    /// touched.
    @MainActor
    func testPhase1aClaudeLifecycleOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            try await lifecycle(name)
        }
    }

    @MainActor
    private func plan(_ outcome: RemoteSessions.OpenOutcome) throws -> RemoteSessions.OpenPlan {
        guard case .plan(let plan) = outcome else { throw XCTSkip("expected a plan, got \(outcome)") }
        return plan
    }

    @MainActor
    private func lifecycle(_ name: String) async throws {
        let state = TempTree("acceptance-1a")
        var log: [String] = ["== \(name) (phase 1a)"]
        defer { print(log.joined(separator: "\n")) }
        let record = RemoteHostRecord.config(name)
        let store = try RemoteStateStore(directory: state.url)
        let sessions = RemoteSessions(record: record, stateDirectory: state.url, sshPath: "/usr/bin/ssh", store: { store })
        let connection = try await sessions.resolvedConnection()
        // No master yet: the first launch is a first contact, whose own ssh
        // becomes the master (the queries before it connect on their own).
        let masterBefore = await sessions.hasLiveMaster()
        XCTAssertFalse(masterBefore, "\(name): a fresh socket directory")
        defer {
            let check = connection.masterCheckArgv
            let exit = [check[0], check[1], check[2]] + SSHConnection.helperOptions + ["-O", "exit", "--", name]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exit[0])
            process.arguments = Array(exit.dropFirst())
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        let exec = try await sessions.queryExec()
        func sh(_ script: String, _ args: [String] = []) async throws -> String {
            let out = try await exec.run(script: script, args: args, deadline: 20)
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        log.append("tmux: \(try await sh("tmux -V"))")
        // tmux passes `-e` values verbatim (no format expansion), which the
        // config root's handoff to the pane relies on.
        // (The pane writes what it got: `show-environment` escapes `$` in
        // its own output on 3.4, which says nothing about the value.)
        let verbatim = try await sh("""
        s=temple-accept-e-$1; o=$(mktemp /tmp/temple-accept-e.XXXXXX); v='a#{session_name}b$HOME
        c'"'"'d'
        tmux -L "$s" -f /dev/null new-session -d -s x -e "TV=$v" -e "TO=$o" 'printf %s "$TV" > "$TO"; sleep 30'
        i=0; while [ ! -s "$o" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
        got=$(cat "$o"; printf x); got=${got%x}
        tmux -L "$s" kill-server 2>/dev/null; rm -f "$o" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"
        [ "$got" = "$v" ] && echo verbatim || printf 'changed: %s' "$got"
        """, [RemoteQuoting.nonce()])
        log.append("tmux -e values: \(verbatim)")
        XCTAssertEqual(verbatim, "verbatim", "\(name)")
        let before = try await sh("tmux -L temple ls -F '#{session_name}' 2>/dev/null || true")
        let recordsBefore = try await sh("[ -e \"$HOME/.temple\" ] && echo yes || echo no")
        log.append("Temple server before: \(before.isEmpty ? "(none)" : before)")
        let folder = try await sh("mktemp -d /tmp/temple-accept-XXXXXX")
        XCTAssertTrue(folder.hasPrefix("/tmp/temple-accept-"), folder)
        let canonicalFolder = try await sh("cd -- \"$1\" && pwd -P", [folder])
        let sessionID = UUID().uuidString.lowercased()
        var commandSizes: [Int] = []
        var handles: [String] = []
        var markers: [String] = []
        var clients: [AcceptanceClient] = []
        defer {
            for client in clients { client.end() }
            let cleanup = """
            f=$1; shift
            for h in "$@"; do tmux -L temple kill-session -t "=temple-$h" 2>/dev/null; done
            case $f in /tmp/temple-accept-*) rm -rf -- "$f" ;; esac
            enc=$(printf '%s' "$f" | sed 's|[/.]|-|g')
            [ -n "$enc" ] && rm -rf -- "$HOME/.claude/projects/$enc"
            # The private server this test started has exited with its last
            # session; its socket file goes too, when nothing answers on it
            # and there was no server before.
            if [ "$TEMPLE_ACCEPT_NONE_BEFORE" = 1 ] && ! tmux -L temple ls >/dev/null 2>&1; then
              rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/temple"
            fi
            # Its records, and the record directory when this test made it.
            for mk in $TEMPLE_ACCEPT_MARKERS; do rm -f "$HOME/.temple/launch/$mk" "$HOME/.temple/launch/$mk".*; done
            if [ "$TEMPLE_ACCEPT_RECORDS_BEFORE" = no ]; then rmdir "$HOME/.temple/launch" "$HOME/.temple" 2>/dev/null; fi
            true
            """
            let semaphore = DispatchSemaphore(value: 0)
            let canonical = canonicalFolder
            let all = handles
            let noneBefore = before.isEmpty ? "1" : "0"
            let markers = markers.joined(separator: " ")
            let recordsWereThere = recordsBefore
            Task.detached {
                _ = try? await exec.run(script: "TEMPLE_ACCEPT_NONE_BEFORE=$1; TEMPLE_ACCEPT_MARKERS=$2; TEMPLE_ACCEPT_RECORDS_BEFORE=$3; shift 3\n"
                                            + cleanup,
                                        args: [noneBefore, markers, recordsWereThere, canonical] + all, deadline: 20)
                semaphore.signal()
            }
            semaphore.wait()
        }

        // Create: the tab's command on a local pty.
        let request = RemoteSessions.OpenRequest(agent: .claude, sessionID: sessionID, mode: .new, directory: folder)
        let first = try plan(await sessions.open(request))
        handles.append(first.handle)
        markers.append(RecordDirectory.marker(from: try XCTUnwrap(store.run(first.handle)).recordPath) ?? "")
        XCTAssertTrue(first.creating)
        XCTAssertEqual(Array(first.argv.prefix(2)), ["/usr/bin/env", "TERM=xterm-256color"])
        XCTAssertFalse(first.staged, "first contact: nothing staged before the tab's ssh connects")
        commandSizes.append(try XCTUnwrap(first.argv.last).utf8.count)
        clients.append(try AcceptanceClient(first.argv))
        let staged = await sessions.stage(first.stage)
        log.append("first contact: the tab's ssh became the master; staging over it: \(staged)")
        XCTAssertEqual(staged, .staged, "\(name)")
        var collected = RemoteSessions.Collected.nothing
        for _ in 0..<40 {
            collected = await sessions.collect(first.handle)
            if case .ok = collected { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        // A launch that stalls: the client's ssh child, its -v trace and pty,
        // and what the host has, for every launch below.
        func stalled() async -> String {
            let state = (try? await sh("""
            ls -la "$HOME/.temple/launch" 2>&1; tmux -L temple ls 2>&1; ps -ef | grep -E 'tmux|temple-launch|sshd: mentes' | grep -v grep
            """)) ?? "(host unreachable)"
            return "\(clients.last?.diagnosis ?? "")\nhost:\n\(state)"
        }
        guard case .ok(let directory) = collected else {
            return XCTFail("\(name): no ok record: \(collected)\n\(await stalled())")
        }
        XCTAssertEqual(directory, canonicalFolder)
        let run = try XCTUnwrap(store.run(first.handle))
        log.append("ok record: dir=\(directory) pane=\(run.panePID ?? -1) start=\(run.paneStart ?? "-") socket=\(run.socketPath ?? "-") server=\(run.serverPID ?? -1)/\(run.serverStart ?? "-")")
        // A config that sets `StdinNull yes` (a throwaway file passed with -F
        // that includes the usual config for the alias; nothing is edited):
        // Temple's own options keep the query's stdin, so its program and
        // input arrive over the master.
        let throwaway = state.write("stdin-null.conf", "Host *\n  StdinNull yes\n  ForkAfterAuthentication yes\n"
                                    + "Include ~/.ssh/config\n")
        let marker = "__temple_\(RemoteQuoting.nonce())__"
        let query = SSHExec.invocation(script: "printf 'program ran|'; cat", args: [], path: nil,
                                       input: Data("input arrived".utf8), marker: marker)
        var nullArgv = connection.argv(.overMaster, remoteCommand: query.command)
        nullArgv.insert(contentsOf: ["-F", throwaway.path], at: 1)
        let nulled = SSHExec.unframe(try await ProcessRunner.run(nullArgv[0], Array(nullArgv.dropFirst()), input: query.stdin,
                                                                 deadline: 20), marker: marker)
        log.append("query under StdinNull yes: status=\(nulled.status) stdout=\(nulled.stdout)")
        XCTAssertEqual(nulled.stdout, "program ran|input arrived", "\(name): \(nulled.stderr)")
        // The executor on this host's sh and find: a staged file that is not
        // exactly 0600 is refused and never run; a private one runs once.
        let executor = try await sh("""
        d=$HOME/.temple/launch; n=st-accept-$1; o=$d/ran-$1
        printf 'touch %s\\n' "$o" > "$d/$n"; chmod 644 "$d/$n"
        sh -c "$2" temple-launch "$n" 1 2>/dev/null; a=$?; [ -e "$o" ] && a="$a ran"
        rm -f "$d/$n" "$d/.run-$n"
        printf 'touch %s\\n' "$o" > "$d/$n"; chmod 600 "$d/$n"
        sh -c "$2" temple-launch "$n" 1 2>/dev/null; b=$?; [ -e "$o" ] && b="$b ran"; [ -e "$d/$n" ] && b="$b left"
        rm -f "$d/$n" "$d/.run-$n" "$o"
        echo "0644: $a; 0600: $b"
        """, [RemoteQuoting.nonce(), LaunchStage.runner])
        log.append("executor: \(executor)")
        XCTAssertEqual(executor, "0644: 125; 0600: 0 ran", "\(name)")
        let socket = try XCTUnwrap(run.socketPath)
        let session = "temple-\(first.handle)"
        func tmux(_ args: String) async throws -> String { try await sh("tmux -S \"$1\" \(args)", [socket]) }
        // The agent is the pane's process.
        let paneComm = try await sh("ps -o comm= -p \"$1\"", [String(run.panePID ?? 0)])
        log.append("pane process: \(paneComm)")
        XCTAssertTrue(paneComm.contains("claude"), "\(name): \(paneComm)")
        // What the pane shows is piped beside its record, private to the account.
        let outputMode = try await sh("stat -c '%a' \"$HOME/.temple/launch/$1.out\" 2>/dev/null || echo missing", [markers[0]])
        log.append("pane output file mode: \(outputMode)")
        XCTAssertEqual(outputMode, "600", "\(name)")
        let observed1 = try await tmux("display-message -p -t =\(session): '#{pane_pid}'")
        XCTAssertEqual(observed1, String(run.panePID ?? 0))
        // TERM: xterm-256color outside, tmux-256color in the pane, both known to the host.
        let clientTerm = try await tmux("list-clients -t =\(session) -F '#{client_termname}'")
        let paneTerm = try await sh("tr '\\0' '\\n' < /proc/$1/environ | grep '^TERM=' || true", [String(run.panePID ?? 0)])
        let colors = try await sh("printf '%s %s' \"$(tput -T xterm-256color colors)\" \"$(tput -T tmux-256color colors)\"")
        log.append("client TERM=\(clientTerm); pane \(paneTerm); tput colors xterm-256color/tmux-256color: \(colors)")
        XCTAssertEqual(clientTerm, "xterm-256color")
        XCTAssertEqual(paneTerm, "TERM=tmux-256color")
        XCTAssertEqual(colors, "256 256")
        let observed2 = try await tmux("show -gv status")
        XCTAssertEqual(observed2, "off")

        // A throwaway prompt, through the live TUI, once it is ready. A
        // folder Claude has not seen asks about trust first (its default is
        // "No, exit": choose Yes). A box whose claude is not logged in stops
        // at onboarding: Temple logs no one in, so the prompt and the
        // conversation check are skipped there and said so.
        var screen = ""
        var ready = false, loggedOut = false
        for _ in 0..<45 {
            try await Task.sleep(for: .seconds(1))
            screen = try await tmux("capture-pane -p -t =\(session):")
            if screen.contains("Yes, I trust this folder") {
                log.append("first screen asked about trust; chose \"Yes, I trust this folder\"")
                _ = try await tmux("send-keys -t =\(session): Down")
                try await Task.sleep(for: .milliseconds(300))
                _ = try await tmux("send-keys -t =\(session): Enter")
                continue
            }
            if screen.contains("Select login method") || screen.contains("Welcome to Claude Code") {
                loggedOut = true
                if screen.contains("Select login method") { break }
                continue
            }
            if screen.contains("Claude Code v"), screen.contains("❯") { ready = true; break }
        }
        var answered = false
        if loggedOut {
            log.append("claude on \(name) is not logged in (onboarding: \(screen.split(separator: "\n").first { $0.contains("Welcome") || $0.contains("login") }.map(String.init) ?? "?")); prompt and conversation check skipped")
        } else {
            XCTAssertTrue(ready, "\(name): the TUI never became ready; screen:\n\(screen)")
            _ = try await tmux("send-keys -t =\(session): -l 'reply with the word ok'")
            try await Task.sleep(for: .milliseconds(500))
            _ = try await tmux("send-keys -t =\(session): Enter")
            for _ in 0..<60 {
                let found = try await sh("""
                f=$(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" 2>/dev/null | head -n 1)
                [ -n "$f" ] && grep -c '"type":"assistant"' "$f" || echo 0
                """, [sessionID])
                if (Int(found) ?? 0) > 0 { answered = true; break }
                try await Task.sleep(for: .seconds(2))
            }
            screen = try await tmux("capture-pane -p -t =\(session):")
            XCTAssertTrue(answered, "\(name): no reply in the transcript; screen:\n\(screen)")
            guard answered else { return }
            log.append("prompt answered: \(answered)")
            // The transcript on the host is the evidence (typed input is not).
            let evidence = await sessions.conversation(sessionID: sessionID)
            XCTAssertEqual(evidence, .present)
            log.append("transcript on the host: \(evidence)")
        }
        let recordDirectory = try await sh("""
        d=$HOME/.temple/launch; [ -L "$d" ] && echo link; stat -c '%a %U' "$d" 2>/dev/null || stat -f '%Lp %Su' "$d"
        """)
        log.append("record directory ~/.temple/launch: \(recordDirectory)")

        // Detach: Temple's client goes; the agent keeps running.
        clients.removeLast().end()
        let afterDetach = await sessions.exitCheck(first.handle)
        XCTAssertEqual(afterDetach, .present)
        let observed3 = try await tmux("display-message -p -t =\(session): '#{session_attached}'")
        XCTAssertEqual(observed3, "0")
        log.append("detached: \(afterDetach)")

        // Reattach: an attach on the pinned socket, no record, no second agent.
        let second = try plan(await sessions.open(request))
        XCTAssertFalse(second.creating)
        XCTAssertEqual(second.evidenceDirectory, directory, "the persisted evidence is replayed on reopen")
        XCTAssertEqual(second.handle, first.handle)
        XCTAssertTrue(second.staged, "\(name): the master is up, so the launch is staged before the spawn")
        commandSizes.append(try XCTUnwrap(second.argv.last).utf8.count)
        clients.append(try AcceptanceClient(second.argv))
        var attached = "0"
        for _ in 0..<40 {
            attached = try await tmux("display-message -p -t =\(session): '#{session_attached}'")
            if attached == "1" { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(attached, "1")
        let observed4 = try await tmux("display-message -p -t =\(session): '#{pane_pid}'")
        XCTAssertEqual(observed4, String(run.panePID ?? 0))
        let records = try await sh("ls \"$HOME/.temple/launch\" 2>/dev/null | grep -c \"^$1\\$\" || true", [markers[0]])
        XCTAssertEqual(records, "0", "the attach wrote no record (and the creation's was acknowledged)")
        log.append("reattached: attached=\(attached), same pane")

        // Stop: Temple's client first, then the one-command stop.
        clients.removeLast().end()
        let stopped = try await sessions.stop(first.handle, fromAttachedTab: true).outcome
        XCTAssertEqual(stopped, .killed)
        XCTAssertEqual(try store.run(first.handle)?.endEvidence, .killed)
        let afterStop = await sessions.exitCheck(first.handle)
        log.append("stop: \(stopped); a check afterwards reads \(afterStop)")

        // Resume from the transcript, in a new run; a conversation Temple
        // never saw confirmed is not resumed blindly (the decision instead).
        var resumeRequest = RemoteSessions.OpenRequest(agent: .claude, sessionID: sessionID, mode: .resume, directory: directory)
        if loggedOut {
            let outcome = try await sessions.open(resumeRequest)
            XCTAssertEqual(outcome, .needsDecision(checked: true), "no transcript on the host for it")
            log.append("unconfirmed conversation, reopened: \(outcome); chose Start a new session")
            resumeRequest.startNew = true
        }
        let resumed = try plan(await sessions.open(resumeRequest))
        handles.append(resumed.handle)
        markers.append(RecordDirectory.marker(from: try XCTUnwrap(store.run(resumed.handle)).recordPath) ?? "")
        XCTAssertTrue(resumed.creating)
        XCTAssertEqual(resumed.agentArgv.suffix(2), [loggedOut ? "--session-id" : "--resume", sessionID])
        XCTAssertTrue(resumed.staged, "\(name): the master is up, so the launch is staged before the spawn")
        commandSizes.append(try XCTUnwrap(resumed.argv.last).utf8.count)
        clients.append(try AcceptanceClient(resumed.argv))
        collected = .nothing
        for _ in 0..<40 {
            collected = await sessions.collect(resumed.handle)
            if case .ok = collected { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard case .ok = collected else {
            return XCTFail("\(name): no ok record for the resume: \(collected)\n\(await stalled())")
        }
        let resumedSession = "temple-\(resumed.handle)"
        let resumedSocket = try XCTUnwrap(store.run(resumed.handle)?.socketPath)
        if loggedOut {
            // No transcript to resume: what can be shown is that the new run
            // asked for it, in a pane of its own.
            let args = try await sh("tr '\\0' ' ' < /proc/$1/cmdline 2>/dev/null || echo '(ended)'",
                                    [String(try XCTUnwrap(store.run(resumed.handle)?.panePID))])
            log.append("new session launched: \(args)")
            clients.removeLast().end()
            let liveness = await sessions.exitCheck(resumed.handle)
            if liveness == .present {
                let stoppedAgain = try await sessions.stop(resumed.handle, fromAttachedTab: true).outcome
                XCTAssertEqual(stoppedAgain, .killed)
                log.append("stop after the new session: \(stoppedAgain)")
            } else {
                log.append("the resumed claude ended on its own (nothing to resume): \(liveness)")
            }
        } else {
            var restored = false
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(1))
                let shown = try await sh("tmux -S \"$1\" capture-pane -p -S -200 -t \"=$2:\"", [resumedSocket, resumedSession])
                if shown.contains("reply with the word ok") { restored = true; break }
            }
            XCTAssertTrue(restored, "\(name): the resumed TUI shows the earlier prompt")
            log.append("resumed with --resume: conversation back=\(restored)")
            clients.removeLast().end()
            let stoppedAgain = try await sessions.stop(resumed.handle, fromAttachedTab: true).outcome
            XCTAssertEqual(stoppedAgain, .killed)
            log.append("stop after resume: \(stoppedAgain)")
        }

        // An agent that fails at once: its own words come back with its
        // record, and the session is gone (the diagnostics change nothing
        // about liveness).
        var failing = RemoteSessions.OpenRequest(agent: .claude, sessionID: UUID().uuidString.lowercased(), mode: .resume,
                                                 directory: directory)
        failing.resumeAnyway = true
        let doomed = try plan(await sessions.open(failing))
        handles.append(doomed.handle)
        markers.append(RecordDirectory.marker(from: try XCTUnwrap(store.run(doomed.handle)).recordPath) ?? "")
        XCTAssertTrue(doomed.staged, "\(name): the master is up, so the launch is staged before the spawn")
        commandSizes.append(try XCTUnwrap(doomed.argv.last).utf8.count)
        clients.append(try AcceptanceClient(doomed.argv))
        var ended = Liveness.present
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            _ = await sessions.collect(doomed.handle)
            ended = await sessions.exitCheck(doomed.handle)
            if ended != .present { break }
        }
        clients.removeLast().end()
        let words = await sessions.diagnostics(doomed.handle).map { raw in
            raw.replacingOccurrences(of: "\u{1b}", with: "^[").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3).joined(separator: " | ")
        }
        log.append("claude --resume <unknown id>: \(ended); diagnostics: \(words ?? "(none)")")
        if ended == .present {
            let stoppedDoomed = try await sessions.stop(doomed.handle, fromAttachedTab: false).outcome
            log.append("it was still running (onboarding); stopped: \(stoppedDoomed)")
        } else if !loggedOut {
            XCTAssertTrue(words?.contains("No conversation found") == true, "\(name): \(words ?? "nil")")
        }

        // Every run here ended with its end proven (stops acknowledged, an
        // absence checked): none leaves its pane's output behind.
        let leftOutputs = try await sh("""
        n=0; for mk in "$@"; do [ -e "$HOME/.temple/launch/$mk.out" ] && n=$((n+1)); done; echo $n
        """, markers)
        log.append("pane output files left by ended runs: \(leftOutputs)")
        XCTAssertEqual(leftOutputs, "0", "\(name)")

        // The resolver's containment, on this host's own sh: a login shell
        // that ignores TERM and leaves a child is abandoned within the
        // budget, and nothing of it is left running.
        let containment = try await sh("""
        f=$1/hangshell; n=$2
        printf '#!/bin/sh\\ntrap "" TERM\\nsleep %s &\\nsleep %s\\n' "$n" "$n" > "$f"; chmod +x "$f"
        SHELL=$f; export SHELL

        """ + RemoteEnvironment.resolverFunction + """

        t0=$(date +%s); temple_login_path __temple_m__ >/dev/null; r=$?; t1=$(date +%s)
        sleep 0.5
        echo "status=$r elapsed=$((t1 - t0))s left=$(pgrep -f "sleep $n" | wc -l | tr -d ' ') containment=$(command -v setsid >/dev/null 2>&1 && echo setsid || echo monitor)"
        """, [folder, "61.\(Int.random(in: 1000...9999))"])
        log.append("hanging login shell: \(containment)")

        // Every interactive command stayed short; the band where macOS's ssh
        // can't hand a session to its master is still there for a command
        // that isn't (informational: how often it bites varies).
        log.append("interactive command sizes: \(commandSizes) bytes (at most \(LaunchStage.maximumCommandBytes))")
        XCTAssertTrue(commandSizes.allSatisfy { $0 <= LaunchStage.maximumCommandBytes }, "\(name): \(commandSizes)")
        var refused = 0
        for length in [8060, 8080, 8100] {
            let probe = connection.argv(.query, remoteCommand: "exit 0 #" + String(repeating: "x", count: length - 8))
            let out = try await ProcessRunner.run(probe[0], Array(probe.dropFirst()), deadline: 20)
            if out.stderr.contains("send fds failed") { refused += 1 }
        }
        log.append("band-sized raw commands refused by this master: \(refused) of 3")
        XCTAssertTrue(containment.contains("left=0"), "\(name): \(containment)")
        // The hang really ran: abandoned at the budget, not refused at once.
        let elapsed = containment.split(separator: " ").first { $0.hasPrefix("elapsed=") }
            .flatMap { Int($0.dropFirst(8).dropLast()) } ?? 0
        XCTAssertTrue((4...8).contains(elapsed), "\(name): \(containment)")

        // The socket-missing case, as this tmux words it, on a throwaway server.
        let missing = try await sh("""
        s=temple-accept-$1
        tmux -L "$s" -f /dev/null new-session -d -s x 'sleep 60'
        p=$(tmux -L "$s" display-message -p '#{socket_path}')
        pid=$(tmux -L "$s" display-message -p '#{pid}')
        rm -f "$p"
        tmux -L "$s" has-session -t =x 2>&1; echo "status=$?"
        kill "$pid" 2>/dev/null; true
        """, [RemoteQuoting.nonce()])
        log.append("socket removed, has-session says: \(missing.replacingOccurrences(of: "\n", with: " | "))")
        XCTAssertTrue(missing.contains("status=1"))
        let after = try await sh("tmux -L temple ls -F '#{session_name}' 2>/dev/null || true")
        log.append("Temple server after: \(after.isEmpty ? "(none)" : after)")
    }
}

extension LinuxAcceptanceTests {
    // MARK: Phase 1b

    /// Codex identity on each box (section 3, phase 1b), with the real
    /// `codex` as installed there and a throwaway prompt in a temp folder:
    ///
    /// - **Automatic**: `codex --no-daemon` writes its own rollout, so the
    ///   pane's process tree holds it open and the walk adopts its id (the
    ///   default `codex` hands its sessions to a shared app server, which
    ///   is not this run's process: logged as what the walk said).
    /// - **Suggested**: with `/proc` hidden from the check (the test hook a
    ///   host without `/proc` stands for), the check is inconclusive for
    ///   good and the suggestion lookup offers the run's own rollout; the
    ///   user's yes claims it.
    ///
    /// Everything it made is removed: its tmux sessions, its folder, its
    /// records, the rollouts its sessions wrote (by id) and their writer
    /// locks, a trust entry Codex saved for the folder, and a Codex app
    /// server its own codex started where none ran before.
    @MainActor
    func testPhase1bCodexIdentityOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            try await codexIdentity(name)
        }
    }

    /// The walk's ownership rule on each box's real `/proc` and `sh`
    /// (round 1), with processes this test starts in a tmux server of its
    /// own and fake rollouts under a temp Codex home: a pane process that
    /// writes its own rollout is adopted; a child and a grandchild (a nested
    /// codex, as the agent could run one) writing theirs are never this
    /// run's. Everything is removed afterwards.
    @MainActor
    func testPhase1bOwnershipOnEachHostsProc() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            let state = TempTree("acceptance-own")
            let store = try RemoteStateStore(directory: state.url)
            let sessions = RemoteSessions(record: .config(name), stateDirectory: state.url, sshPath: "/usr/bin/ssh", store: { store })
            let exec = try await sessions.queryExec()
            func sh(_ script: String, _ args: [String] = []) async throws -> String {
                try await exec.run(script: script, args: args, deadline: 30).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let server = "own-\(RemoteQuoting.nonce())"
            let base = try await sh("mktemp -d /tmp/temple-accept-own-XXXXXX")
            XCTAssertTrue(base.hasPrefix("/tmp/temple-accept-own-"))
            defer {
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    _ = try? await exec.run(script: #"""
                    TMUX_TMPDIR=$1/tmux tmux -L "$2" kill-server 2>/dev/null
                    # The panes' backgrounded children outlive the server:
                    # this test's are those holding its files.
                    for p in $(pgrep -u "$(id -u)" -f '^sleep 120$'); do
                      ls -l "/proc/$p/fd" 2>/dev/null | grep -qF "$1/" && kill "$p"
                    done
                    case $1 in /tmp/temple-accept-own-*) rm -rf -- "$1" ;; esac
                    """#, args: [base, server], deadline: 20)
                    semaphore.signal()
                }
                semaphore.wait()
            }
            // A Codex home with three rollouts whose headers name the folder,
            // and the scripts the panes run.
            let setup = try await sh(#"""
            b=$1; mkdir -p "$b/tmux" "$b/home/sessions/2026/10/16" "$b/work"; w=$(cd "$b/work" && pwd -P)
            for k in A B C; do
              id=$(cat /proc/sys/kernel/random/uuid)
              f=$b/home/sessions/2026/10/16/rollout-2026-10-16T10-00-00-$id.jsonl
              printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"2026-10-16T17:00:00Z"}}\n' "$id" "$w" > "$f"
              echo "$f"
            done
            printf 'exec 3>>"$1"; exec sleep 120\n' > "$b/own.sh"
            printf 'sh "$0.child" "$1" "$2" & exec sleep 120\n' > "$b/nested.sh"
            printf 'exec 3>>"$1"; sh "%s/grand.sh" "$2" & exec sleep 120\n' "$b" > "$b/nested.sh.child"
            printf 'exec 4>>"$1"; exec sleep 120\n' > "$b/grand.sh"
            echo "$w"
            """#, [base])
            let parts = setup.split(separator: "\n").map(String.init)
            XCTAssertEqual(parts.count, 4, setup)
            let (rolloutA, rolloutB, rolloutC, folder) = (parts[0], parts[1], parts[2], parts[3])
            func pane(_ session: String, _ script: String, _ args: [String]) async throws -> (pid: Int, start: String, socket: String) {
                let answer = try await sh(#"""
                export TMUX_TMPDIR=$1/tmux; srv=$2; s=$3; shift 3
                tmux -L "$srv" -f /dev/null new-session -d -s "$s" "exec sh $*"
                sleep 1
                p=$(tmux -L "$srv" display-message -p -t "=$s:" '#{pane_pid}')
                st=$(cut -d')' -f2- /proc/$p/stat | awk '{print $20}')
                printf '%s %s %s\n' "$p" "$st" "$(tmux -L "$srv" display-message -p '#{socket_path}')"
                """#, [base, server, session, script] + args)
                let fields = answer.split(separator: " ").map(String.init)
                guard fields.count == 3 else { throw XCTSkip("\(name): no pane: \(answer)") }
                return (Int(fields[0]) ?? 0, fields[1], fields[2])
            }
            let home = (state: "set", value: base + "/home", base: folder)
            let own = try await pane("temple-own", base + "/own.sh", [rolloutA])
            let adopted = await CodexIdentityCheck.run(proc: "/proc", panePID: own.pid, paneStart: own.start, socket: own.socket,
                                                       session: "temple-own", home: home, using: exec)
            let nested = try await pane("temple-nested", base + "/nested.sh", [rolloutB, rolloutC])
            let tree = try await sh("ps -o pid,ppid,args --ppid $1; for c in $(pgrep -P $1); do ps -o pid,ppid,args --ppid $c | tail -n +2; done",
                                    [String(nested.pid)])
            let refused = await CodexIdentityCheck.run(proc: "/proc", panePID: nested.pid, paneStart: nested.start, socket: nested.socket,
                                                       session: "temple-nested", home: home, using: exec)
            print("== \(name) (phase 1b ownership on /proc)\npane writes its own: \(adopted)\nchild and grandchild write theirs: \(refused)\nthe nested pane's tree:\n\(tree)")
            guard case .found(let path, _) = adopted else { return XCTFail("\(name): the pane's own writer: \(adopted)") }
            XCTAssertEqual(path, rolloutA)
            XCTAssertEqual(refused, .inconclusive(.lasting("the session file is held by a process Temple didn't start")), "\(name)")
        }
    }

    @MainActor
    private func pendingPlan(_ outcome: RemoteSessions.PendingOpenOutcome) throws -> RemoteSessions.OpenPlan {
        guard case .plan(let plan) = outcome else { throw XCTSkip("expected a plan, got \(outcome)") }
        return plan
    }

    @MainActor
    private func codexIdentity(_ name: String) async throws {
        let state = TempTree("acceptance-1b")
        var log: [String] = ["== \(name) (phase 1b)"]
        defer { print(log.joined(separator: "\n")) }
        let store = try RemoteStateStore(directory: state.url)
        let sessions = RemoteSessions(record: .config(name), stateDirectory: state.url, sshPath: "/usr/bin/ssh", store: { store })
        let connection = try await sessions.resolvedConnection()
        defer {
            let check = connection.masterCheckArgv
            let exit = [check[0], check[1], check[2]] + SSHConnection.helperOptions + ["-O", "exit", "--", name]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exit[0])
            process.arguments = Array(exit.dropFirst())
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        let exec = try await sessions.queryExec()
        func sh(_ script: String, _ args: [String] = []) async throws -> String {
            let out = try await exec.run(script: script, args: args, deadline: 30)
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let started = try await sh("date +%s")
        log.append("codex: \(try await sh("command -v codex; codex --version 2>&1 | head -n 1"))")
        let before = try await sh("tmux -L temple ls -F '#{session_name}' 2>/dev/null || true")
        let recordsBefore = try await sh("[ -e \"$HOME/.temple\" ] && echo yes || echo no")
        let daemonBefore = try await sh("""
        p=$(sed -n 's/.*"pid":\\([0-9]*\\).*/\\1/p' "$HOME/.codex/app-server-daemon/daemon.pid" 2>/dev/null)
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p" || echo none
        """)
        log.append("Codex app server before: \(daemonBefore)")
        let folder = try await sh("mktemp -d /tmp/temple-accept-XXXXXX")
        XCTAssertTrue(folder.hasPrefix("/tmp/temple-accept-"), folder)
        let canonicalFolder = try await sh("cd -- \"$1\" && pwd -P", [folder])
        let configBefore = try await sh("cksum < \"$HOME/.codex/config.toml\" 2>/dev/null || echo none")
        var handles: [String] = []
        var markers: [String] = []
        var clients: [AcceptanceClient] = []
        var trusted = false
        defer {
            for client in clients { client.end() }
            let cleanup = #"""
            f=$1; since=$2; noneBefore=$3; markers=$4; recordsBefore=$5; daemonBefore=$6; trusted=$7; shift 7
            for h in "$@"; do tmux -L temple kill-session -t "=temple-$h" 2>/dev/null; done
            # The rollouts this test's sessions wrote: those whose header
            # names its folder, written since it started; removed by id, with
            # their writer locks.
            ids=
            for r in $(find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -newermt "@$since" 2>/dev/null); do
              head -c 65536 "$r" | head -n 1 | grep -qF "\"$f\"" || continue
              id=${r%.jsonl}; id=$(printf '%s' "$id" | sed 's/.*-\([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\)$/\1/')
              ids="$ids $id"
            done
            for id in $ids; do
              for r in $(find "$HOME/.codex/sessions" -name "rollout-*-$id.jsonl" 2>/dev/null); do rm -f "$r" && echo "removed rollout $id"; done
              rm -f "$HOME/.codex/thread-writer-locks/$id.lock"
            done
            # A Codex app server this test's codex started (none ran before):
            # stopped first, since it is what persists the trust decision.
            if [ "$daemonBefore" = none ]; then
              p=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$HOME/.codex/app-server-daemon/daemon.pid" 2>/dev/null)
              if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
                kill "$p" && echo "stopped the Codex app server this test started ($p)"
                i=0; while kill -0 "$p" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
              fi
            fi
            case $f in /tmp/temple-accept-*) rm -rf -- "$f" ;; esac
            # Trust entries Codex saved for this test's folders (only those
            # blocks, and only for temp folders that no longer exist).
            c=$HOME/.codex/config.toml
            if [ "$trusted" = yes ] && [ -f "$c" ]; then
              awk 'skip && /^\[/ {skip=0}
                   /^\[projects\."\/tmp\/temple-accept-[A-Za-z0-9]+"\]$/ { d=$0; sub(/^\[projects\."/, "", d); sub(/"\]$/, "", d)
                     if (system("test -e \"" d "\"") != 0) { skip=1; next } }
                   !skip' "$c" > "$c.temple-accept" && cat "$c.temple-accept" > "$c"
              rm -f "$c.temple-accept"
              echo "removed the trust entries for this test's folders: $(grep -c 'temple-accept' "$c") left"
            fi
            if [ "$noneBefore" = 1 ] && ! tmux -L temple ls >/dev/null 2>&1; then
              rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/temple"
            fi
            for mk in $markers; do rm -f "$HOME/.temple/launch/$mk" "$HOME/.temple/launch/$mk".*; done
            if [ "$recordsBefore" = no ]; then rmdir "$HOME/.temple/launch" "$HOME/.temple" 2>/dev/null; fi
            echo "left: tmux=$(tmux -L temple ls -F '#{session_name}' 2>/dev/null | grep -c . ) folder=$([ -e "$f" ] && echo yes || echo no) codex=$(pgrep -u "$(id -u)" -f "$f" | grep -c .)"
            """#
            let semaphore = DispatchSemaphore(value: 0)
            let args = [canonicalFolder, started, before.isEmpty ? "1" : "0", markers.joined(separator: " "),
                        recordsBefore, daemonBefore, trusted ? "yes" : "no"] + handles
            var cleanupLog = ""
            Task.detached {
                cleanupLog = (try? await exec.run(script: cleanup, args: args, deadline: 30).stdout) ?? "(cleanup did not answer)"
                semaphore.signal()
            }
            semaphore.wait()
            log.append("cleanup:\n" + cleanupLog.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Starts a pending Codex session and waits for its composer.
        func launch(_ extra: [String], label: String) async throws -> (plan: RemoteSessions.OpenPlan, socket: String) {
            let outcome = try await sessions.openPending(handle: nil, directory: folder, extraArguments: extra)
            let plan = try pendingPlan(outcome)
            handles.append(plan.handle)
            markers.append(RecordDirectory.marker(from: try XCTUnwrap(store.run(plan.handle)).recordPath) ?? "")
            XCTAssertTrue(plan.creating)
            XCTAssertEqual(plan.agentArgv, ["codex"] + extra, "codex mints its own id")
            clients.append(try AcceptanceClient(plan.argv))
            if !plan.staged {
                let staged = await sessions.stage(plan.stage)
                XCTAssertEqual(staged, .staged, "\(name): \(label)")
            }
            var collected = RemoteSessions.Collected.nothing
            for _ in 0..<40 {
                collected = await sessions.collect(plan.handle)
                if case .ok = collected { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard case .ok(let directory) = collected else {
                XCTFail("\(name): \(label): no ok record: \(collected)\n\(clients.last?.diagnosis ?? "")")
                throw XCTSkip("no ok record")
            }
            XCTAssertEqual(directory, canonicalFolder)
            let run = try XCTUnwrap(store.run(plan.handle))
            XCTAssertEqual(run.codexHome, .unset, "\(name): the pane recorded the Codex home it was given")
            let socket = try XCTUnwrap(run.socketPath)
            let session = "temple-\(plan.handle)"
            var screen = ""
            var ready = false
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(1))
                screen = try await sh("tmux -S \"$1\" capture-pane -p -t \"=$2:\"", [socket, session])
                if screen.contains("Update now") {
                    log.append("\(label): Codex offered an update; skipped it (Esc)")
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" Escape", [socket, session])
                    continue
                }
                if screen.contains("Trust this folder") {
                    log.append("\(label): Codex asked about trust; chose Trust and continue (removed afterwards)")
                    trusted = true
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" Enter", [socket, session])
                    continue
                }
                if screen.contains("Ask Codex") || screen.contains("OpenAI Codex") && screen.contains("›") { ready = true; break }
            }
            XCTAssertTrue(ready, "\(name): \(label): the composer never came; screen:\n\(screen)")
            // A TUI that has just drawn can drop typed keys and the first
            // Enter: type until the composer holds the prompt, Enter until it
            // shows above the composer as sent.
            var sent = false
            for attempt in 1...10 {
                screen = try await sh("tmux -S \"$1\" capture-pane -p -t \"=$2:\"", [socket, session])
                // Codex's own screens can come up after the composer has drawn.
                if screen.contains("Trust this folder") {
                    if !trusted { log.append("\(label): Codex asked about trust; chose Trust and continue (removed afterwards)") }
                    trusted = true
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" Enter", [socket, session])
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                if screen.contains("Update now") {
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" Escape", [socket, session])
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                let prompts = screen.split(separator: "\n").filter { $0.hasPrefix("›") }.map(String.init)
                if prompts.dropLast().contains(where: { $0.contains("reply with the word ok") }) {
                    if attempt > 2 { log.append("\(label): the prompt went in after \(attempt - 1) tries") }
                    sent = true
                    break
                }
                if prompts.last?.contains("reply with the word ok") == true {
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" Enter", [socket, session])
                } else {
                    _ = try await sh("tmux -S \"$1\" send-keys -t \"=$2:\" -l 'reply with the word ok'", [socket, session])
                }
                try await Task.sleep(for: .seconds(2))
            }
            XCTAssertTrue(sent, "\(name): \(label): the prompt never went in; screen:\n\(screen)")
            return (plan, socket)
        }

        /// The rollout a session wrote, by id: its header's id and folder.
        func rollout(_ id: String) async throws -> String {
            try await sh(#"""
            r=$(find "$HOME/.codex/sessions" -name "rollout-*-$1.jsonl" 2>/dev/null | head -n 1)
            [ -n "$r" ] || { echo none; exit 0; }
            h=$(head -c 65536 "$r" | head -n 1)
            case $h in *"$2"*) i=yes ;; *) i=no ;; esac
            case $h in *"$3"*) c=yes ;; *) c=no ;; esac
            echo "header id=$i cwd=$c"
            """#, [id, "\"id\":\"\(id)\"", "\"cwd\":\"\(canonicalFolder)\""])
        }

        // 1. Automatic: codex writing its own rollout (--no-daemon).
        let model = ["-m", "gpt-5.6-luna"]
        let automatic = try await launch(["--no-daemon"] + model, label: "automatic")
        var identity = RemoteSessions.Identity.inconclusive(.retry("not checked"))
        var tries: [String] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(2))
            identity = await sessions.identify(automatic.plan.handle)
            if case .adopted = identity { break }
            if case .inconclusive(let why) = identity { tries.append(why.reason) }
        }
        log.append("automatic (codex --no-daemon): \(identity) after \(tries.count) inconclusive checks \(Set(tries).sorted())")
        guard case .adopted(let adoptedID) = identity else {
            let screen = (try? await sh("tmux -S \"$1\" capture-pane -p -t \"=$2:\" | grep -v '^ *$' | tail -n 25",
                                        [automatic.socket, "temple-\(automatic.plan.handle)"])) ?? "(no screen)"
            return XCTFail("\(name): the process tree never adopted: \(identity)\nscreen:\n\(screen)")
        }
        let adoptedRun = try XCTUnwrap(store.run(automatic.plan.handle))
        XCTAssertEqual(adoptedRun.claim, .verified)
        XCTAssertEqual(adoptedRun.sessionID, adoptedID)
        let adoptedFile = try await rollout(adoptedID)
        log.append("adopted \(adoptedID): rollout \(adoptedFile)")
        XCTAssertEqual(adoptedFile, "header id=yes cwd=yes")
        let writer = try await sh("""
        p=$1; for f in /proc/$p/fd/*; do l=$(readlink "$f" 2>/dev/null); case $l in *rollout-*$2.jsonl) echo "pane pid $p holds it: $(grep flags /proc/$p/fdinfo/${f##*/} | tr -d '\t')"; exit 0;; esac; done
        for c in $(pgrep -P "$p"); do for f in /proc/$c/fd/*; do l=$(readlink "$f" 2>/dev/null); case $l in *rollout-*$2.jsonl) echo "child $c holds it"; exit 0;; esac; done; done
        echo "not held right now"
        """, [String(adoptedRun.panePID ?? 0), adoptedID])
        log.append("writer: \(writer)")
        clients.removeLast().end()
        let stoppedAutomatic = try await sessions.stop(automatic.plan.handle, fromAttachedTab: true).outcome
        XCTAssertEqual(stoppedAutomatic, .killed)
        log.append("stopped: \(stoppedAutomatic)")

        // 2. The default codex (its shared app server writes the rollout):
        // what the walk says, then the suggestion path with /proc hidden.
        let suggested = try await launch(model, label: "suggested")
        var shared = RemoteSessions.Identity.inconclusive(.retry("not checked"))
        var appeared = false
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(2))
            shared = await sessions.identify(suggested.plan.handle)
            if case .adopted = shared { break }
            let written = try await sh("""
            find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -newermt "@$1" 2>/dev/null | while read -r r; do
              head -c 65536 "$r" | head -n 1 | grep -qF "\"$2\"" && echo "$r"; done | grep -c .
            """, [started, canonicalFolder])
            if (Int(written) ?? 0) >= 2 { appeared = true; break }
        }
        log.append("default codex, process tree: \(shared)")
        XCTAssertTrue(appeared, "\(name): the default codex wrote no rollout for the prompt")
        if case .adopted = shared { log.append("(the default codex wrote in-process here: adopted without the suggestion path)") }
        sessions.procRoot = "/nonexistent-proc-\(RemoteQuoting.nonce())"
        var hidden = RemoteSessions.Identity.inconclusive(.retry("not checked"))
        if case .adopted = shared {} else {
            hidden = await sessions.identify(suggested.plan.handle)
            log.append("with /proc hidden: \(hidden)")
            XCTAssertEqual(hidden, .inconclusive(.lasting("this host has no /proc")))
            // The question names the first prompt once Codex has written it.
            var offered: [CodexSuggestion] = []
            for _ in 0..<15 {
                guard case .candidates(let found) = await sessions.suggestions(suggested.plan.handle) else {
                    return XCTFail("\(name): no suggestions")
                }
                offered = found
                if found.first?.firstPrompt != nil { break }
                try await Task.sleep(for: .seconds(2))
            }
            log.append("suggestions: \(offered.map { "\($0.sessionID) prompt=\($0.firstPrompt ?? "(none)")" })")
            XCTAssertEqual(offered.count, 1, "\(name): only this run's own rollout (the adopted one is held by its run)")
            let candidate = try XCTUnwrap(offered.first)
            XCTAssertNotEqual(candidate.sessionID, adoptedID)
            XCTAssertEqual(candidate.firstPrompt, "reply with the word ok")
            let yes = await sessions.confirm(suggested.plan.handle, suggestion: candidate)
            log.append("confirmed: \(yes)")
            XCTAssertEqual(yes, .adopted(candidate.sessionID))
            XCTAssertEqual(try store.run(suggested.plan.handle)?.claim, .confirmed)
            let confirmedFile = try await rollout(candidate.sessionID)
            log.append("confirmed \(candidate.sessionID): rollout \(confirmedFile)")
            XCTAssertEqual(confirmedFile, "header id=yes cwd=yes")
        }
        sessions.procRoot = "/proc"
        clients.removeLast().end()
        let stoppedSuggested = try await sessions.stop(suggested.plan.handle, fromAttachedTab: true).outcome
        XCTAssertEqual(stoppedSuggested, .killed)
        log.append("stopped: \(stoppedSuggested)")
        let leftOutputs = try await sh("""
        n=0; for mk in "$@"; do [ -e "$HOME/.temple/launch/$mk.out" ] && n=$((n+1)); done; echo $n
        """, markers)
        log.append("pane output files left by ended runs: \(leftOutputs)")
        XCTAssertEqual(leftOutputs, "0", "\(name)")
        let configNow = try await sh("cksum < \"$HOME/.codex/config.toml\" 2>/dev/null || echo none")
        log.append("codex config changed by the run: \(configNow != configBefore) (trust asked: \(trusted))")
    }
}

/// The tab, for acceptance: the launch argv on a local pty (`script`), its
/// stdin held open so the client stays. For a launch that stalls, it keeps
/// what makes it diagnosable: the ssh child's own pid and exit status (not
/// `script`'s), ssh's `-v` startup trace (`-E`), and what the pty showed.
final class AcceptanceClient {
    let process = Process()
    private let input = Pipe()
    private let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("temple-accept-\(UUID().uuidString)")
    var transcript: URL { base.appendingPathExtension("pty") }
    var trace: URL { base.appendingPathExtension("sshlog") }
    var pidFile: URL { base.appendingPathExtension("pid") }
    var statusFile: URL { base.appendingPathExtension("status") }

    init(_ argv: [String]) throws {
        // ssh's own trace, to a file: `-v -E <file>` right after ssh.
        var traced = argv
        if let ssh = traced.firstIndex(where: { $0.hasSuffix("/ssh") }) {
            traced.insert(contentsOf: ["-v", "-E", trace.path], at: ssh + 1)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", transcript.path, "/bin/sh", "-c",
                             #"echo $$ > "$0"; s=$1; shift; "$@"; echo $? > "$s""#, pidFile.path, statusFile.path] + traced
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func read(_ url: URL, suffix: Int) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return String(text.suffix(suffix)).replacingOccurrences(of: "\u{1b}", with: "^[")
    }

    /// The ssh child: its pid, whether it runs, its exit status if it ended.
    var sshState: String {
        let parent = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        child.arguments = ["-P", parent]
        let out = Pipe()
        child.standardOutput = out
        try? child.run()
        child.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).joined(separator: ",")
        let status = (try? String(contentsOf: statusFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ssh child pid=\(pids.isEmpty ? "(none)" : pids) running=\(!pids.isEmpty) exit=\(status ?? "(not ended)")"
    }

    var diagnosis: String {
        "\(sshState)\nssh -v trace (tail):\n\(read(trace, suffix: 2500))\npty (tail):\n\(read(transcript, suffix: 600))"
    }

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
        for url in [transcript, trace, pidFile, statusFile] { try? FileManager.default.removeItem(at: url) }
    }
}
