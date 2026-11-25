import Foundation
import SQLite3
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Antigravity on a host (ADR-044): the scripts run under `/bin/sh` against
/// real SQLite files shaped like `agy`'s, with the host's own `sqlite3` (and
/// `python3`'s module where there is none), a `/proc`-style fixture, and a
/// real process holding a lock (read with `lsof`, as on a host without
/// `/proc`). Nothing in a store is ever written by a read.
@MainActor
final class AntigravityRemoteTests: XCTestCase {
    typealias StandIn = RemoteScriptsTests.StandIn

    private let id = "502dbaf1-4ae5-4f7c-ab0f-53dfb69d6efd"
    private let other = "0d8063b7-4be9-440a-80ca-5ea1d4ba5e98"
    private let sent = Date(timeIntervalSince1970: 1_795_553_744)

    /// A host's home with `agy`'s store in it.
    final class Store {
        let host = StandIn()
        var root: String { host.home + "/.gemini/antigravity-cli" }
        var conversations: String { root + "/conversations" }
        var summaries: String { root + "/conversation_summaries.db" }
        func database(_ id: String) -> String { "\(conversations)/\(id).db" }

        init() {
            try? FileManager.default.createDirectory(atPath: conversations, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: root + "/presence", withIntermediateDirectories: true)
            // tmux names the pane by its pid (as `#{pane_pid}` answers).
            host.tree.write("bin/tmux", "#!/bin/sh\ncase \"$*\" in *display-message*) printf '%s\\n' \"${STUB_PANE_PID:-100}\" ;; esac\n",
                            executable: true)
        }

        var exec: LocalShellExec { LocalShellExec(path: nil, environment: host.environment) }

        /// A conversation as `agy` leaves it on exit: WAL mode, checkpointed,
        /// with no `-wal` or `-shm` (`wal` false: a rollback-journal file).
        func conversation(_ id: String, prompt: String?, at: Date?, wal: Bool = true) throws {
            let path = database(id)
            try SQLiteFile.exec(path, [
                wal ? "PRAGMA journal_mode=WAL" : "PRAGMA journal_mode=DELETE",
                "CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text)",
                "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, step_payload blob)",
                "INSERT INTO trajectory_meta VALUES ('t-\(id)', '\(id)')",
                "INSERT INTO steps VALUES (0, 15, x'00')",
            ] + (prompt.map { ["INSERT INTO steps VALUES (1, 14, x'\(Self.hex(Self.userStep($0, at: at)))')"] } ?? [])
              + (wal ? ["PRAGMA wal_checkpoint(TRUNCATE)"] : []))
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }

        func summary(_ id: String, title: String, folder: String, parent: String = "", steps: Int = 2,
                     modified: String = "2026-11-24 20:55:47.538592+00:00") throws {
            try SQLiteFile.exec(summaries, [
                "PRAGMA journal_mode=WAL",
                """
                CREATE TABLE IF NOT EXISTS conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '',
                  step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL,
                  workspace_uris text NOT NULL, parent_conversation_id text NOT NULL DEFAULT '')
                """,
                "INSERT INTO conversation_summaries VALUES ('\(id)', '\(title)', \(steps), '\(modified)', '[\"file://\(folder)\"]', '\(parent)')",
                "PRAGMA wal_checkpoint(TRUNCATE)",
            ])
            try? FileManager.default.removeItem(atPath: summaries + "-wal")
            try? FileManager.default.removeItem(atPath: summaries + "-shm")
        }

        func files() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: conversations)) ?? [])
                + ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
        }

        static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

        /// A user-input step as `agy` writes it: field 1 the step type, 5.1
        /// the time, 19.2 the text.
        static func userStep(_ text: String, at: Date?) -> [UInt8] {
            func varint(_ value: UInt64) -> [UInt8] {
                var v = value, out: [UInt8] = []
                repeat { var byte = UInt8(v & 0x7f); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
                return out
            }
            func bytes(_ number: UInt64, _ payload: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(payload.count)) + payload }
            func int(_ number: UInt64, _ value: UInt64) -> [UInt8] { varint(number << 3) + varint(value) }
            var meta: [UInt8] = []
            if let at { meta = bytes(1, int(1, UInt64(at.timeIntervalSince1970)) + int(2, 0)) }
            let text = Array(text.utf8)
            return int(1, 14) + bytes(5, meta) + bytes(19, bytes(2, text))
        }
    }

    private func read(_ store: Store, _ id: String, facts: Bool = true,
                      exec: RemoteExec? = nil) async throws -> AntigravityRemote.ReadAnswer {
        let output = try await (exec ?? store.exec).run(script: AntigravityRemote.readProgram,
                                                       args: [store.database(id), store.summaries, id, facts ? "1" : "0"],
                                                       deadline: 20)
        XCTAssertEqual(output.status, 0, output.stderr)
        return try XCTUnwrap(AntigravityRemote.parseRead(output.data, id: id), "unparsed: \(output.stdout)")
    }

    // MARK: Read

    func testAQuiescentConversationIsReadAsACheckedSnapshotAndLeftUntouched() async throws {
        let store = Store()
        try store.conversation(id, prompt: "Reply with only the word ok", at: sent)
        try store.summary(id, title: "Replying With Only Ok", folder: "/home/u/app")
        try store.summary(other, title: "Another", folder: "/home/u/app")
        let before = store.files().sorted()
        guard case .rows(let opening, let closing, let record) = try await read(store, id) else { return XCTFail() }
        XCTAssertEqual(opening, closing)
        XCTAssertEqual(record.ids, [id])
        XCTAssertEqual(record.summary?.title, "Replying With Only Ok", "the conversation's own row, not another's")
        XCTAssertEqual(record.summary?.workspaceURIs, "[\"file:///home/u/app\"]")
        XCTAssertEqual(record.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "Reply with only the word ok")
        XCTAssertEqual(store.files().sorted(), before, "no -wal or -shm made in a store that is not Temple's")

        guard case .rows(_, _, let identity) = try await read(store, id, facts: false) else { return XCTFail() }
        XCTAssertEqual(identity.ids, [id])
        XCTAssertNil(identity.summary, "an identity read takes the ids alone")
        XCTAssertNil(identity.firstUserStep)
    }

    /// A host without `sqlite3`: `python3`'s module reads the same rows.
    func testWithoutSqlite3PythonReadsTheSameRows() async throws {
        let store = Store()
        try store.conversation(id, prompt: "hello there", at: sent)
        try store.summary(id, title: "Hello", folder: "/w")
        // Every tool the host has, except sqlite3.
        let bin = store.host.tree.directory("nosqlite").path
        for folder in ["/usr/bin", "/bin"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name != "sqlite3" {
                try? FileManager.default.createSymbolicLink(atPath: "\(bin)/\(name)", withDestinationPath: "\(folder)/\(name)")
            }
        }
        var environment = store.host.environment
        environment["PATH"] = "\(store.host.bin):\(bin)"
        let exec = LocalShellExec(path: nil, environment: environment)
        let which = try await exec.run(script: "command -v sqlite3 || echo none", args: [], deadline: 5)
        XCTAssertEqual(which.stdout, "none\n", "the fixture hides sqlite3")
        guard case .rows(_, _, let record) = try await read(store, id, exec: exec) else { return XCTFail() }
        XCTAssertEqual(record.ids, [id])
        XCTAssertEqual(record.summary?.title, "Hello")
        XCTAssertEqual(record.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "hello there")
    }

    /// A writer with the database open: its commits are in the log, which
    /// the read-only open reads; the snapshot read would miss them.
    func testALiveWritersLogIsReadThrough() async throws {
        let store = Store()
        try store.conversation(id, prompt: nil, at: nil)
        let path = store.database(id)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["PRAGMA wal_autocheckpoint=0",
                    "INSERT INTO steps VALUES (1, 14, x'\(Store.hex(Store.userStep("only in the log", at: sent)))')"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
        guard case .rows(_, _, let record) = try await read(store, id) else { return XCTFail() }
        XCTAssertEqual(record.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "only in the log")
    }

    func testAMissingConversationIsMissingAndABadIdIsRefused() async throws {
        let store = Store()
        let missing = try await read(store, id)
        XCTAssertEqual(missing, .missing)
        let output = try await store.exec.run(script: AntigravityRemote.readProgram,
                                              args: [store.database(id), store.summaries, "x'; DROP TABLE t; --", "1"], deadline: 10)
        XCTAssertEqual(AntigravityRemote.parseRead(output.data, id: id), .unreadable("not a conversation id"))
    }

    func testTheReadsAnswerIsStrict() {
        let stat = "db\t10\t1.5\t7\nwal\tnone\n"
        XCTAssertNotNil(AntigravityRemote.parseRead(Data((stat + "id\t\(hex(id))\n" + stat + "done\n").utf8), id: id))
        XCTAssertNil(AntigravityRemote.parseRead(Data((stat + "id\t\(hex(id))\n" + stat).utf8), id: id), "no done")
        XCTAssertNil(AntigravityRemote.parseRead(Data((stat + "what\tx\n" + stat + "done\n").utf8), id: id), "an unknown line")
        XCTAssertNil(AntigravityRemote.parseRead(Data((stat + "busy\n" + stat + "done\n").utf8), id: id), "a terminal line mid-answer")
        XCTAssertEqual(AntigravityRemote.parseRead(Data((stat + "busy\n").utf8), id: id), .busy)
        XCTAssertEqual(AntigravityRemote.parseRead(Data((stat + "unreadable\tlocked\n").utf8), id: id), .unreadable("locked"))
        guard case .rows(let opening, _, _)? = AntigravityRemote.parseRead(
            Data(("db\t10\t1.5\t7\nwal\t32\t2.5\t8\n" + "db\t10\t1.5\t7\nwal\t32\t2.5\t8\ndone\n").utf8), id: id) else { return XCTFail() }
        XCTAssertEqual(opening.modifiedAt, Date(timeIntervalSince1970: 2.5), "the log's time when it is newer")
        guard case .rows(let first, let second, _)? = AntigravityRemote.parseRead(
            Data(("db\t10\t1.5\t7\nwal\t32\t2.5\t8\n" + "db\t10\t1.5\t7\nwal\t32\t2.5\t9\ndone\n").utf8), id: id) else { return XCTFail() }
        XCTAssertNotEqual(first, second, "a log replaced by one of the same size and time is another version")
    }

    private func hex(_ text: String) -> String { Store.hex(Array(text.utf8)) }

    // MARK: Through the source

    func testTheSourceLocatesAndReadsAConversationOnTheHost() async throws {
        let store = Store()
        try store.conversation(id, prompt: "Reply with only the word ok", at: sent)
        try store.summary(id, title: "Replying With Only Ok", folder: "/home/u/app")
        let provider = RemoteSourceTests.Provider(store.exec, roots: [.antigravity: RemoteTranscriptRoot(.unset, base: nil)!])
        let source = RemoteSessionSource(host: HostID(rawValue: "box"), provider: provider)
        let located = try await source.locate([LocateRequest(id: id, agent: .antigravity)])
        let candidate = try XCTUnwrap(located.candidates[id]?.first, "\(located)")
        XCTAssertTrue(candidate.locator.path.hasSuffix("/.gemini/antigravity-cli/conversations/\(id).db"), candidate.locator.path)
        let read = try await source.read(candidate.locator, agent: .antigravity, expecting: id, facts: true)
        XCTAssertEqual(read.identity, .verified)
        XCTAssertEqual(read.summary?.titleFact, "Replying With Only Ok")
        XCTAssertEqual(read.summary?.cwd, "/home/u/app")
        XCTAssertEqual(read.summary?.firstPrompt, "Reply with only the word ok")
        let mismatch = try await source.read(candidate.locator, agent: .antigravity, expecting: other, facts: true)
        XCTAssertEqual(mismatch.identity, .mismatch)
        XCTAssertNil(mismatch.summary)

        let lookup = try await source.lookup(id: id)
        guard case .found = lookup[.antigravity] else { return XCTFail("\(lookup)") }
        let notFound = try await source.lookup(id: other)
        XCTAssertEqual(notFound[.antigravity], .notFound)
    }

    // MARK: Identity

    /// One process in a `/proc`-style fixture: its stat (start time past the
    /// last `)`, field 22) and its open files.
    private func process(_ store: Store, pid: Int, start: Int, files: [String]) {
        let base = "proc/\(pid)"
        store.host.tree.write("\(base)/stat", "\(pid) (agy (x)) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 \(start) 0 0\n")
        _ = store.host.tree.directory("\(base)/fd")
        for (index, target) in files.enumerated() {
            try? FileManager.default.createSymbolicLink(atPath: "\(store.host.tree.path)/proc/\(pid)/fd/\(index + 3)",
                                                        withDestinationPath: target)
        }
    }

    private func identify(_ store: Store, pid: Int = 100, start: String? = "1000",
                          proc: String? = nil) async -> AntigravityRemote.IdentityAnswer {
        await AntigravityRemote.identify(proc: proc ?? store.host.tree.path + "/proc", panePID: pid, paneStart: start,
                                         socket: "/tmp/tmux-1000/temple", session: "temple-h1", using: store.exec)
    }

    func testThePanesOwnLockNamesItsConversation() async {
        let store = Store()
        let lock = "\(store.root)/presence/\(id).lock"
        process(store, pid: 100, start: 1000, files: ["/dev/null", "\(store.conversations)/\(other).db", lock])
        let found = await identify(store)
        XCTAssertEqual(found, .found(id))
        let reused = await identify(store, start: "999")
        XCTAssertEqual(reused, .inconclusive(.ended("the session's process has ended")),
                       "another process under a reused pid")
        store.host.extra["STUB_PANE_PID"] = "200"
        guard case .inconclusive(.retry) = await identify(store) else { return XCTFail("tmux names another pane") }
    }

    func testNoLockIsNoConversationYetAndTwoAreInconclusive() async {
        let store = Store()
        process(store, pid: 100, start: 1000, files: ["/dev/null", "\(store.root)/presence/notes.txt",
                                                      "\(store.root)/presence/x/\(id).lock"])
        let none = await identify(store)
        XCTAssertEqual(none, .none)
        process(store, pid: 101, start: 1000, files: ["\(store.root)/presence/\(id).lock", "\(store.root)/presence/\(other).lock"])
        store.host.extra["STUB_PANE_PID"] = "101"
        guard case .inconclusive(.retry) = await identify(store, pid: 101) else { return XCTFail("two conversations") }
    }

    func testTheLockIsMatchedUnderTheStoresResolvedPathToo() async throws {
        let store = Store()
        // `~/.gemini` a link to elsewhere: the kernel reports the real path.
        let elsewhere = store.host.tree.directory("real-gemini").path
        try FileManager.default.moveItem(atPath: store.host.home + "/.gemini", toPath: elsewhere + "/g")
        try FileManager.default.createSymbolicLink(atPath: store.host.home + "/.gemini", withDestinationPath: elsewhere + "/g")
        let real = elsewhere + "/g/antigravity-cli/presence/\(id).lock"
        process(store, pid: 100, start: 1000, files: [real])
        let resolved = await identify(store)
        XCTAssertEqual(resolved, .found(id))
    }

    /// No `/proc` (a macOS host): `ps` pins the process and `lsof` lists its
    /// files. A real process holds a real lock.
    func testWithoutProcARealProcessHoldingALockIsIdentified() async throws {
        let store = Store()
        let lock = "\(store.root)/presence/\(id).lock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3>>\"$1\"; exec /bin/sleep 30", "sh", lock]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        store.host.extra["STUB_PANE_PID"] = String(process.processIdentifier)
        var answer = AntigravityRemote.IdentityAnswer.none
        for _ in 0..<50 {
            answer = await identify(store, pid: Int(process.processIdentifier), start: nil, proc: "/nonexistent-proc")
            if answer != .none { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(answer, .found(id))
    }

    func testTheIdentityAnswerIsStrict() {
        XCTAssertEqual(AntigravityRemote.parseIdentity("found\t\(id)\n"), .found(id))
        guard case .inconclusive = AntigravityRemote.parseIdentity("found\t\(id.uppercased())\n") else { return XCTFail() }
        guard case .inconclusive = AntigravityRemote.parseIdentity("found\tnot-a-uuid\n") else { return XCTFail() }
        guard case .inconclusive = AntigravityRemote.parseIdentity("found\t\(id)\nfound\t\(other)\n") else { return XCTFail() }
        XCTAssertEqual(AntigravityRemote.parseIdentity("none\n"), .none)
        XCTAssertEqual(AntigravityRemote.parseIdentity("inconclusive\tlasting\tno lsof\n"), .inconclusive(.lasting("no lsof")))
    }

    // MARK: Suggestions

    func testTheListOffersConversationsStartedInTheRunsFolderWhileItRan() async throws {
        let store = Store()
        let okAt = 1_795_553_700
        let mine = "6e8833b0-0a18-4475-a159-f32c998a9f06", early = "43cab1c4-e60d-43c0-b363-fac9b4b89f36"
        let child = "8c8e8b9b-721a-4e3a-adda-6389fb94f724", elsewhere = "c9742222-e2a9-4b9b-9f4d-6717189122af"
        try store.conversation(mine, prompt: "make the tests pass", at: Date(timeIntervalSince1970: TimeInterval(okAt + 30)))
        try store.conversation(early, prompt: "an older one, still going", at: Date(timeIntervalSince1970: TimeInterval(okAt - 600)))
        try store.conversation(child, prompt: "a subagent", at: Date(timeIntervalSince1970: TimeInterval(okAt + 40)))
        try store.conversation(elsewhere, prompt: "another folder", at: Date(timeIntervalSince1970: TimeInterval(okAt + 50)))
        for (conversation, parent, folder) in [(mine, "", "/home/u/app"), (early, "", "/home/u/app"),
                                               (child, mine, "/home/u/app"), (elsewhere, "", "/home/u/other")] {
            try store.summary(conversation, title: "", folder: folder, parent: parent, modified: "2026-11-24 20:56:00.1+00:00")
        }
        try store.summary(id, title: "Long ago", folder: "/home/u/app", modified: "2026-01-01 00:00:00+00:00")
        let since = Date(timeIntervalSince1970: TimeInterval(okAt - 60))
        XCTAssertEqual(AntigravityRemote.timeText(since), "2026-11-24 20:54:00+00:00")
        let listing = await AntigravityRemote.list(since: since, using: store.exec)
        guard case .conversations(let now, let found) = listing else { return XCTFail("\(listing)") }
        XCTAssertGreaterThan(now, okAt)
        XCTAssertEqual(Set(found.map(\.id)), [mine, early, child, elsewhere], "rows changed since the run began, nothing older")
        let offered = AntigravityRemote.eligible(found, directory: "/home/u/app", since: okAt,
                                                 until: Date(timeIntervalSince1970: TimeInterval(okAt + 3600)),
                                                 declined: [], held: [], database: AntigravityRemote.declineKey)
        XCTAssertEqual(offered.map(\.sessionID), [mine])
        XCTAssertEqual(offered.first?.firstPrompt, "make the tests pass")
        XCTAssertEqual(offered.first?.rolloutPath, "~/.gemini/antigravity-cli/conversations/\(mine).db")
        XCTAssertTrue(AntigravityRemote.eligible(found, directory: "/home/u/app", since: okAt,
                                                 until: Date(timeIntervalSince1970: TimeInterval(okAt + 3600)),
                                                 declined: [RemotePath(AntigravityRemote.declineKey(mine))], held: [],
                                                 database: AntigravityRemote.declineKey).isEmpty, "declined")
        XCTAssertTrue(AntigravityRemote.eligible(found, directory: "/home/u/app", since: okAt,
                                                 until: Date(timeIntervalSince1970: TimeInterval(okAt + 3600)),
                                                 declined: [], held: [mine], database: AntigravityRemote.declineKey).isEmpty,
                      "another run's")
    }

    func testNoStoreListsNothing() async {
        let store = Store()
        let listing = await AntigravityRemote.list(since: Date(), using: store.exec)
        guard case .conversations(_, let found) = listing else { return XCTFail("\(listing)") }
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: Through RemoteSessions

    private func sessions(_ store: Store, run: RemoteStateStore) -> RemoteSessions {
        let environment = store.host.environment
        let sessions = RemoteSessions(record: .config("box"), stateDirectory: store.host.tree.url,
                                      sshPath: "/never-execute-ssh", store: { run },
                                      resolve: { _ in .resolved(["hostname": "fixture.invalid"]) },
                                      makeExec: { _, path, _ in LocalShellExec(path: path, environment: environment) },
                                      masterCheck: { _ in true })
        sessions.procRoot = store.host.tree.path + "/proc"
        return sessions
    }

    private func pendingRun(_ run: RemoteStateStore, folder: String) throws {
        var pending = RemoteRun(handle: "a", host: .init(rawValue: "box"), agent: .antigravity, mode: .new,
                                directoryIntent: folder, sessionID: nil, recordPath: "r-a", startedAt: Date())
        pending.creation = .proven
        pending.directory = folder
        pending.okAt = 1_795_553_700
        pending.panePID = 100
        pending.paneStart = "1000"
        try run.insert(pending)
    }

    func testAPendingRunIsClaimedFromItsPanesLock() async throws {
        let store = Store()
        let run = try RemoteStateStore()
        try pendingRun(run, folder: "/home/u/app")
        let sessions = sessions(store, run: run)
        process(store, pid: 100, start: 1000, files: [])
        guard case .inconclusive(.retry) = await sessions.identify("a") else { return XCTFail("no prompt yet") }
        XCTAssertNil(try run.run("a")?.sessionID)
        process(store, pid: 100, start: 1000, files: ["\(store.root)/presence/\(id).lock"])
        let adopted = await sessions.identify("a")
        XCTAssertEqual(adopted, .adopted(id))
        XCTAssertEqual(try run.run("a")?.sessionID, id)
        XCTAssertEqual(try run.run("a")?.claim, .verified)
        let known = await sessions.identify("a")
        XCTAssertEqual(known, .known(id))
    }

    func testAPendingRunThatEndedIsAskedAboutItsFoldersConversations() async throws {
        let store = Store()
        let run = try RemoteStateStore()
        try pendingRun(run, folder: "/home/u/app")
        try store.conversation(id, prompt: "fix the build", at: Date(timeIntervalSince1970: 1_795_553_730))
        try store.summary(id, title: "", folder: "/home/u/app", modified: "2026-11-24 20:55:40+00:00")
        let sessions = sessions(store, run: run)
        guard case .candidates(let found) = await sessions.suggestions("a") else { return XCTFail() }
        XCTAssertEqual(found.map(\.sessionID), [id])
        XCTAssertEqual(found.first?.firstPrompt, "fix the build")
        XCTAssertNotNil(found.first?.hostClockOffset)
        let yes = await sessions.confirm("a", suggestion: try XCTUnwrap(found.first))
        XCTAssertEqual(yes, .adopted(id))
        XCTAssertEqual(try run.run("a")?.claim, .confirmed)
    }

    func testOnlyAgentsThatMintTheirIdsStartPending() async throws {
        let store = Store()
        let sessions = sessions(store, run: try RemoteStateStore())
        do {
            _ = try await sessions.openPending(agent: .claude, handle: nil, directory: "~/p", extraArguments: [])
            XCTFail("Claude takes the id Temple gives it")
        } catch {}
        do {
            _ = try await sessions.open(.init(agent: .antigravity, sessionID: id, mode: .new, directory: "~/p"))
            XCTFail("a new Antigravity session starts without an id")
        } catch let error as RemoteSessions.OpenError {
            XCTAssertEqual(error, .refused("A new Antigravity session starts without an id (Temple learns it later)."))
        }
        XCTAssertEqual(sessions.agentArgv(.antigravity, sessionID: id, resume: true, extra: ["--model", "x"]),
                       ["agy", "--model", "x", "--conversation", id])
        XCTAssertEqual(sessions.agentArgv(.antigravity, sessionID: nil, resume: false, extra: []), ["agy"])
    }
}

/// Builds SQLite files with the system library.
enum SQLiteFile {
    struct Failure: Error { let message: String }
    static func exec(_ path: String, _ statements: [String], whileOpen: () throws -> Void = {}) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Failure(message: "open \(path)") }
        defer { sqlite3_close(db) }
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                defer { sqlite3_free(error) }
                throw Failure(message: error.map { String(cString: $0) } ?? sql)
            }
        }
        try whileOpen()
    }
}
