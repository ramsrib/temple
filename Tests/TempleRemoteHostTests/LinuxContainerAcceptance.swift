import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Antigravity's host scripts in real Linux userlands (ADR-044): dash
/// (Debian) and busybox (Alpine) as `/bin/sh`, each distribution's own
/// `sqlite3` and `python3`, a real `/proc`, a real tmux pane, and `lsof`.
/// A stand-in process holds the presence lock the way `agy` does (the
/// pane's own process, opened and kept). Opt in with
/// `TEMPLE_LINUX_CONTAINERS=<container>[,<container>…]`: running
/// containers with a user `u`, sqlite3, python3, tmux, procps and lsof
/// (docs/designs/remote-ssh.md, "Antigravity on a host"). Nothing else
/// reaches a container.
final class LinuxContainerAcceptance: XCTestCase {
    private let id = "502dbaf1-4ae5-4f7c-ab0f-53dfb69d6efd"
    private let other = "0d8063b7-4be9-440a-80ca-5ea1d4ba5e98"
    private let sent = Date(timeIntervalSince1970: 1_795_553_744)

    private var containers: [String] {
        (ProcessInfo.processInfo.environment["TEMPLE_LINUX_CONTAINERS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A query run in the container as `u`, the way `SSHExec` runs one on a
    /// host: the bootstrap on the command line, the program on stdin.
    struct ContainerExec: RemoteExec {
        let container: String
        let path: String?
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
            let marker = "__temple_\(RemoteQuoting.nonce())__"
            let invocation = SSHExec.invocation(script: script, args: args, path: path, input: input, marker: marker)
            let raw = try await ProcessRunner.run("/usr/local/bin/docker",
                                                  ["exec", "-i", "-u", "u", "-e", "HOME=/home/u", "-w", "/home/u", container,
                                                   "/bin/sh", "-c", invocation.command],
                                                  input: invocation.stdin, deadline: deadline)
            return SSHExec.unframe(raw, marker: marker)
        }
    }

    private func sh(_ exec: RemoteExec, _ script: String, _ args: [String] = []) async throws -> RemoteOutput {
        let output = try await exec.run(script: script, args: args, deadline: 30)
        XCTAssertEqual(output.status, 0, "\(script.prefix(60))…: \(output.stderr)")
        return output
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// A fresh store: `id` (titled, in /home/u/app, WAL left as `agy`
    /// leaves it on exit) and `other` (in another folder).
    private let storeSetup = #"""
    set -e
    r=$HOME/.gemini/antigravity-cli; rm -rf "$r"; mkdir -p "$r/conversations" "$r/presence"
    mk() {
      db=$r/conversations/$1.db
      sqlite3 "$db" "PRAGMA journal_mode=WAL; CREATE TABLE trajectory_meta (trajectory_id text PRIMARY KEY, cascade_id text);
        CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, step_payload blob);
        INSERT INTO trajectory_meta VALUES ('t-$1', '$1'); INSERT INTO steps VALUES (0, 15, x'00');
        INSERT INTO steps VALUES (1, 14, x'$2'); PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
      rm -f "$db-wal" "$db-shm"
    }
    mk "$1" "$3"; mk "$2" "$4"
    sqlite3 "$r/conversation_summaries.db" "PRAGMA journal_mode=WAL;
      CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '',
        step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL, workspace_uris text NOT NULL,
        parent_conversation_id text NOT NULL DEFAULT '');
      INSERT INTO conversation_summaries VALUES ('$1', 'Replying With Only Ok', 2, '2026-11-24 20:55:47.538592+00:00', '[\"file:///home/u/app\"]', '');
      INSERT INTO conversation_summaries VALUES ('$2', '', 2, '2026-11-24 20:55:50+00:00', '[\"file:///home/u/other\"]', '');
      PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
    rm -f "$r/conversation_summaries.db-wal" "$r/conversation_summaries.db-shm"
    mkdir -p "$HOME/nosq"
    for f in /usr/bin/* /bin/*; do n=${f##*/}; [ "$n" = sqlite3 ] || [ -e "$HOME/nosq/$n" ] || ln -s "$f" "$HOME/nosq/$n"; done
    """#

    private func userStep(_ text: String, at: Date) -> String {
        Self.hex(AntigravityRemoteTests.Store.userStep(text, at: at))
    }

    func testAntigravityScriptsInLinuxUserlands() async throws {
        guard !containers.isEmpty else { throw XCTSkip("set TEMPLE_LINUX_CONTAINERS to run") }
        for container in containers {
            try await runAll(in: container)
        }
    }

    private func runAll(in container: String) async throws {
        let exec = ContainerExec(container: container, path: nil)
        _ = try await sh(exec, storeSetup, [id, other, userStep("Reply with only the word ok", at: sent),
                                            userStep("elsewhere", at: sent.addingTimeInterval(6))])
        let root = "/home/u/.gemini/antigravity-cli"
        let files = { try await self.sh(exec, "ls -a \"$1\" \"$1/conversations\"", [root]).stdout }
        let before = try await files()

        // The read, with sqlite3 and then python3 alone.
        for (reader, path) in [("sqlite3", nil), ("python3", "/home/u/nosq")] as [(String, String?)] {
            let readExec = ContainerExec(container: container, path: path)
            let output = try await readExec.run(script: AntigravityRemote.readProgram,
                                                args: ["\(root)/conversations/\(id).db", "\(root)/conversation_summaries.db", id, "1"],
                                                deadline: 30)
            guard case .rows(let opening, let closing, let record)? = AntigravityRemote.parseRead(output.data, id: id) else {
                return XCTFail("\(container) \(reader): \(output.stdout) \(output.stderr)")
            }
            XCTAssertEqual(opening, closing, "\(container) \(reader)")
            XCTAssertEqual(record.ids, [id], "\(container) \(reader)")
            XCTAssertEqual(record.summary?.title, "Replying With Only Ok", "\(container) \(reader)")
            XCTAssertEqual(record.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "Reply with only the word ok",
                           "\(container) \(reader)")
        }
        let after = try await files()
        XCTAssertEqual(after, before, "\(container): nothing written to agy's store")

        // A live writer's log is read through.
        let db = "\(root)/conversations/\(other).db"
        _ = try await sh(exec, #"""
            ( printf 'PRAGMA wal_autocheckpoint=0;\nUPDATE steps SET step_payload = x'"'"'%s'"'"' WHERE idx = 1;\n' "$2"; sleep 20 ) \
              | sqlite3 "$1" >/dev/null 2>&1 &
            i=0; while [ ! -s "$1-wal" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
            """#, [db, userStep("only in the log", at: sent.addingTimeInterval(6))])
        let live = try await exec.run(script: AntigravityRemote.readProgram,
                                      args: [db, "\(root)/conversation_summaries.db", other, "1"], deadline: 30)
        guard case .rows(_, _, let record)? = AntigravityRemote.parseRead(live.data, id: other) else {
            return XCTFail("\(container) live: \(live.stdout) \(live.stderr)")
        }
        XCTAssertEqual(record.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "only in the log", container)

        // Located and read through the source, as enrichment does.
        let provider = RemoteSourceTests.Provider(exec, roots: [.antigravity: RemoteTranscriptRoot(.unset, base: nil)!])
        let source = RemoteSessionSource(host: HostID(rawValue: container), provider: provider)
        let located = try await source.locate([LocateRequest(id: id, agent: .antigravity)])
        let candidate = try XCTUnwrap(located.candidates[id]?.first, container)
        XCTAssertEqual(candidate.locator.path, "\(root)/conversations/\(id).db", container)
        let read = try await source.read(candidate.locator, agent: .antigravity, expecting: id, facts: true)
        XCTAssertEqual(read.identity, .verified, container)
        XCTAssertEqual(read.summary?.titleFact, "Replying With Only Ok", container)
        XCTAssertEqual(read.summary?.cwd, "/home/u/app", container)
        let absent = try await source.lookup(id: "6e8833b0-0a18-4475-a159-f32c998a9f06")
        XCTAssertEqual(absent[.antigravity], .notFound, container)

        // Identity: a real tmux pane whose own process holds the lock; then
        // the same through lsof, as on a host without /proc.
        let pane = try await sh(exec, #"""
            tmux -L temple kill-server 2>/dev/null
            tmux -L temple -f /dev/null new-session -d -s temple-h1 "exec sh -c 'exec 3>>\"\$0\"; exec sleep 120' $1" || exit 3
            sleep 0.5
            p=$(tmux -L temple display-message -p -t '=temple-h1:' '#{pane_pid}')
            s=$(cat /proc/$p/stat); s=${s##*)}; set -- $s; shift 19
            printf '%s %s\n' "$p" "$1"
            """#, ["\(root)/presence/\(id).lock"]).stdout.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let pid = try XCTUnwrap(Int(pane.first ?? ""), container)
        let found = await AntigravityRemote.identify(proc: "/proc", panePID: pid, paneStart: pane.last, socket: nil,
                                                     session: "temple-h1", using: exec)
        XCTAssertEqual(found, .found(id), "\(container) /proc")
        let byLsof = await AntigravityRemote.identify(proc: "/no-proc", panePID: pid, paneStart: nil, socket: nil,
                                                      session: "temple-h1", using: exec)
        XCTAssertEqual(byLsof, .found(id), "\(container) lsof")
        let reused = await AntigravityRemote.identify(proc: "/proc", panePID: pid, paneStart: "1", socket: nil,
                                                      session: "temple-h1", using: exec)
        XCTAssertEqual(reused, .inconclusive(.ended("the session's process has ended")), container)
        _ = try await sh(exec, "tmux -L temple kill-server 2>/dev/null; exit 0")

        // The question's candidates.
        let listing = await AntigravityRemote.list(since: Date(timeIntervalSince1970: 1_795_553_640), using: exec)
        guard case .conversations(_, let conversations) = listing else { return XCTFail("\(container): \(listing)") }
        XCTAssertEqual(Set(conversations.map(\.id)), [id, other], container)
        let candidates = AntigravityRemote.inFolder(conversations, directory: "/home/u/app", declined: [], held: [])
        let fetched = await AntigravityRemote.heads(candidates.map(\.id), using: exec)
        let heads = try XCTUnwrap(fetched, container)
        let offered = AntigravityRemote.eligible(candidates, heads: heads, since: 1_795_553_700,
                                                 until: Date(timeIntervalSince1970: 1_795_557_000))
        XCTAssertEqual(offered?.map(\.sessionID), [id], container)

        // A dead writer's log: read from a copy, and nothing made in the store.
        _ = try await sh(exec, #"""
            d=$HOME/.gemini/antigravity-cli/conversations
            cp "$d/$1.db" /tmp/s.db && rm -f /tmp/s.db-wal /tmp/s.db-shm
            ( printf 'PRAGMA wal_autocheckpoint=0;\nUPDATE steps SET step_payload = x'"'"'%s'"'"' WHERE idx = 1;\n' "$2"; sleep 1 ) \
              | sqlite3 /tmp/s.db >/dev/null 2>&1 &
            i=0; while [ ! -s /tmp/s.db-wal ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
            cp /tmp/s.db-wal "$d/$1.db-wal"; wait
            """#, [id, userStep("from the dead writer", at: sent)])
        let dead = try await files()
        let crashed = try await exec.run(script: AntigravityRemote.readProgram,
                                         args: ["\(root)/conversations/\(id).db", "\(root)/conversation_summaries.db", id, "1"],
                                         deadline: 30)
        guard case .rows(_, _, let deadRecord)? = AntigravityRemote.parseRead(crashed.data, id: id) else {
            return XCTFail("\(container) dead writer: \(crashed.stdout) \(crashed.stderr)")
        }
        XCTAssertEqual(deadRecord.firstUserStep.flatMap(AntigravityFormat.firstPrompt)?.prompt, "from the dead writer", container)
        let afterDead = try await files()
        XCTAssertEqual(afterDead, dead, "\(container): no -shm made beside a dead writer's log")

        // The host test's reader check.
        let reader = await SQLiteReaderCheck.run(using: exec)
        XCTAssertEqual(reader, .found("sqlite3"), container)
        let pythonOnly = await SQLiteReaderCheck.run(using: ContainerExec(container: container, path: "/home/u/nosq"))
        XCTAssertEqual(pythonOnly, .found("python3"), container)
    }
}
