import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Phase 2's acceptance (enrichment), opt-in like the rest:
///
///     TEMPLE_REMOTE_ACCEPTANCE=masterblaster-mentes,jetson-mentes swift test --filter LinuxAcceptanceTests/testPhase2
///
/// On each box: a real Claude transcript (`claude -p … --session-id`) and a
/// real Codex rollout (`codex exec`), made in a temp folder under /tmp
/// there; rows for them on that host with no title, folder or date; the
/// real engine over `RemoteSessionSource` (the box's own GNU find, sh and
/// coreutils, over ssh) fills them through `FactPersister`. A box whose
/// claude is not logged in leaves no Claude transcript: that half is
/// logged as incomplete, not passed. Removed afterwards: the temp folder,
/// Claude's project folder for it, and the rollout this test made (Codex's
/// history and index lines stay, as Codex wrote them). Then a host that
/// refuses connections trips the breaker: three transport failures, then
/// nothing spawned.
extension LinuxAcceptanceTests {
    @MainActor
    func testPhase2EnrichmentOnEachHost() async throws {
        guard !hosts.isEmpty else { throw XCTSkip("set TEMPLE_REMOTE_ACCEPTANCE=<alias>[,<alias>] to run") }
        for name in hosts {
            precondition(name.hasSuffix("-mentes"), "acceptance runs only against the -mentes agent accounts")
            try await enrichment(name)
        }
        try await unreachableBreaker()
    }

    @MainActor
    private func enrichment(_ name: String) async throws {
        let state = TempTree("acceptance-p2")
        var log: [String] = ["== \(name) (phase 2)"]
        defer { print(log.joined(separator: "\n")) }
        let host = HostID(rawValue: name)
        let store = try RemoteStateStore(directory: state.url)
        let sessions = RemoteSessions(record: .config(name), stateDirectory: state.url, sshPath: "/usr/bin/ssh", store: { store })
        let exec = try await sessions.queryExec()
        func sh(_ script: String, _ args: [String] = [], deadline: TimeInterval = 30) async throws -> String {
            let out = try await exec.run(script: script, args: args, deadline: deadline)
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let folder = try await sh("mktemp -d /tmp/temple-accept-p2-XXXXXX")
        XCTAssertTrue(folder.hasPrefix("/tmp/temple-accept-p2-"), folder)
        let canonical = try await sh("cd -- \"$1\" && pwd -P", [folder])
        var rollouts: [String] = []
        defer {
            let cleanup = """
            f=$1; c=$2; shift 2
            case $f in /tmp/temple-accept-p2-*) rm -rf -- "$f" ;; esac
            enc=$(printf '%s' "$c" | sed 's|[/.]|-|g')
            [ -n "$enc" ] && rm -rf -- "$HOME/.claude/projects/$enc"
            for r; do case $r in "$HOME"/.codex/sessions/*/rollout-*.jsonl) rm -f -- "$r" ;; esac; done
            true
            """
            let semaphore = DispatchSemaphore(value: 0)
            let all = rollouts
            Task.detached {
                _ = try? await exec.run(script: cleanup, args: [folder, canonical] + all, deadline: 20)
                semaphore.signal()
            }
            semaphore.wait()
        }

        // A real Claude transcript, in print mode, under a known id.
        let claudeID = UUID().uuidString.lowercased()
        let claudeRun = try await sh("""
        cd -- "$1" || exit 1
        out=$(claude -p 'Reply with the single word ok' --session-id "$2" </dev/null 2>&1); s=$?
        printf 'exit=%s %s\\n' "$s" "$(printf '%s' "$out" | head -n 1)"
        ls "$HOME"/.claude/projects/*/"$2".jsonl 2>/dev/null | head -n 1
        """, [folder, claudeID], deadline: 180)
        let claudeLines = claudeRun.split(separator: "\n").map(String.init)
        let claudeMade = claudeLines.count > 1
        let claudeStatus = claudeLines.first ?? "(nothing)"
        // The one limitation allowed: a claude that isn't logged in (jetson).
        // Anything else that leaves no transcript is a failure.
        let loggedOut = claudeStatus.localizedCaseInsensitiveContains("not logged in")
            || claudeStatus.localizedCaseInsensitiveContains("/login")
        log.append("claude -p: \(claudeStatus); transcript: \(claudeMade ? claudeLines[1] : "none")")
        if !claudeMade {
            XCTAssertTrue(loggedOut, "\(name): claude left no transcript, and not for want of a login: \(claudeStatus)")
        }
        XCTAssertTrue(claudeStatus.hasPrefix("exit=0") || loggedOut, "\(name): \(claudeStatus)")

        // A real Codex rollout; its id is in exec's header.
        let codexRun = try await sh("""
        cd -- "$1" || exit 1
        codex exec --skip-git-repo-check 'Reply with the single word ok' </dev/null 2>&1 | grep -m 1 -i 'session id:'
        """, [folder], deadline: 240)
        let codexID = codexRun.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        log.append("codex exec: \(codexRun.isEmpty ? "(no session id printed)" : codexRun)")
        XCTAssertTrue(RemoteQuoting.isSafeToken(codexID), "\(name): codex printed its session id")
        let rollout = try await sh("find \"$HOME/.codex/sessions\" -name \"rollout-*-$1.jsonl\" | head -n 1", [codexID])
        if !rollout.isEmpty { rollouts.append(rollout) }
        log.append("rollout: \(rollout.isEmpty ? "none" : rollout)")

        // Rows on this host that lack a title, a folder and a date.
        let db = try TempleDB.inMemory()
        var ids: [(String, Agent)] = [(codexID, .codex)]
        if claudeMade { ids.append((claudeID, .claude)) }
        for (id, agent) in ids {
            try db.join(sessionID: id, via: .opened, agent: agent, core: SessionCore(host: host))
        }
        let missing = UUID().uuidString.lowercased()
        try db.join(sessionID: missing, via: .opened, agent: .claude, core: SessionCore(host: host))
        let source = RemoteSessionSource(sessions: sessions)
        let engine = SessionEngine(source: source, database: db)
        let committer = FactCommitter(database: db)
        let stream = engine.snapshots()
        let loop = Task { await committer.consume(stream, retryEvery: .milliseconds(200), onSnapshot: { _ in }) }
        let started = Date()
        await engine.start()
        let deadline = Date().addingTimeInterval(90)
        func filled() throws -> Bool {
            try ids.allSatisfy { id, _ in try db.sessionState(id)?.title != nil && db.sessionState(id)?.lastActiveAt != nil }
        }
        while try !filled(), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        let elapsed = Date().timeIntervalSince(started)
        for (id, agent) in ids {
            let row = try XCTUnwrap(try db.sessionState(id), "\(name): \(agent) row")
            log.append("\(agent.rawValue) row filled in \(String(format: "%.1f", elapsed)) s: title=\(row.title ?? "nil") "
                       + "directory=\(row.directory ?? "nil") lastActive=\(row.lastActiveAt.map { "\($0)" } ?? "nil") "
                       + "transcript=\(row.transcriptPath ?? "nil")")
            XCTAssertNotNil(row.title, "\(name): \(agent) title")
            XCTAssertEqual(row.directory, canonical, "\(name): \(agent) folder")
            XCTAssertNotNil(row.lastActiveAt, "\(name): \(agent) date")
            XCTAssertEqual(row.host, host)
        }
        if loggedOut {
            log.append("Claude: INCOMPLETE on \(name): claude is not logged in, so no conversation; "
                       + (claudeMade ? "the transcript it wrote anyway (its login error) filled the row"
                                     : "it wrote no transcript"))
        }
        try await Task.sleep(for: .milliseconds(500))
        let absent = engine.latestSnapshot?.resolutions[missing]
        log.append("row with no transcript: \(absent.map { "\($0)" } ?? "nil") (never confirmedAbsent)")
        XCTAssertNotEqual(absent, .confirmedAbsent)
        let counters = source.counters
        log.append("source: \(counters.listings) listing exec(s), \(counters.reads) read exec(s), \(counters.widerReads) wider")
        await engine.shutDown()
        loop.cancel()

        // This box's sh and find on the edges, under roots inside the temp
        // folder (nothing of the account's own stores is touched): a
        // transcript that is a link is unreadable in the listing and in a
        // read; shared lines past the response budget are that session's
        // `.unreadable`, decided before anything is printed, and charge
        // nothing to the host.
        let edgeID = UUID().uuidString.lowercased()
        let made = try await sh("""
        f=$1; id=$2
        mkdir -p "$f/cdx/sessions/2026/10/16" "$f/cfg/projects/-p" || exit 1
        printf '{"type":"session_meta","payload":{"id":"%s","cwd":"/w","timestamp":"2026-10-16T10:00:00Z"}}\n' "$id" \
          > "$f/cdx/sessions/2026/10/16/rollout-2026-10-16T10-00-00-$id.jsonl"
        i=0; while [ $i -lt 300 ]; do
          printf '{"session_id":"%s","ts":1,"text":"%01000d"}\n' "$id" 0; i=$((i+1)); done > "$f/cdx/history.jsonl"
        printf '{"type":"user","sessionId":"%s","message":{"content":"x"}}\n' "$id" > "$f/real.jsonl"
        ln -s "$f/real.jsonl" "$f/cfg/projects/-p/$id.jsonl" && echo made
        """, [canonical, edgeID])
        XCTAssertEqual(made, "made", name)
        struct Fixed: RemoteTranscriptProvider {
            let exec: RemoteExec
            let roots: [Agent: RemoteTranscriptRoot]
            func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext {
                RemoteTranscriptContext(exec: exec, roots: Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, roots) }))
            }
            func transportFailed() async {}
        }
        let edges = RemoteSessionSource(host: host, provider: Fixed(exec: exec, roots: [
            .claude: try XCTUnwrap(RemoteTranscriptRoot(.set(canonical + "/cfg"), base: nil)),
            .codex: try XCTUnwrap(RemoteTranscriptRoot(.set(canonical + "/cdx"), base: nil)),
        ]), now: { Date() }, responseBudget: 128 * 1024)
        let edge = try await edges.locate([LocateRequest(id: edgeID)])
        let linkStat = edge.candidates[edgeID]?.first { $0.agent == .claude }?.stat
        XCTAssertEqual(linkStat, .unreadable, "\(name): a linked transcript")
        let edgeRollout = try XCTUnwrap(edge.candidates[edgeID]?.first { $0.agent == .codex }?.locator, name)
        do { _ = try await edges.read(edgeRollout, agent: .codex, expecting: edgeID, facts: true); XCTFail(name) } catch {
            log.append("edges: link \(linkStat.map { "\($0)" } ?? "nil"); oversized shared lines: \(error)")
            guard case .unreadable? = error as? TranscriptReadError else { return XCTFail("\(name): \(error)") }
        }
        XCTAssertEqual(edges.counters.refused, 0)
    }

    /// A host that refuses connections: three transport failures, then the
    /// breaker answers without spawning ssh; an explicit open gets one try.
    @MainActor
    private func unreachableBreaker() async throws {
        let state = TempTree("acceptance-p2-breaker")
        let record = RemoteHostRecord(name: "unreachable-mentes", source: .temple, address: "127.0.0.1", user: "nobody", port: 1)
        let store = try RemoteStateStore(directory: state.url)
        let sessions = RemoteSessions(record: record, stateDirectory: state.url, sshPath: "/usr/bin/ssh", store: { store })
        let source = RemoteSessionSource(sessions: sessions)
        var lines = ["== unreachable host (127.0.0.1 port 1)"]
        defer { print(lines.joined(separator: "\n")) }
        let id = UUID().uuidString.lowercased()
        for attempt in 1...3 {
            let started = Date()
            do { _ = try await source.locate([LocateRequest(id: id)]); XCTFail("unreachable") } catch {
                lines.append("locate \(attempt): \(error) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
                guard case .transport? = error as? LocateError else { return XCTFail("\(error)") }
            }
        }
        let spawned = RemoteProcessCounter.launches
        do { _ = try await source.locate([LocateRequest(id: id)]); XCTFail("open breaker") } catch let LocateError.transport(words) {
            lines.append("locate 4: \(words)")
            XCTAssertTrue(words.hasPrefix("unreachable-mentes unreachable since "), words)
        }
        let locator = TranscriptLocator(host: record.host, path: "/home/nobody/.claude/projects/-p/\(id).jsonl")
        do { _ = try await source.read(locator, agent: .claude, expecting: id, facts: true); XCTFail() } catch {
            lines.append("read: \(error)")
        }
        XCTAssertEqual(RemoteProcessCounter.launches, spawned, "an open breaker spawns nothing")
        _ = try? await source.locate([LocateRequest(id: id, refresh: true)])
        XCTAssertGreaterThan(RemoteProcessCounter.launches, spawned, "an explicit open gets through once")
        lines.append("explicit open spawned \(RemoteProcessCounter.launches - spawned) process(es); counters: \(source.counters)")
    }
}
