import Foundation
import XCTest
import TempleCore
@testable import TempleRemoteHost

/// Enrichment's source (phase 2) over the local `/bin/sh` stand-in: the
/// locate and read scripts against a temp `HOME`, their framing, the
/// breaker, the coalescing and the concurrency limit, the roots a session's
/// runs decide, and the whole path through `SessionEngine` and
/// `FactPersister` to a filled row. No ssh.
final class RemoteSourceTests: XCTestCase {
    static let host = HostID(rawValue: "box")

    /// A stand-in host: a temp HOME with Claude's and Codex's stores.
    final class Box: @unchecked Sendable {
        let tree = TempTree("temple-enrich")
        var home: String { tree.path + "/home" }
        var extra: [String: String] = [:]
        var path = "/usr/bin:/bin"
        init() {
            _ = tree.directory("home/.claude/projects/-work-project")
            _ = tree.directory("home/.codex/sessions/2026/10/01")
        }
        var environment: [String: String] { hostEnvironment(home: home, path: path, extra: extra) }
        var exec: LocalShellExec { LocalShellExec(path: path, environment: environment) }

        @discardableResult
        func claude(_ id: String, project: String = "-work-project", lines: [String]) -> String {
            let file = tree.write("home/.claude/projects/\(project)/\(id).jsonl", lines.joined(separator: "\n") + "\n")
            return file.path
        }

        @discardableResult
        func codex(_ id: String, stamp: String = "2026-10-01T10-00-00", lines: [String]) -> String {
            let file = tree.write("home/.codex/sessions/2026/10/01/rollout-\(stamp)-\(id).jsonl", lines.joined(separator: "\n") + "\n")
            return file.path
        }

        func shared(_ name: String, _ text: String) { tree.write("home/.codex/\(name)", text) }
    }

    /// Hands over an exec and the login roots (unset: the agents' defaults).
    final class Provider: RemoteTranscriptProvider, @unchecked Sendable {
        private let lock = NSLock()
        var exec: RemoteExec
        var roots: [Agent: RemoteTranscriptRoot]
        private var _failures = 0
        var failures: Int { lock.withLock { _failures } }
        init(_ exec: RemoteExec, roots: [Agent: RemoteTranscriptRoot]? = nil) {
            self.exec = exec
            self.roots = roots ?? [.claude: RemoteTranscriptRoot(.unset, base: nil)!, .codex: RemoteTranscriptRoot(.unset, base: nil)!]
        }
        func transcriptContext(sessionIDs: [String], refresh: Bool) async throws -> RemoteTranscriptContext {
            RemoteTranscriptContext(exec: exec, roots: Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, roots) }))
        }
        func transportFailed() async { lock.withLock { _failures += 1 } }
    }

    /// Records what each exec printed, and how many ran at once.
    final class Watching: RemoteExec, @unchecked Sendable {
        private let lock = NSLock()
        let inner: RemoteExec
        var broken = false
        var delay: Duration = .zero
        private var _outputs: [Data] = []
        private var _calls = 0
        private var _running = 0
        private var _peak = 0
        init(_ inner: RemoteExec) { self.inner = inner }
        var outputs: [Data] { lock.withLock { _outputs } }
        var calls: Int { lock.withLock { _calls } }
        var peak: Int { lock.withLock { _peak } }
        var running: Int { lock.withLock { _running } }
        func run(script: String, args: [String], input: Data?, deadline: TimeInterval) async throws -> RemoteOutput {
            let broken = lock.withLock { () -> Bool in
                _calls += 1; _running += 1; _peak = max(_peak, _running)
                return self.broken
            }
            defer { lock.withLock { _running -= 1 } }
            if delay > .zero { try await Task.sleep(for: delay) }
            if broken {
                return RemoteOutput(status: 255, stdout: "", stderr: "ssh: connect to host box port 22: Connection refused\n",
                                    reachedCommand: false)
            }
            let output = try await inner.run(script: script, args: args, input: input, deadline: deadline)
            lock.withLock { _outputs.append(output.data) }
            return output
        }
    }

    func uuid() -> String { UUID().uuidString.lowercased() }

    func claudeLines(_ id: String, cwd: String = "/work/project", prompt: String = "Fix the build") -> [String] {
        [#"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-01T10:00:00Z","message":{"content":"\#(prompt)"}}"#,
         #"{"type":"assistant","sessionId":"\#(id)","timestamp":"2026-10-01T10:05:00Z","message":{"content":[{"type":"text","text":"done"}]}}"#]
    }

    func codexLines(_ id: String, cwd: String = "/work/project", prompt: String? = "Codex prompt") -> [String] {
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-01T10:00:00Z"}}"#]
        if let prompt { lines.append(#"{"type":"event_msg","payload":{"type":"user_message","message":"\#(prompt)"}}"#) }
        return lines
    }

    // MARK: Locate and read

    func testLocateFindsOnlyTheRequestedIdsAndReadAgreesOnTheSignature() async throws {
        let box = Box()
        let claudeID = uuid(), codexID = uuid(), stranger = uuid()
        let claudePath = box.claude(claudeID, lines: claudeLines(claudeID))
        let codexPath = box.codex(codexID, lines: codexLines(codexID))
        box.claude(stranger, lines: claudeLines(stranger))
        let watching = Watching(box.exec)
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        let result = try await source.locate([LocateRequest(id: claudeID, agent: .claude), LocateRequest(id: codexID)])
        let canonicalClaude = try XCTUnwrap(result.candidates[claudeID]?.first)
        XCTAssertEqual(result.complete, [], "a find over ssh is never an audited listing")
        XCTAssertEqual(canonicalClaude.locator.host, Self.host)
        XCTAssertTrue(canonicalClaude.locator.path.hasSuffix("/.claude/projects/-work-project/\(claudeID).jsonl"))
        XCTAssertEqual(result.candidates[codexID]?.map(\.role), [.selected])
        XCTAssertTrue(try XCTUnwrap(result.candidates[codexID]?.first).locator.path.hasSuffix(URL(fileURLWithPath: codexPath).lastPathComponent))
        _ = claudePath
        // No discovery: the answer never names a session nobody asked for.
        XCTAssertFalse(watching.outputs.contains { String(decoding: $0, as: UTF8.self).contains(stranger) })
        XCTAssertFalse(watching.outputs.contains { $0.range(of: Data(stranger.utf8.map { String(format: "%02x", $0) }.joined().utf8)) != nil })
        let read = try await source.read(canonicalClaude.locator, agent: .claude, expecting: claudeID, facts: true)
        XCTAssertEqual(read.identity, .verified)
        XCTAssertEqual(.present(read.signature), canonicalClaude.stat)
        XCTAssertEqual(read.summary?.firstPrompt, "Fix the build")
        XCTAssertEqual(read.summary?.cwd, "/work/project")
        XCTAssertNotNil(read.summary?.lastEntryAt)
        XCTAssertEqual(read.summary?.locator, canonicalClaude.locator)
        let other = try await source.read(canonicalClaude.locator, agent: .claude, expecting: stranger, facts: true)
        XCTAssertEqual(other.identity, .mismatch)
        XCTAssertNil(other.summary)
    }

    func testCodexReadTakesTheSessionsSharedLinesAndBothRolloutShapesTitle() async throws {
        let box = Box()
        let tui = uuid(), appServer = uuid(), indexed = uuid()
        box.codex(tui, lines: codexLines(tui, prompt: "typed in the TUI"))
        box.codex(appServer, stamp: "2026-10-01T11-00-00", lines: codexLines(appServer, prompt: nil) + [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n</environment_context>"}]}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /work/project\n\nbe brief"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"from the app server"}]}}"#,
        ])
        box.codex(indexed, stamp: "2026-10-01T12-00-00", lines: codexLines(indexed, prompt: "rollout prompt"))
        box.shared("history.jsonl", #"{"session_id":"\#(tui)","ts":5,"text":"history prompt"}"# + "\n"
                   + #"{"session_id":"someone-else","ts":1,"text":"not ours"}"# + "\n")
        box.shared("session_index.jsonl", #"{"id":"\#(indexed)","thread_name":"index name"}"# + "\n")
        let watching = Watching(box.exec)
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        let located = try await source.locate([tui, appServer, indexed].map { LocateRequest(id: $0, agent: .codex) })
        func summary(_ id: String) async throws -> TranscriptSummary? {
            let locator = try XCTUnwrap(located.candidates[id]?.first?.locator)
            return try await source.read(locator, agent: .codex, expecting: id, facts: true).summary
        }
        let a = try await summary(tui)
        XCTAssertEqual(a?.titleFact, "history prompt")
        XCTAssertEqual(a?.historyPrompt, "history prompt")
        let b = try await summary(appServer)
        XCTAssertEqual(b?.firstPrompt, "from the app server")
        let c = try await summary(indexed)
        XCTAssertEqual(c?.titleFact, "index name")
        XCTAssertFalse(watching.outputs.contains { String(decoding: $0, as: UTF8.self).contains("not ours") },
                       "only the session's own lines of the shared inputs travel")
    }

    func testPathsWithNewlinesTabsAndQuotesSurviveAndAWiderHeadIsOneMoreExec() async throws {
        let box = Box()
        let id = uuid(), codexID = uuid()
        let odd = "-we\nird\t'pro\"ject"
        box.claude(id, project: odd, lines: claudeLines(id, cwd: #"/we\nird"#))
        let padding = #"{"type":"response_item","payload":{"role":"user","content":"\#(String(repeating: "x", count: 200_000))"}}"#
        box.codex(codexID, lines: codexLines(codexID, prompt: nil) + [padding, #"{"type":"event_msg","payload":{"type":"user_message","message":"deep prompt"}}"#])
        let watching = Watching(box.exec)
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        let located = try await source.locate([LocateRequest(id: id, agent: .claude), LocateRequest(id: codexID, agent: .codex)])
        let locator = try XCTUnwrap(located.candidates[id]?.first?.locator)
        XCTAssertTrue(locator.path.contains("/\(odd)/"), locator.path)
        let read = try await source.read(locator, agent: .claude, expecting: id, facts: true)
        XCTAssertEqual(read.summary?.cwd, "/we\nird")
        let before = watching.calls
        let codex = try XCTUnwrap(located.candidates[codexID]?.first?.locator)
        let deep = try await source.read(codex, agent: .codex, expecting: codexID, facts: true)
        XCTAssertEqual(deep.summary?.firstPrompt, "deep prompt")
        XCTAssertEqual(watching.calls - before, 2, "the read, then one wider head")
        XCTAssertEqual(source.counters.widerReads, 1)
    }

    func testAHintIsStatedAndAMissingOneIsNoCandidate() async throws {
        let box = Box()
        let id = uuid()
        let source = RemoteSessionSource(host: Self.host, provider: Provider(box.exec))
        let first = try await source.locate([LocateRequest(id: id, agent: .claude)])
        XCTAssertEqual(first.candidates[id], [])
        // The row's recorded path, somewhere the listing doesn't reach (a
        // deeper folder), is a candidate while its file is there.
        let canonicalHome = box.home   // /private/tmp/…: already canonical
        let deep = box.tree.write("home/.claude/projects/-a/deeper/\(id).jsonl", claudeLines(id).joined(separator: "\n"))
        let hint = TranscriptLocator(host: Self.host, path: canonicalHome + "/.claude/projects/-a/deeper/\(id).jsonl")
        let hinted = try await source.locate([LocateRequest(id: id, agent: .claude, hint: hint)])
        XCTAssertEqual(hinted.candidates[id]?.map(\.locator), [hint])
        XCTAssertEqual(hinted.candidates[id]?.map(\.role), [.hinted])
        try FileManager.default.removeItem(at: deep)
        let gone = try await source.locate([LocateRequest(id: id, agent: .claude, hint: hint)])
        XCTAssertEqual(gone.candidates[id], [], "a hint whose file is gone is no candidate")
        // A hint outside the session's store is not looked at.
        let outside = TranscriptLocator(host: Self.host, path: canonicalHome + "/elsewhere/\(id).jsonl")
        box.tree.write("home/elsewhere/\(id).jsonl", claudeLines(id).joined(separator: "\n"))
        let ignored = try await source.locate([LocateRequest(id: id, agent: .claude, hint: outside)])
        XCTAssertEqual(ignored.candidates[id], [])
    }

    /// A store folder that is a link is followed, as the local store
    /// resolves its root; a Codex file name in capitals is the same thread,
    /// as `CodexFormat.name` reads it.
    func testALinkedStoreIsListedAndCodexNamesMatchInAnyCase() async throws {
        let box = Box()
        let id = uuid(), upper = uuid()
        let elsewhere = box.tree.directory("disk/sessions")
        try FileManager.default.removeItem(atPath: box.home + "/.codex/sessions")
        try FileManager.default.createSymbolicLink(atPath: box.home + "/.codex/sessions", withDestinationPath: elsewhere.path)
        box.tree.write("disk/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(id).jsonl", codexLines(id).joined(separator: "\n"))
        box.tree.write("disk/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(upper.uppercased()).jsonl",
                       codexLines(upper).joined(separator: "\n"))
        let source = RemoteSessionSource(host: Self.host, provider: Provider(box.exec))
        let found = try await source.locate([LocateRequest(id: id, agent: .codex), LocateRequest(id: upper, agent: .codex)])
        let locator = try XCTUnwrap(found.candidates[id]?.first?.locator)
        XCTAssertTrue(locator.path.hasPrefix(box.home + "/.codex/sessions/"), locator.path)
        let read = try await source.read(locator, agent: .codex, expecting: id, facts: true)
        XCTAssertEqual(read.summary?.firstPrompt, "Codex prompt")
        let shouting = try XCTUnwrap(found.candidates[upper]?.first)
        XCTAssertEqual(shouting.role, .selected)
        XCTAssertTrue(shouting.locator.path.hasSuffix(upper.uppercased() + ".jsonl"))
        let verified = try await source.read(shouting.locator, agent: .codex, expecting: upper, facts: false)
        XCTAssertEqual(verified.identity, .verified)
    }

    func testRootsAreResolvedOnTheHostAndAnUnknownOneIsNotSearched() async throws {
        let box = Box()
        let id = uuid()
        // A config root whose name ends in a newline, set absolutely.
        let odd = box.tree.directory("home/conf\n")
        _ = box.tree.directory("home/conf\n/projects/-p")
        box.tree.write("home/conf\n/projects/-p/\(id).jsonl", claudeLines(id).joined(separator: "\n"))
        let set = try XCTUnwrap(RemoteTranscriptRoot(.set(odd.path), base: nil))
        let source = RemoteSessionSource(host: Self.host, provider: Provider(box.exec, roots: [.claude: set]))
        let found = try await source.locate([LocateRequest(id: id, agent: .claude)])
        let path = try XCTUnwrap(found.candidates[id]?.first?.locator.path)
        XCTAssertTrue(path.contains("/conf\n/projects/-p/"), path)
        // Relative to a run's folder.
        let relative = try XCTUnwrap(RemoteTranscriptRoot(.set("conf\n"), base: box.home))
        let viaBase = RemoteSessionSource(host: Self.host, provider: Provider(box.exec, roots: [.claude: relative]))
        let again = try await viaBase.locate([LocateRequest(id: id, agent: .claude)])
        XCTAssertEqual(again.candidates[id]?.first?.locator.path, path)
        // Unknown roots: never searched, never a guess.
        XCTAssertNil(RemoteTranscriptRoot(.set(""), base: box.home))
        XCTAssertNil(RemoteTranscriptRoot(.set("conf"), base: nil))
        XCTAssertNil(RemoteTranscriptRoot(nil, base: box.home))
        let watching = Watching(box.exec)
        let blind = RemoteSessionSource(host: Self.host, provider: Provider(watching, roots: [:]))
        let nothing = try await blind.locate([LocateRequest(id: id)])
        XCTAssertEqual(nothing.candidates[id], [])
    }

    func testReadsAreTypedAndAFileThatKeepsChangingIsNotReported() async throws {
        let box = Box()
        let id = uuid(), locked = uuid()
        let path = box.claude(id, lines: claudeLines(id))
        let lockedPath = box.claude(locked, lines: claudeLines(locked))
        let source = RemoteSessionSource(host: Self.host, provider: Provider(box.exec))
        let located = try await source.locate([LocateRequest(id: id, agent: .claude), LocateRequest(id: locked, agent: .claude)])
        let locator = try XCTUnwrap(located.candidates[id]?.first?.locator)
        let lockedLocator = try XCTUnwrap(located.candidates[locked]?.first?.locator)
        chmod(lockedPath, 0o000)
        defer { chmod(lockedPath, 0o600) }
        do { _ = try await source.read(lockedLocator, agent: .claude, expecting: locked, facts: false); XCTFail() } catch {
            guard case .unreadable? = error as? TranscriptReadError else { return XCTFail("\(error)") }
        }
        // `head` that appends to the file after reading it: every read
        // straddles a change.
        let stubs = box.tree.directory("stubs")
        box.tree.write("stubs/head", "#!/bin/sh\n/usr/bin/head \"$@\"; s=$?\nprintf '\\n{}' >> \(RemoteQuoting.quote(path))\nexit $s\n",
                       executable: true)
        box.path = stubs.path + ":/usr/bin:/bin"
        let churning = RemoteSessionSource(host: Self.host, provider: Provider(box.exec))
        do { _ = try await churning.read(locator, agent: .claude, expecting: id, facts: true); XCTFail() } catch {
            XCTAssertEqual(error as? TranscriptReadError, .changedDuringRead)
        }
        try FileManager.default.removeItem(atPath: path)
        do { _ = try await source.read(locator, agent: .claude, expecting: id, facts: false); XCTFail() } catch {
            XCTAssertEqual(error as? TranscriptReadError, .missing)
        }
    }

    // MARK: Breaker, coalescing, concurrency

    func testTheBreakerStopsSpawningAfterThreeTransportFailuresAndAnExplicitOpenGetsThroughOnce() async throws {
        let box = Box()
        let id = uuid()
        box.claude(id, lines: claudeLines(id))
        let watching = Watching(box.exec)
        watching.broken = true
        let provider = Provider(watching)
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let source = RemoteSessionSource(host: Self.host, provider: provider, now: { clock.now })
        for _ in 0..<3 {
            do { _ = try await source.locate([LocateRequest(id: id)]); XCTFail("transport failure is thrown") } catch {
                guard case .transport? = error as? LocateError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(watching.calls, 3)
        XCTAssertEqual(provider.failures, 3, "each failure resets the host's environment")
        // Open: nothing spawns, and the answer says why and until when.
        do { _ = try await source.locate([LocateRequest(id: id)]); XCTFail() } catch let LocateError.transport(words) {
            XCTAssertTrue(words.hasPrefix("box unreachable since "), words)
            XCTAssertTrue(words.contains("; next try at "), words)
        }
        let locator = TranscriptLocator(host: Self.host, path: box.home + "/.claude/projects/-work-project/\(id).jsonl")
        do { _ = try await source.read(locator, agent: .claude, expecting: id, facts: true); XCTFail() } catch {
            guard case .transport? = error as? TranscriptReadError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(watching.calls, 3, "an open breaker spawns nothing")
        // An explicit open bypasses it once; still failing, it stays open.
        _ = try? await source.locate([LocateRequest(id: id, refresh: true)])
        XCTAssertEqual(watching.calls, 4)
        _ = try? await source.locate([LocateRequest(id: id)])
        XCTAssertEqual(watching.calls, 4)
        // Ten minutes on, it tries again; a success closes it and moves coverage.
        clock.now = clock.now.addingTimeInterval(10 * 60 + 1)
        watching.broken = false
        let found = try await source.locate([LocateRequest(id: id)])
        XCTAssertEqual(found.candidates[id]?.count, 1)
        XCTAssertEqual(found.coverage, 2, "the first listing after a transport failure moves coverage")
        let next = try await source.locate([LocateRequest(id: id)])
        XCTAssertEqual(next.coverage, 2)
        XCTAssertEqual(source.counters.refused, 3)
    }

    func testLocatesWithin250msShareOneExecAndAtMostTwoExecsRunAtOnce() async throws {
        let box = Box()
        let ids = (0..<6).map { _ in uuid() }
        for id in ids { box.claude(id, lines: claudeLines(id)) }
        let watching = Watching(box.exec)
        let source = RemoteSessionSource(host: Self.host, provider: Provider(watching))
        async let a = source.locate([LocateRequest(id: ids[0])])
        try await Task.sleep(for: .milliseconds(50))
        async let b = source.locate([LocateRequest(id: ids[1]), LocateRequest(id: ids[2])])
        let (first, second) = try await (a, b)
        XCTAssertEqual(watching.calls, 1, "one exec for both")
        XCTAssertEqual(Set(first.candidates.keys), [ids[0]])
        XCTAssertEqual(Set(second.candidates.keys), [ids[1], ids[2]])
        XCTAssertEqual(second.candidates[ids[2]]?.count, 1)
        let all = try await source.locate(ids.map { LocateRequest(id: $0, agent: .claude) })
        watching.delay = .milliseconds(150)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                let locator = try XCTUnwrap(all.candidates[id]?.first?.locator)
                group.addTask { _ = try await source.read(locator, agent: .claude, expecting: id, facts: true) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(watching.peak, 2)
    }

    /// A quit cancels the listing in flight (its process is killed, not
    /// left to run into exit), and a cancellation is not a transport failure.
    func testShutDownCancelsTheListingInFlight() async throws {
        let box = Box()
        let watching = Watching(box.exec)
        watching.delay = .seconds(10)
        let provider = Provider(watching)
        let source = RemoteSessionSource(host: Self.host, provider: provider)
        let started = Date()
        let locate = Task { try await source.locate([LocateRequest(id: uuid())]) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(watching.calls, 1)
        await source.shutDown()
        do { _ = try await locate.value; XCTFail("cancelled") } catch {
            guard case .transport? = error as? LocateError else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(provider.failures, 0)
        do { _ = try await source.locate([LocateRequest(id: uuid())]); XCTFail() } catch {
            guard case .transport? = error as? LocateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(watching.calls, 1, "nothing after the quit")
    }

    /// A caller that goes away is answered at once; a batch nobody waits
    /// for any more is cancelled, its exec with it.
    func testACancelledLocateIsAnsweredAndAnAbandonedBatchStops() async throws {
        let box = Box()
        let watching = Watching(box.exec)
        watching.delay = .seconds(10)
        let provider = Provider(watching)
        let source = RemoteSessionSource(host: Self.host, provider: provider)
        let started = Date()
        let locate = Task { try await source.locate([LocateRequest(id: uuid())]) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(watching.calls, 1, "listing")
        locate.cancel()
        do { _ = try await locate.value; XCTFail("cancelled") } catch {
            XCTAssertEqual(error as? LocateError, .transport("the lookup was cancelled"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(watching.running, 0, "the abandoned batch's exec was cancelled")
        XCTAssertEqual(provider.failures, 0, "a cancellation is not a transport failure")
        // Collecting: cancelled before its listing, nothing runs at all.
        let early = Task { try await source.locate([LocateRequest(id: uuid())]) }
        try await Task.sleep(for: .milliseconds(50))
        early.cancel()
        _ = try? await early.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(watching.calls, 1, "nothing listed for nobody")
    }

    // MARK: Framing

    func testFramingIsStrict() throws {
        let stat = "stat\t5\t1.5\t9\n"
        let good = Data((stat + "head\t2\nab\nend\n" + stat + "done\n").utf8)
        guard case .bytes(let read)? = RemoteTranscripts.parseRead(good) else { return XCTFail() }
        XCTAssertEqual(read.head, Data("ab".utf8))
        XCTAssertNil(RemoteTranscripts.parseRead(good + Data("x".utf8)), "leftover bytes")
        XCTAssertNil(RemoteTranscripts.parseRead(Data((stat + "head\t2\nab\nend\n" + stat).utf8)), "no done")
        XCTAssertNil(RemoteTranscripts.parseRead(Data((stat + "head\t9223372036854775807\nab\nend\n" + stat + "done\n").utf8)))
        XCTAssertNil(RemoteTranscripts.parseRead(Data((stat + "head\t3\nab\nend\n" + stat + "done\n").utf8)))
        XCTAssertNil(RemoteTranscripts.parseRead(Data((stat + "head\t-1\n\nend\n" + stat + "done\n").utf8)))
        XCTAssertEqual(RemoteTranscripts.parseRead(Data("missing\n".utf8)), .missing)
        XCTAssertNil(RemoteTranscripts.parseRead(Data("missing\nx".utf8)))
        // Bytes that aren't text survive.
        let binary = Data(stat.utf8) + Data("head\t3\n".utf8) + Data([0x00, 0xff, 0x0a]) + Data(("\nend\n" + stat + "done\n").utf8)
        guard case .bytes(let raw)? = RemoteTranscripts.parseRead(binary) else { return XCTFail() }
        XCTAssertEqual(raw.head, Data([0x00, 0xff, 0x0a]))

        let hex = { (s: String) in Data(s.utf8).map { String(format: "%02x", $0) }.joined() }
        let list = hex("3\t1.0\t7\t/r/projects/-p/a.jsonl") + "00" + hex("S0")
        let locate = "root\t0\tok\t\(hex("/r"))\nlist\t0\t\(list)\ndone\n"
        XCTAssertEqual(RemoteTranscripts.parseLocate(Data(locate.utf8), groups: 1)?.lists[0]??.map(\.path), ["/r/projects/-p/a.jsonl"])
        XCTAssertNil(RemoteTranscripts.parseLocate(Data(locate.utf8), groups: 2), "every group answered")
        XCTAssertNil(RemoteTranscripts.parseLocate(Data((locate + "x").utf8), groups: 1))
        XCTAssertNil(RemoteTranscripts.parseLocate(Data(locate.dropLast(5).utf8), groups: 1))
        let failed = "root\t0\tok\t\(hex("/r"))\nlist\t0\t\(hex("S1"))\ndone\n"
        XCTAssertEqual(RemoteTranscripts.parseLocate(Data(failed.utf8), groups: 1)?.lists[0], .some(nil),
                       "a listing that failed lists nothing, not part of something")
    }

    // MARK: Roots from runs

    @MainActor
    func testASessionsRunsDecideItsRootAndOnlyARowWithoutRunsUsesTheLoginOne() async throws {
        let box = Box()
        let store = try RemoteStateStore()
        let sessions = RemoteSessions(record: .config("box"), stateDirectory: box.tree.url, sshPath: "/usr/bin/ssh",
                                      store: { store }, resolve: { _ in .resolved(["hostname": "box", "user": "u", "port": "22"]) },
                                      makeExec: { _, path, _ in LocalShellExec(path: path, environment: box.environment) },
                                      masterCheck: { _ in false })
        func run(_ handle: String, session: String, config: RemoteEnvironment.ClaudeConfig?, directory: String? = "/work",
                 dismissed: Bool = false) throws {
            var run = RemoteRun(handle: handle, host: Self.host, agent: .claude, mode: .new, directoryIntent: "/work",
                                sessionID: session, recordPath: RecordDirectory.locator(marker: "r-\(handle)"), startedAt: Date())
            run.claudeConfig = config
            run.directory = directory
            if dismissed { run.dismissedAt = Date() }
            try store.insert(run)
        }
        try run("h1", session: "s-run", config: .set("/elsewhere"))
        try run("h2", session: "s-blind", config: nil)
        try run("h3", session: "s-rel", config: .set("conf"), directory: "/work/dir")
        let context = try await sessions.transcriptContext(sessionIDs: ["s-run", "s-blind", "s-rel", "s-row"], refresh: false)
        XCTAssertEqual(context.roots["s-run"]?[.claude], RemoteTranscriptRoot(.set("/elsewhere"), base: nil))
        XCTAssertEqual(context.roots["s-run"]?[.codex], nil)
        XCTAssertEqual(context.roots["s-blind"], [:], "a run with no evidence: unknown, never the login root")
        XCTAssertEqual(context.roots["s-rel"]?[.claude], RemoteTranscriptRoot(.set("/work/dir/conf"), base: nil))
        // No run: the login environment's (unset here: the defaults).
        XCTAssertEqual(context.roots["s-row"]?[.claude], RemoteTranscriptRoot(.unset, base: nil))
        XCTAssertEqual(context.roots["s-row"]?[.codex], RemoteTranscriptRoot(.unset, base: nil))
    }

    // MARK: End to end

    /// A remote row with no title, folder or date fills from its transcript
    /// through the engine and the persister (NULL-only, under the
    /// membership); a row whose transcript isn't there is never absent.
    func testARemoteRowFillsFromItsTranscriptThroughTheEngine() async throws {
        let box = Box()
        let id = uuid(), missing = uuid(), titled = uuid()
        box.claude(id, lines: claudeLines(id, cwd: "/work/project", prompt: "Fill me in"))
        box.claude(titled, lines: claudeLines(titled, prompt: "Not this title"))
        let db = try TempleDB.inMemory()
        try db.join(sessionID: id, via: .opened, agent: .claude, core: SessionCore(host: Self.host))
        try db.join(sessionID: missing, via: .opened, agent: .claude, core: SessionCore(host: Self.host))
        try db.join(sessionID: titled, via: .opened, agent: .claude, core: SessionCore(host: Self.host, title: "Mine"))
        let source = RemoteSessionSource(host: Self.host, provider: Provider(box.exec))
        let engine = SessionEngine(source: source, database: db)
        let committer = FactCommitter(database: db)
        let stream = engine.snapshots()
        let loop = Task { await committer.consume(stream, retryEvery: .milliseconds(50), onSnapshot: { _ in }) }
        defer { loop.cancel() }
        await engine.start()
        defer { Task { await engine.stop() } }
        let deadline = Date().addingTimeInterval(20)
        while try db.sessionState(id)?.title == nil || (try db.sessionState(titled)?.directory) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let row = try XCTUnwrap(try db.sessionState(id))
        XCTAssertEqual(row.title, "Fill me in")
        XCTAssertEqual(row.directory, "/work/project")
        XCTAssertNotNil(row.lastActiveAt)
        XCTAssertEqual(row.host, Self.host)
        XCTAssertTrue(row.transcriptPath?.hasSuffix("/\(id).jsonl") == true)
        XCTAssertEqual(try db.sessionState(titled)?.title, "Mine", "fills are NULL-only")
        try await Task.sleep(for: .milliseconds(300))
        let resolution = engine.latestSnapshot?.resolutions[missing]
        XCTAssertNotEqual(resolution, .confirmedAbsent, "a remote row is never absent")
        XCTAssertNil(try db.sessionState(missing)?.title)
    }
}
