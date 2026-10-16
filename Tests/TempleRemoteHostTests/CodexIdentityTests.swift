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
                     files: [(target: String, flags: String)] = []) {
            let base = "proc/\(pid)"
            host.tree.write("\(base)/stat", "\(pid) (\(name) (x)) S \(parent) 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 \(start) 0 0\n")
            host.tree.write("\(base)/cmdline", argv.joined(separator: "\0") + "\0")
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

    /// Codex's npm launcher is the pane's process; the native binary under
    /// it writes the rollout: found at depth 1, and its header verifies.
    func testTheWriterUnderTheLauncherIsFound() async throws {
        let f = Fixture()
        let rollout = f.rollout()
        f.process(100, parent: 1, start: 1000, name: "node", argv: ["node", "/usr/lib/codex.js"])
        f.process(101, parent: 100, start: 1001, files: [(rollout.path, Self.writing), ("/dev/null", Self.writing)])
        f.process(102, parent: 101, start: 1005, name: "bash", argv: ["bash"])
        guard case .found(let path, let header) = await f.check() else { return XCTFail("not found") }
        XCTAssertEqual(path, rollout.path)
        XCTAssertEqual(CodexIdentityCheck.verify(path: path, header: header, directory: f.folder), rollout.id)
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

        // Two rollouts in the tree.
        f = Fixture()
        let a = f.rollout(), b = f.rollout()
        f.process(100, parent: 1, start: 1000, files: [(a.path, Self.writing)])
        f.process(101, parent: 100, start: 1002, files: [(b.path, Self.writing)])
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
        XCTAssertEqual(inconclusive(answer3), .lasting("a shared Codex app server writes this session's transcript"))

        // A writer that is not a descendant (the daemon outside the tree).
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
                guard case .found = answer else { return XCTFail("depth 4 is in the tree: \(answer)") }
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
        let answer = await CodexSuggestionLookup.run(home: ("unset", "", f.folder), since: Int(Date().timeIntervalSince1970) - 60,
                                                     directory: f.folder, using: f.exec)
        guard case .files(let now, let files) = answer else { return XCTFail("\(answer)") }
        XCTAssertLessThan(abs(now - Int(Date().timeIntervalSince1970)), 5)
        XCTAssertEqual(Set(files.map(\.path)).count, 5, "only the folder's rollouts are read")
        let candidates = CodexSuggestionLookup.candidates(files, directory: f.folder, since: since,
                                                          until: Date(timeIntervalSince1970: TimeInterval(since + 3600)),
                                                          declined: [declined.path], held: [held.id])
        XCTAssertEqual(candidates.map(\.sessionID), [blank.id, mine.id])
        XCTAssertEqual(candidates.last?.firstPrompt, "reply with the word ok")
        XCTAssertNil(candidates.first?.firstPrompt)
        XCTAssertFalse(candidates.contains { $0.sessionID == before.id })
        // The window's end bounds it too.
        let early = CodexSuggestionLookup.candidates(files, directory: f.folder, since: since,
                                                     until: ISO8601DateFormatter().date(from: "2026-10-16T17:20:05Z")!,
                                                     declined: [], held: [])
        XCTAssertEqual(early.map(\.sessionID), [mine.id])
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
