import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Codex identity (docs/designs/remote-ssh.md section 3, phase 1b): the
/// process-tree walk over `/proc`-style fixtures, executed under `/bin/sh`;
/// the suggestion lookup over a temp Codex home; the claims and their
/// uniqueness in the run store. Exactly one writable rollout in the pane's
/// own tree is adopted; every other case is inconclusive, never a claim.
@MainActor
final class CodexIdentityTests: XCTestCase {
    typealias StandIn = RemoteScriptsTests.StandIn

    /// A fake `/proc` and a Codex home under a stand-in host.
    final class Fixture {
        let host = StandIn()
        var proc: String { host.tree.path + "/proc" }
        var folder: String { host.tree.path + "/work" }
        var sessions: String { host.home + "/.codex/sessions/2026/10/16" }
        let paneStart = "1000"

        init() {
            _ = host.tree.directory("proc")
            _ = host.tree.directory("work")
            try? FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
            // tmux names the pane by its pid (as `#{pane_pid}` answers).
            host.tree.write("bin/tmux", "#!/bin/sh\ncase \"$*\" in *display-message*) printf '%s\\n' \"${STUB_PANE_PID:-100}\" ;; esac\n",
                            executable: true)
        }

        /// One process: its stat (start time past the last `)`, field 22),
        /// its argv and its open files (`target`, fdinfo `flags`).
        func process(_ pid: Int, parent: Int, start: Int, name: String = "codex", argv: [String] = ["codex"],
                     exe: String = "/home/u/.local/bin/codex", files: [(target: String, flags: String)] = []) {
            let base = "proc/\(pid)"
            host.tree.write("\(base)/stat", "\(pid) (\(name) (x)) S \(parent) 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 \(start) 0 0\n")
            host.tree.write("\(base)/cmdline", argv.joined(separator: "\0") + "\0")
            try? FileManager.default.createSymbolicLink(atPath: "\(proc)/\(pid)/exe", withDestinationPath: exe)
            _ = host.tree.directory("\(base)/fd")
            _ = host.tree.directory("\(base)/fdinfo")
            for (index, file) in files.enumerated() {
                let fd = index + 3
                try? FileManager.default.createSymbolicLink(atPath: "\(proc)/\(pid)/fd/\(fd)", withDestinationPath: file.target)
                host.tree.write("\(base)/fdinfo/\(fd)", "pos:\t0\nflags:\t\(file.flags)\nmnt_id:\t21\n")
            }
        }

        /// A rollout as Codex writes it: its header first.
        @discardableResult
        func rollout(_ id: String = UUID().uuidString.lowercased(), cwd: String? = nil, created: String = "2026-10-16T17:18:52.100Z",
                     named: String? = nil, subagent: Bool = false, prompt: String? = nil) -> (path: String, id: String) {
            let path = "\(sessions)/rollout-2026-10-16T10-18-52-\(named ?? id).jsonl"
            var payload: [String: Any] = ["id": id, "timestamp": created, "cwd": cwd ?? folder, "originator": "codex-tui"]
            if subagent { payload["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": "p"]]] }
            let header: [String: Any] = ["timestamp": created, "type": "session_meta", "payload": payload]
            var text = String(decoding: try! JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
            if let prompt {
                let line: [String: Any] = ["timestamp": created, "type": "event_msg", "payload": ["type": "user_message", "message": prompt]]
                text += String(decoding: try! JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
            }
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
            return (path, id)
        }

        var exec: LocalShellExec { LocalShellExec(path: nil, environment: host.environment) }

        func check(pid: Int = 100, start: String? = nil, proc: String? = nil,
                   home: (state: String, value: String, base: String)? = nil) async -> CodexIdentityCheck.Answer {
            await CodexIdentityCheck.run(proc: proc ?? self.proc, panePID: pid, paneStart: start ?? paneStart,
                                         socket: "/tmp/tmux-1000/temple", session: "temple-h1",
                                         home: home ?? ("unset", "", folder), using: exec)
        }
    }

    static let writing = "02102002", appending = "0102001", reading = "0100000"

    private func inconclusive(_ answer: CodexIdentityCheck.Answer, file: StaticString = #filePath, line: UInt = #line)
        -> CodexIdentityCheck.Inconclusive? {
        guard case .inconclusive(let why) = answer else {
            XCTFail("expected inconclusive, got \(answer)", file: file, line: line)
            return nil
        }
        return why
    }

    // MARK: The walk

    /// Codex's npm launcher is the pane's process (an interpreter running
    /// `codex.js`); the native binary under it, given the same arguments,
    /// is the launched CLI and writes the rollout: found at depth 1, and its
    /// header verifies.
    func testTheLaunchedCLIUnderTheLauncherIsFound() async throws {
        let f = Fixture()
        let rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, name: "node", argv: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js", "--no-daemon"],
                  exe: "/usr/bin/node")
        f.process(101, parent: 100, start: 1001, argv: ["/usr/lib/codex/codex-x86_64-unknown-linux-musl", "--no-daemon"],
                  exe: "/usr/lib/codex/codex-x86_64-unknown-linux-musl",
                  files: [(rollout.path, Self.writing), ("/dev/null", Self.writing)])
        f.process(102, parent: 101, start: 1005, name: "bash", argv: ["bash"], exe: "/usr/bin/bash")
        guard case .found(let path, let header) = await f.check() else { return XCTFail("not found") }
        XCTAssertEqual(path, rollout.path)
        XCTAssertEqual(CodexIdentityCheck.verify(path: path, header: header, directory: f.folder), rollout.id)
    }

    /// Only the run's own process counts (round 1): a child of a pane that
    /// is not a launcher shim, a child given other arguments than the pane,
    /// a child that is not a codex executable, and every deeper descendant
    /// (a codex the agent ran, say) prove nothing about this run. When
    /// only such processes hold a rollout, the question takes over.
    func testAWriterThatIsNotTheRunsOwnProcessIsNeverAdopted() async throws {
        let foreign = CodexIdentityCheck.Inconclusive.lasting("the session file is held by a process Temple didn't start")
        // The pane is codex itself; a nested `codex --no-daemon` under it
        // (as the agent's tool would run it) writes the only rollout.
        var f = Fixture()
        var rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(101, parent: 100, start: 1001, name: "bash", argv: ["bash", "-lc", "codex --no-daemon"], exe: "/usr/bin/bash")
        f.process(102, parent: 101, start: 1002, argv: ["codex", "--no-daemon"], files: [(rollout.path, Self.writing)])
        var answer = await f.check()
        XCTAssertEqual(inconclusive(answer), foreign, "a nested codex is never this run's")
        // The same at depth 1, under a pane that is codex (not a shim).
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(101, parent: 100, start: 1001, argv: ["codex", "exec", "hi"], files: [(rollout.path, Self.writing)])
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), foreign)
        // Under a shim, a child given other arguments is not the launched CLI.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, name: "node", argv: ["node", "/x/bin/codex.js"], exe: "/usr/bin/node")
        f.process(101, parent: 100, start: 1001, argv: ["codex", "exec", "hi"], files: [(rollout.path, Self.writing)])
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), foreign)
        // Under a shim, a child whose executable is not codex's.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, name: "node", argv: ["node", "/x/bin/codex.js"], exe: "/usr/bin/node")
        f.process(101, parent: 100, start: 1001, argv: ["python3"], exe: "/usr/bin/python3", files: [(rollout.path, Self.writing)])
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), foreign)
        // The pane's own writer is adopted even with a foreign one beside it.
        f = Fixture()
        let mine = f.rollout(), theirs = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(mine.path, Self.writing)])
        f.process(101, parent: 100, start: 1001, name: "bash", argv: ["bash"], exe: "/usr/bin/bash")
        f.process(102, parent: 101, start: 1002, files: [(theirs.path, Self.writing)])
        guard case .found(let path, _) = await f.check() else { return XCTFail() }
        XCTAssertEqual(path, mine.path)
    }

    /// A read that fails anywhere in the walk is inconclusive, never
    /// skipped, even with another rollout readable beside it (round 1): a
    /// descriptor whose link can't be read, a `fdinfo` that can't be read
    /// or is malformed, an argument list or executable that can't be read.
    func testAFailedReadIsNeverSkipped() async throws {
        // A descriptor link that can't be read, beside the pane's rollout.
        var f = Fixture()
        var rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(rollout.path, Self.writing)])
        f.host.tree.write("proc/100/fd/9", "not a link")
        chmod(f.proc + "/100/fd/9", 0)
        var answer = await f.check()
        // A regular file in fd/ is not a link: readlink fails.
        XCTAssertEqual(inconclusive(answer), .retry("a process's open file couldn't be read"))

        // A rollout's fdinfo that can't be read.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(rollout.path, Self.writing)])
        chmod(f.proc + "/100/fdinfo/3", 0)
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), .retry("a session file's flags couldn't be read"))

        // Malformed flags, and access mode 3 (not a write mode).
        for flags in ["0210200x", "", "0100003", "0100007"] {
            f = Fixture()
            rollout = f.rollout()
            f.process(100, parent: 1, start: 1000, files: [(rollout.path, flags)])
            answer = await f.check()
            if flags.hasSuffix("3") || flags.hasSuffix("7") {
                XCTAssertEqual(inconclusive(answer), .retry("no session file is open right now"), "mode 3 is not writing: \(flags)")
            } else {
                XCTAssertEqual(inconclusive(answer), .retry("a session file's flags couldn't be read"), flags)
            }
        }

        // The pane's arguments can't be read.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(rollout.path, Self.writing)])
        chmod(f.proc + "/100/cmdline", 0)
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), .retry("the session's process couldn't be read"))

        // A launched child's arguments can't be read.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, name: "node", argv: ["node", "/x/bin/codex.js"], exe: "/usr/bin/node")
        f.process(101, parent: 100, start: 1001, argv: ["codex"], files: [(rollout.path, Self.writing)])
        chmod(f.proc + "/101/cmdline", 0)
        answer = await f.check()
        XCTAssertEqual(inconclusive(answer), .retry("a process's arguments couldn't be read"))
    }

    /// A Codex home whose name ends in a newline is that folder, not its
    /// namesake without one.
    func testAHomeEndingInANewlineIsKept() async throws {
        let f = Fixture()
        let plain = f.host.tree.directory("codexhome").path
        let odd = plain + "\n"
        try FileManager.default.createDirectory(atPath: odd + "/sessions/2026/10/16", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: plain + "/sessions/2026/10/16", withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let path = odd + "/sessions/2026/10/16/rollout-2026-10-16T10-18-52-\(id).jsonl"
        FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8))
        f.process(100, parent: 1, start: 1000, files: [(path, Self.writing)])
        guard case .found(let found, _) = await f.check(home: ("set", odd, f.folder)) else { return XCTFail("the odd home") }
        XCTAssertEqual(found, path)
        let other = await f.check(home: ("set", plain, f.folder))
        XCTAssertEqual(inconclusive(other), .retry("no session file is open right now"), "a different folder")
    }

    /// The pane itself writes (a standalone codex, or `--no-daemon`), and
    /// the same file held twice is one rollout.
    func testThePaneItselfAndOneFileHeldTwice() async throws {
        let f = Fixture()
        let rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(rollout.path, Self.writing), (rollout.path, Self.appending)])
        guard case .found(let path, _) = await f.check() else { return XCTFail() }
        XCTAssertEqual(path, rollout.path)
    }

    func testEveryOtherTreeIsInconclusive() async throws {
        // Read-only: not a writer.
        var f = Fixture()
        var rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(rollout.path, Self.reading)])
        let answer1 = await f.check()
        XCTAssertEqual(inconclusive(answer1), .retry("no session file is open right now"))

        // Two rollouts held by the run's own process.
        f = Fixture()
        let a = f.rollout(), b = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(a.path, Self.writing), (b.path, Self.writing)])
        let answer2 = await f.check()
        XCTAssertEqual(inconclusive(answer2), .retry("more than one session file is open"))

        // A shared app server in the tree (the TUI started the daemon as its
        // child): it writes every session of the account, so what it holds
        // is not this run's.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(101, parent: 100, start: 1003, argv: ["/home/u/.codex/packages/app-server-daemon/codex", "app-server",
                                                         "--listen", "unix://", "--managed-daemon"],
                  files: [(rollout.path, Self.writing)])
        let answer3 = await f.check()
        XCTAssertEqual(inconclusive(answer3), .lasting("the session file is held by a process Temple didn't start"))

        // A writer that is not a descendant (the server outside the tree).
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(50, parent: 1, start: 10, argv: ["codex", "app-server"], files: [(rollout.path, Self.writing)])
        let answer4 = await f.check()
        XCTAssertEqual(inconclusive(answer4), .retry("no session file is open right now"))

        // Start-time ordering: a "child" older than its parent is a reused
        // pid's, not a descendant.
        f = Fixture()
        rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(101, parent: 100, start: 999, files: [(rollout.path, Self.writing)])
        let answer5 = await f.check()
        XCTAssertEqual(inconclusive(answer5), .retry("no session file is open right now"))

        // A rollout outside the run's Codex home is not one of its sessions.
        f = Fixture()
        let stray = f.host.tree.write("elsewhere/rollout-2026-10-16T10-18-52-\(UUID().uuidString.lowercased()).jsonl", "{}\n")
        f.process(100, parent: 1, start: 1000, files: [(stray.path, Self.writing)])
        let answer6 = await f.check()
        XCTAssertEqual(inconclusive(answer6), .retry("no session file is open right now"))
    }

    /// The walk stops at a depth of 4.
    /// The walk reaches a depth of 4 (a writer there is in the tree, and
    /// not the run's own) and no further.
    func testTheDepthLimit() async throws {
        for depth in [4, 5] {
            let f = Fixture()
            let rollout = f.rollout()
            f.process(100, parent: 1, start: 1000)
            for level in 1...depth {
                f.process(100 + level, parent: 100 + level - 1, start: 1000 + level,
                          files: level == depth ? [(rollout.path, Self.writing)] : [])
            }
            let answer = await f.check()
            if depth == 4 {
                XCTAssertEqual(inconclusive(answer), .lasting("the session file is held by a process Temple didn't start"),
                               "depth 4 is in the tree, and not the run's own process")
            } else {
                XCTAssertEqual(inconclusive(answer), .retry("no session file is open right now"), "depth 5 is not")
            }
        }
    }

    /// The pane's pid reused (another start time), tmux naming another
    /// pane, no `/proc`, an unreadable descriptor table, an unknown home:
    /// each inconclusive, with how lasting it is.
    func testWhatTheWalkWillNotTrust() async throws {
        var f = Fixture()
        f.process(100, parent: 1, start: 1777)
        let answer7 = await f.check()
        XCTAssertEqual(inconclusive(answer7), .ended("the session's process has ended"))
        let answer8 = await f.check(pid: 404)
        XCTAssertEqual(inconclusive(answer8), .ended("the session's process has ended"))

        f = Fixture()
        f.process(100, parent: 1, start: 1000)
        f.host.extra = ["STUB_PANE_PID": "555"]
        let answer9 = await f.check()
        XCTAssertEqual(inconclusive(answer9), .retry("tmux doesn't name this process as the session's pane"))

        f = Fixture()
        let answer10 = await f.check(proc: f.host.tree.path + "/no-proc")
        XCTAssertEqual(inconclusive(answer10), .lasting("this host has no /proc"))

        f = Fixture()
        let rollout = f.rollout()
        f.process(100, parent: 1, start: 1000)
        f.process(101, parent: 100, start: 1001, files: [(rollout.path, Self.writing)])
        chmod(f.proc + "/101/fd", 0)
        defer { chmod(f.proc + "/101/fd", 0o755) }
        let answer11 = await f.check()
        XCTAssertEqual(inconclusive(answer11), .retry("a process's open files couldn't be read"))

        f = Fixture()
        f.process(100, parent: 1, start: 1000)
        let answer12 = await f.check(home: ("set", "/no/such/codex", f.folder))
        guard case .lasting = inconclusive(answer12) else { return XCTFail() }
        XCTAssertNil(CodexHomeRoot.arguments(.set(""), base: "/x"), "an empty CODEX_HOME is not guessed at")
        XCTAssertNil(CodexHomeRoot.arguments(nil, base: "/x"))
        XCTAssertEqual(CodexHomeRoot.arguments(.set("rel"), base: "/w")?.value, "rel")
    }

    /// A found file is the run's only when its header names its own file's
    /// id, the run's folder, and a session a person started.
    func testAFoundFileMustVerify() async throws {
        let f = Fixture()
        func header(_ path: String) throws -> Data {
            Data(try XCTUnwrap(String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").first).utf8)
        }
        let good = f.rollout()
        XCTAssertEqual(CodexIdentityCheck.verify(path: good.path, header: try header(good.path), directory: f.folder), good.id)
        XCTAssertNil(CodexIdentityCheck.verify(path: good.path, header: try header(good.path), directory: "/elsewhere"))
        let renamed = f.rollout(named: UUID().uuidString.lowercased())
        XCTAssertNil(CodexIdentityCheck.verify(path: renamed.path, header: try header(renamed.path), directory: f.folder))
        let subagent = f.rollout(subagent: true)
        XCTAssertNil(CodexIdentityCheck.verify(path: subagent.path, header: try header(subagent.path), directory: f.folder))
    }

    // MARK: Suggestions

    /// The lookup reads only rollouts in the run's folder touched since its
    /// `ok`; the candidates are those begun in its window, newest first,
    /// with their first prompt; declined files and ids another run holds
    /// are never offered.
    func testSuggestionsAreTheRunsCandidatesOnly() async throws {
        let f = Fixture()
        let mine = f.rollout(created: "2026-10-16T17:20:00.000Z", prompt: "reply with the word ok")
        let blank = f.rollout(created: "2026-10-16T17:21:00.000Z")
        _ = f.rollout(cwd: "/somewhere/else", created: "2026-10-16T17:20:30.000Z")
        let before = f.rollout(created: "2026-10-16T16:00:00.000Z")
        let declined = f.rollout(created: "2026-10-16T17:20:10.000Z")
        let held = f.rollout(created: "2026-10-16T17:20:20.000Z")
        let since = Int(ISO8601DateFormatter().date(from: "2026-10-16T17:19:00Z")!.timeIntervalSince1970)
        let listing = await CodexSuggestionLookup.list(home: ("unset", "", f.folder), since: Int(Date().timeIntervalSince1970) - 60,
                                                       directory: f.folder, using: f.exec)
        guard case .headers(let now, let files) = listing else { return XCTFail("\(listing)") }
        XCTAssertLessThan(abs(now - Int(Date().timeIntervalSince1970)), 5)
        XCTAssertEqual(Set(files.map(\.path)).count, 5, "only the folder's rollouts are read")
        let eligible = CodexSuggestionLookup.eligible(files, directory: f.folder, since: since,
                                                      until: Date(timeIntervalSince1970: TimeInterval(since + 3600)),
                                                      declined: [declined.path], held: [held.id])
        XCTAssertEqual(eligible.map(\.sessionID), [blank.id, mine.id])
        let fetched = await CodexSuggestionLookup.heads(eligible.map(\.rolloutPath), using: f.exec)
        let heads = try XCTUnwrap(fetched)
        let candidates = CodexSuggestionLookup.withPrompts(eligible, heads: heads)
        XCTAssertEqual(candidates.last?.firstPrompt, "reply with the word ok")
        XCTAssertNil(candidates.first?.firstPrompt)
        XCTAssertFalse(candidates.contains { $0.sessionID == before.id })
        // The window's end bounds it too.
        let early = CodexSuggestionLookup.eligible(files, directory: f.folder, since: since,
                                                   until: ISO8601DateFormatter().date(from: "2026-10-16T17:20:05Z")!,
                                                   declined: [], held: [])
        XCTAssertEqual(early.map(\.sessionID), [mine.id])
    }

    /// Paths travel whole (a folder whose name holds a newline is one
    /// path); a session file that can't be read, or a folder that can't be
    /// searched, makes the lookup unavailable rather than a partial list.
    func testTheLookupIsPathSafeAndNeverPartial() async throws {
        var f = Fixture()
        let odd = f.sessions + "/x\ny"
        try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let header: [String: Any] = ["type": "session_meta", "timestamp": "2026-10-16T17:20:00Z",
                                     "payload": ["id": id, "cwd": f.folder, "timestamp": "2026-10-16T17:20:00Z"]]
        let path = odd + "/rollout-2026-10-16T10-18-52-\(id).jsonl"
        FileManager.default.createFile(atPath: path, contents: try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes]) + Data("\n".utf8))
        var listing = await CodexSuggestionLookup.list(home: ("unset", "", f.folder), since: Int(Date().timeIntervalSince1970) - 60,
                                                       directory: f.folder, using: f.exec)
        guard case .headers(_, let files) = listing else { return XCTFail("\(listing)") }
        XCTAssertEqual(files.map(\.path), [path])

        f = Fixture()
        let unreadable = f.rollout()
        chmod(unreadable.path, 0)
        listing = await CodexSuggestionLookup.list(home: ("unset", "", f.folder), since: Int(Date().timeIntervalSince1970) - 60,
                                                   directory: f.folder, using: f.exec)
        XCTAssertEqual(listing, .unavailable("not every session file could be read"))

        f = Fixture()
        _ = f.rollout()
        let closed = f.sessions + "/closed"
        try FileManager.default.createDirectory(atPath: closed, withIntermediateDirectories: true)
        chmod(closed, 0)
        defer { chmod(closed, 0o755) }
        listing = await CodexSuggestionLookup.list(home: ("unset", "", f.folder), since: Int(Date().timeIntervalSince1970) - 60,
                                                   directory: f.folder, using: f.exec)
        XCTAssertEqual(listing, .unavailable("not every session file could be read"))
    }

    /// The answer must be whole: a frame cut short, a wrong length, bytes
    /// after `done`, or no `done` at all is unavailable.
    func testTheLookupsFramingIsStrict() {
        let path = Data("/h/sessions/rollout-x.jsonl".utf8).map { String(format: "%02x", $0) }.joined()
        func parse(_ text: String) -> CodexSuggestionLookup.Listing { CodexSuggestionLookup.parseList(Data(text.utf8)) }
        guard case .headers(1, let files) = parse("now\t1\nfile\t\(path)\t2\n{}\nend\ndone\n") else { return XCTFail() }
        XCTAssertEqual(files.map(\.header), [Data("{}".utf8)])
        for broken in ["now\t1\nfile\t\(path)\t2\n{}\nend\n",
                       "now\t1\nfile\t\(path)\t3\n{}\nend\ndone\n",
                       "now\t1\nfile\t\(path)\t2\n{}\nend\ndone\nextra",
                       "now\t1\nfile\t\(path)\t2\n{}",
                       "now\t1\n"] {
            guard case .unavailable = parse(broken) else { return XCTFail("accepted: \(broken.debugDescription)") }
        }
        XCTAssertEqual(parse("now\t1\nunavailable\tnot every session file could be read\n"),
                       .unavailable("not every session file could be read"))
    }

    /// Codex's app server records the prompt as a user message item behind
    /// its injected blocks, with no `user_message` event: the question still
    /// names it.
    func testTheFirstPromptOfAnAppServerRollout() {
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "x", "cwd": "/w", "timestamp": "2026-10-16T17:00:00Z"]],
            ["type": "response_item", "payload": ["type": "message", "role": "developer",
                                                  "content": [["type": "input_text", "text": "<skills_instructions>x"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "<environment_context>\n<cwd>/w</cwd>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "reply with the word ok"]]]],
        ]
        let head = Data(lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").utf8)
        XCTAssertNil(CodexFormat.firstUserMessage(in: head))
        XCTAssertEqual(CodexFormat.firstTypedPrompt(in: head), "reply with the word ok")
    }

    func testTheFolderIsMatchedAsJSONSpellsIt() {
        XCTAssertEqual(CodexSuggestionLookup.jsonString("/home/u/a \"b\"\\c\n\u{1}é/"), #""/home/u/a \"b\"\\c\n\u0001é/""#)
        let header: [String: Any] = ["cwd": "/home/u/a \"b\"\\c\n\u{1}é/"]
        let data = try! JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(CodexSuggestionLookup.jsonString("/home/u/a \"b\"\\c\n\u{1}é/")))
    }

    // MARK: Claims

    private func pendingRun(_ store: RemoteStateStore, _ handle: String, host: HostID = HostID(rawValue: "box")) throws {
        var run = RemoteRun(handle: handle, host: host, agent: .codex, mode: .new, directoryIntent: "~",
                            sessionID: nil, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
        run.conversation = .unconfirmed
        try store.insert(run)
    }

    /// Two pending runs in one folder can both be shown one candidate; the
    /// first yes claims it and the other is refused (it keeps asking). A
    /// claim is written before the core join, and released when core
    /// refuses; several runs of one session (its resumes) are allowed.
    func testClaimsAreUniquePerHostAndReleasable() throws {
        let store = try RemoteStateStore()
        try pendingRun(store, "a")
        try pendingRun(store, "b")
        XCTAssertEqual(try store.claim("a", sessionID: "c1", how: .confirmed), .claimed)
        XCTAssertEqual(try store.claim("b", sessionID: "c1", how: .verified), .taken)
        XCTAssertNil(try store.run("b")?.sessionID)
        XCTAssertEqual(try store.claim("a", sessionID: "c2", how: .verified), .alreadyKnown("c1"))
        let claimed = try XCTUnwrap(store.run("a"))
        XCTAssertEqual(claimed.claim, .confirmed)
        XCTAssertEqual(claimed.conversation, .confirmed)
        XCTAssertNil(claimed.joinedAt)
        XCTAssertEqual(try store.unjoinedClaims(host: HostID(rawValue: "box")).map(\.handle), ["a"])
        try store.markJoined("a", at: Date())
        XCTAssertEqual(try store.unjoinedClaims(host: HostID(rawValue: "box")), [])
        // A resume of the claimed session is another run of it: allowed.
        var resume = RemoteRun(handle: "r", host: HostID(rawValue: "box"), agent: .codex, mode: .resume, directoryIntent: "~",
                               sessionID: "c1", recordPath: RecordDirectory.locator(marker: "r-r"), startedAt: Date())
        resume.conversation = .confirmed
        try store.insert(resume)
        XCTAssertEqual(try store.runs(host: HostID(rawValue: "box"), sessionID: "c1").count, 2)
        // The same id on another host is another host's business.
        try pendingRun(store, "z", host: HostID(rawValue: "jet"))
        XCTAssertEqual(try store.claim("z", sessionID: "c1", how: .verified), .claimed)
        // Released: pending again, and the other run may claim it.
        try store.releaseClaim("a", sessionID: "c1")
        XCTAssertNil(try store.run("a")?.sessionID)
        try store.dismissRun("r", at: Date())
        try store.update("r") { $0.sessionID = nil }
        XCTAssertEqual(try store.claim("b", sessionID: "c1", how: .confirmed), .claimed)
        // The database itself refuses a second claim of one id on a host.
        XCTAssertThrowsError(try store.update("a") { $0.sessionID = "c1"; $0.claim = .verified })
    }

    func testDeclinedCandidatesAndPendingRestore() throws {
        let store = try RemoteStateStore()
        try pendingRun(store, "a")
        try pendingRun(store, "b")
        try pendingRun(store, "c")
        try store.decline("a", rolloutPath: "/r/1")
        try store.decline("a", rolloutPath: "/r/1")
        XCTAssertEqual(try store.declined("a"), ["/r/1"])
        XCTAssertEqual(try store.declined("b"), [])
        XCTAssertEqual(try store.claim("a", sessionID: "z1", how: .confirmed, rolloutPath: "/r/1"), .declined,
                       "a declined file is refused in the claim's own transaction")
        XCTAssertNil(try store.run("a")?.sessionID)
        try store.update("b") { $0.tabClosedAt = Date() }
        try store.dismissRun("c", at: Date())
        XCTAssertEqual(try store.pendingRuns(host: HostID(rawValue: "box")).map(\.handle), ["a"])
        // Reopening a pending run clears its closed tab; an ended one says so.
        XCTAssertEqual(try store.reservePending("b").handle, "b")
        XCTAssertNil(try store.run("b")?.tabClosedAt)
        try store.update("a") { $0.endedAt = Date() }
        XCTAssertEqual(try store.reservePending("a"), .ended(try XCTUnwrap(store.run("a"))))
        XCTAssertEqual(try store.reservePending("c"), .gone)
        _ = try store.claim("b", sessionID: "x", how: .verified)
        XCTAssertEqual(try store.reservePending("b"), .identified("x"))
    }
}

private extension RemoteStateStore.PendingReservation {
    var handle: String? {
        if case .existing(let run) = self { return run.handle }
        return nil
    }
}
