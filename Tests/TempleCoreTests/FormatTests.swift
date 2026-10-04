import XCTest
@testable import TempleCore

/// The agent formats as pure functions: no file is opened here.
final class FormatTests: XCTestCase {
    private let codex = CodexFormat()
    private let claude = ClaudeFormat()
    private let thread = "0199a213-81c0-7800-8aa1-bbab2a035a53"
    private let revertID = "0199a213-81c0-7800-8aa1-bbab2a0aaaaa"

    private func lines(_ text: String...) -> [Data] { text.map { Data($0.utf8) } }
    private func bytes(_ text: String) -> TranscriptBytes {
        let data = Data(text.utf8)
        return TranscriptBytes(head: data, tail: nil, fileSize: data.count)
    }
    private func summary(_ facts: TranscriptFacts, file: StaticString = #filePath, line: UInt = #line) throws -> TranscriptSummary {
        guard case .summary(let summary) = facts else {
            XCTFail("expected a summary, got \(facts)", file: file, line: line)
            throw CancellationError()
        }
        return summary
    }
    private func locator(_ path: String) -> TranscriptLocator { TranscriptLocator(host: HostID(rawValue: "box"), path: path) }

    // MARK: Names and selection

    func testCodexNamesCarryTheThreadAndTheRevertSelectionKey() {
        let canonical = codex.name(path: "/r/sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(thread).jsonl")
        XCTAssertEqual(canonical, TranscriptName(threadID: thread, selectionKey: "2026-10-01T10-00-00-\(thread)"))
        let revert = codex.name(path: "rollout-2026-10-01T09-00-00-\(thread.uppercased())_\(revertID).jsonl")
        XCTAssertEqual(revert, TranscriptName(threadID: thread, selectionKey: "2026-10-01T09-00-00-\(revertID)"))
        for bad in ["rollout-codex.jsonl", "rollout-2026-02-30T10-00-00-\(thread).jsonl",
                    "rollout-2026-10-01T24-00-00-\(thread).jsonl", "rollout-2026-10-01T10-00-00-\(thread).json",
                    "rollout-2026-10-01T10-00-00-\(thread)_\(thread)_\(thread).jsonl"] {
            XCTAssertNil(codex.name(path: bad), bad)
        }
        XCTAssertEqual(claude.name(path: "/p/-work/abc.jsonl"), TranscriptName(threadID: "abc"))
        XCTAssertNil(claude.name(path: "/p/-work/abc.txt"))
        XCTAssertNil(claude.name(path: ".jsonl"))
    }

    func testCodexSelectsTheHighestKeyWithTheLaterPathBreakingTies() {
        let older = ("/a/rollout-old", TranscriptName(threadID: thread, selectionKey: "2026-10-01T09-00-00-a"))
        let newer = ("/a/rollout-new", TranscriptName(threadID: thread, selectionKey: "2026-10-01T10-00-00-a"))
        let tieLow = ("/a/x", TranscriptName(threadID: thread, selectionKey: "2026-10-01T10-00-00-a"))
        XCTAssertEqual(codex.select([older, newer].map { (path: $0.0, name: $0.1) }), "/a/rollout-new")
        XCTAssertEqual(codex.select([newer, tieLow].map { (path: $0.0, name: $0.1) }), "/a/x")
        XCTAssertEqual(codex.select([tieLow, newer].map { (path: $0.0, name: $0.1) }), "/a/x")
        XCTAssertNil(codex.select([]))
        XCTAssertNil(claude.select([(path: "/p/a.jsonl", name: TranscriptName(threadID: "a"))]))
    }

    func testCandidateRolesKeepAnOlderCanonicalRolloutBehindTheRevert() {
        let canonical = "/s/rollout-2026-10-01T09-00-00-\(thread).jsonl"
        let revert = "/s/rollout-2026-10-01T10-00-00-\(thread)_\(revertID).jsonl"
        let other = "/s/rollout-2026-10-01T08-00-00-\(revertID).jsonl"
        // The revert is selected; the older canonical file is only an alternate.
        let roles = TranscriptCandidates.assign(id: thread, format: codex, listed: [canonical, revert], hint: nil)
        XCTAssertEqual(roles, [.init(path: revert, role: .selected), .init(path: canonical, role: .alternate)])
        // An older canonical hint is not a separate candidate.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [canonical, revert], hint: canonical), roles)
        // A hint whose file is named for another thread is consulted after the selected file.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [canonical, revert], hint: other),
                       [.init(path: revert, role: .selected), .init(path: other, role: .hinted), .init(path: canonical, role: .alternate)])
        // A non-canonical hint, too.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [revert], hint: "/s/rollout-codex.jsonl"),
                       [.init(path: revert, role: .selected), .init(path: "/s/rollout-codex.jsonl", role: .hinted)])
        // A present same-thread hint the listing has not seen yet competes for selection.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [canonical], hint: revert),
                       [.init(path: revert, role: .selected), .init(path: canonical, role: .alternate)])
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [canonical], hint: revert, hintPresent: false),
                       [.init(path: canonical, role: .selected)])
        // With nothing listed, a same-thread hint is all there is.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [], hint: canonical, hintPresent: false),
                       [.init(path: canonical, role: .hinted)])
        // Files named for another thread never join this one's.
        XCTAssertEqual(TranscriptCandidates.assign(id: thread, format: codex, listed: [other], hint: nil), [])
    }

    func testAlternatesArePermittedOnlyPastMissingFilesAndTheFirstSurvivorDecides() {
        let roles: [TranscriptCandidates.Assignment] = [.init(path: "r", role: .selected), .init(path: "h", role: .hinted),
                                                        .init(path: "a", role: .alternate), .init(path: "b", role: .alternate)]
        func permitted(missing: Set<String>) -> [String] {
            TranscriptCandidates.permitted(roles, role: \.role, missing: { missing.contains($0.path) }).map(\.path)
        }
        XCTAssertEqual(permitted(missing: []), ["r", "h"])
        XCTAssertEqual(permitted(missing: ["r"]), ["r", "h", "a"], "the first surviving alternate decides; no further")
        XCTAssertEqual(permitted(missing: ["r", "a"]), ["r", "h", "a", "b"])
        XCTAssertEqual(permitted(missing: ["h"]), ["r", "h"], "a hint is outside the chain")
    }

    func testClaudeTriesTheHintFirstThenEveryFileNamedForTheSession() {
        let roles = TranscriptCandidates.assign(id: "id", format: claude,
            listed: ["/p/-b/id.jsonl", "/p/-a/id.jsonl", "/p/-a/other.jsonl"], hint: "/p/-b/id.jsonl")
        XCTAssertEqual(roles, [.init(path: "/p/-b/id.jsonl", role: .hinted), .init(path: "/p/-a/id.jsonl", role: .alternate)])
        XCTAssertEqual(TranscriptCandidates.permitted(roles, role: \.role, missing: { _ in false }), roles)
    }

    // MARK: Identity

    func testClaudeIdentityIsTheFirstTypedSessionIDAndAnExhaustedScanIsIncomplete() {
        XCTAssertEqual(claude.identity(lines: lines(#"{"sessionId":"x"}"#, #"{"type":"user","sessionId":"id"}"#), expecting: "id"), .verified)
        XCTAssertEqual(claude.identity(lines: lines(#"{"type":"user","sessionId":"other"}"#, #"{"type":"user","sessionId":"id"}"#), expecting: "id"), .mismatch)
        XCTAssertEqual(claude.identity(lines: lines("garbage", #"{"type":"system"}"#), expecting: "id"), .incomplete)
        XCTAssertEqual(claude.identity(lines: [Data](), expecting: "id"), .incomplete)
        XCTAssertEqual(claude.identityScan, .lines(maxBytes: 1024 * 1024))
    }

    func testCodexIdentityReadsTheParsersThreadIDFromTheHeaderOnly() {
        XCTAssertEqual(codex.identity(lines: lines(#"{"type":"session_meta","payload":{"session_id":"s"}}"#), expecting: "s"), .verified)
        XCTAssertEqual(codex.identity(lines: lines(#"{"type":"session_meta","payload":{"id":"own","session_id":"root"}}"#), expecting: "root"), .mismatch)
        XCTAssertEqual(codex.identity(lines: lines(#"{"type":"event_msg"}"#, #"{"type":"session_meta","payload":{"id":"s"}}"#), expecting: "s"), .incomplete)
        XCTAssertEqual(codex.identityScan, .firstLine(maxBytes: 64 * 1024))
    }

    // MARK: Adoption headers

    func testCodexHeaderExcludesSubagentsAndOtherRecordsAndThrowsOnPartialMetadata() throws {
        let ok = try codex.header(firstLine: Data(#"{"type":"session_meta","payload":{"id":"a","cwd":"/w","timestamp":"2026-01-01T00:00:00Z"}}"#.utf8))
        XCTAssertEqual(ok, AdoptionCandidate(id: "a", cwd: "/w", createdAt: Date(timeIntervalSince1970: 1_767_225_600)))
        XCTAssertNil(try codex.header(firstLine: Data(#"{"type":"event_msg","payload":{}}"#.utf8)))
        XCTAssertNil(try codex.header(firstLine: Data(#"{"type":"session_meta","payload":{"id":"a","cwd":"/w","timestamp":"2026-01-01T00:00:00Z","thread_source":"subagent"}}"#.utf8)))
        XCTAssertNil(try codex.header(firstLine: Data(#"{"type":"session_meta","payload":{"id":"a","source":{"subagent":{}}}}"#.utf8)))
        for partial in [#"{"type":"session_meta","payload":{"id":"a","cwd":"/w"}}"#,
                        #"{"type":"session_meta","payload":{"id":"a","timestamp":"2026-01-01T00:00:00Z"}}"#,
                        #"{"payload":{}}"#, #"{"type":"session_meta"}"#, "{partial", ""] {
            XCTAssertThrowsError(try codex.header(firstLine: Data(partial.utf8)), partial)
        }
        XCTAssertNil(try claude.header(firstLine: Data(#"{"type":"user"}"#.utf8)))
    }

    // MARK: Facts

    func testFactsCarryTheCallersLocatorAndSelectionKeyOnAnyHost() throws {
        let path = "/home/me/.x/sessions/rollout-2026-10-01T10-00-00-\(thread).jsonl"
        let facts = codex.facts(bytes(#"{"type":"session_meta","payload":{"id":"\#(thread)","cwd":"/w"}}"# + "\n" +
                                      #"{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#),
                                name: codex.name(path: path), locator: locator(path),
                                modifiedAt: Date(timeIntervalSince1970: 5), shared: .empty)
        let s = try summary(facts)
        XCTAssertEqual(s.locator, locator(path))
        XCTAssertEqual(s.selectionKey, "2026-10-01T10-00-00-\(thread)")
        XCTAssertEqual(s.modifiedAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(s.firstPrompt, "hi")
        let claudeFacts = try summary(claude.facts(bytes(#"{"type":"system"}"#), name: claude.name(path: "/p/-work-x/id.jsonl"),
                                                   locator: locator("/p/-work-x/id.jsonl"), modifiedAt: .distantPast, shared: .empty))
        XCTAssertEqual(claudeFacts.id, "id")
        XCTAssertNil(claudeFacts.selectionKey)
        XCTAssertEqual(claudeFacts.directoryHint, "/work/x")
    }

    /// A6(b): a prompt only in the tail is a later-prompt hint, never the first prompt.
    func testATailOnlyPromptIsAHintForBothAgents() throws {
        let claudeBytes = TranscriptBytes(head: Data(#"{"type":"system","cwd":"/w"}"#.utf8),
                                          tail: Data("\n{\"type\":\"user\",\"message\":{\"content\":\"late\"}}".utf8),
                                          fileSize: 200_000, window: 64)
        let c = try summary(claude.facts(claudeBytes, name: nil, locator: locator("/p/-w/i.jsonl"), modifiedAt: .distantPast, shared: .empty))
        XCTAssertNil(c.firstPrompt)
        XCTAssertEqual(c.laterPromptHint, "late")
        let codexBytes = TranscriptBytes(head: Data(#"{"type":"session_meta","payload":{"id":"t"}}"#.utf8),
                                         tail: Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"late\"}}".utf8),
                                         fileSize: 2_000_000, window: 64, widerHead: Data())
        let x = try summary(codex.facts(codexBytes, name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty))
        XCTAssertNil(x.firstPrompt)
        XCTAssertEqual(x.laterPromptHint, "late")
    }

    func testCodexAsksForOneWiderHeadOnlyWhenTheHeadIsNotTheWholeFile() throws {
        let header = #"{"type":"session_meta","payload":{"id":"t","cwd":"/w"}}"#
        let prompt = #"{"type":"event_msg","payload":{"type":"user_message","message":"deep prompt"}}"#
        let head = Data((header + "\n" + #"{"type":"response_item","payload":{"role":"user","content":"x"}}"#).utf8)
        let partial = TranscriptBytes(head: head, tail: nil, fileSize: 500_000, window: head.count)
        XCTAssertEqual(codex.facts(partial, name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty),
                       .needsWiderHead(bytes: CodexFormat.promptScanBytes))
        let wider = partial.with(widerHead: Data((header + "\n" + prompt).utf8))
        XCTAssertEqual(try summary(codex.facts(wider, name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty)).firstPrompt,
                       "deep prompt")
        // A wider head with no prompt either is an answer, not another request.
        let none = partial.with(widerHead: head)
        XCTAssertNil(try summary(codex.facts(none, name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty)).firstPrompt)
        // A head that is the whole file needs no second read.
        XCTAssertNil(try summary(codex.facts(bytes(header), name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty)).firstPrompt)
    }

    func testUnparseableBytesAreNotSessions() {
        for text in ["", #"{"note":1}"#] {
            XCTAssertEqual(claude.facts(bytes(text), name: nil, locator: locator("/p/-w/i.jsonl"), modifiedAt: .distantPast, shared: .empty), .unparseable)
        }
        for text in ["", #"{"type":"event_msg"}"#, #"{"type":"session_meta","payload":{"id":"t","thread_source":"subagent"}}"#,
                     #"{"type":"session_meta","payload":{"cwd":"/w"}}"#] {
            XCTAssertEqual(codex.facts(bytes(text), name: nil, locator: locator("/s/r.jsonl"), modifiedAt: .distantPast, shared: .empty), .unparseable, text)
        }
    }

    // MARK: Shared facts

    func testCodexSharedFactsPreferTheEarliestHistoryPromptThenTheIndexName() {
        let history = Data("""
        {"session_id":"a","ts":20,"text":"later"}
        {"session_id":"a","ts":10,"text":"  first   prompt "}
        {"session_id":"b","ts":10,"text":"   "}
        """.utf8)
        let index = Data("""
        {"id":"a","thread_name":"name a"}
        {"id":"b","thread_name":"old b"}
        {"id":"b","thread_name":"name b"}
        """.utf8)
        let facts = codex.sharedFacts([CodexFormat.historyInput: history, CodexFormat.sessionIndexInput: index])
        XCTAssertEqual(facts.titles, ["a": "first prompt", "b": "name b"])
        XCTAssertEqual(facts.prompts, ["a": "first prompt"])
        XCTAssertEqual(codex.sharedFacts([:]), .empty)
        XCTAssertEqual(codex.sharedFacts([CodexFormat.historyInput: Data([0xff, 0xfe])]), .empty)
        XCTAssertEqual(codex.sharedInputs, ["history.jsonl", "session_index.jsonl"])
        XCTAssertEqual(claude.sharedInputs, [])
        XCTAssertEqual(claude.sharedFacts([CodexFormat.historyInput: history]), .empty)
    }

    func testCodexTitlesComeFromTheSharedFactsHandedIn() throws {
        let s = try summary(codex.facts(bytes(#"{"type":"session_meta","payload":{"id":"t"}}"#), name: nil, locator: locator("/s/r.jsonl"),
                                        modifiedAt: .distantPast, shared: SharedFacts(titles: ["t": "shared"], prompts: ["t": "prompt"])))
        XCTAssertEqual(s.sharedTitle, "shared")
        XCTAssertEqual(s.historyPrompt, "prompt")
        XCTAssertEqual(s.titleFact, "shared")
    }

    // MARK: Rows from facts

    func testSessionCoreFillingTakesOnlyRecordedFacts() {
        let path = "/s/rollout-2026-10-01T10-00-00-\(thread).jsonl"
        let full = TranscriptSummary(id: thread, agent: .codex, locator: locator(path), modifiedAt: Date(timeIntervalSince1970: 9),
                                     cwd: "/w", firstPrompt: "prompt", recordedTitle: nil, sharedTitle: "shared",
                                     laterPromptHint: "hint", legacyTitleHint: "legacy")
        let core = SessionCore(filling: full)
        XCTAssertEqual(core.host, HostID(rawValue: "box"))
        XCTAssertEqual(core.directory, "/w")
        XCTAssertEqual(core.directorySource, .transcript)
        XCTAssertEqual(core.title, "shared")
        XCTAssertEqual(core.lastActiveAt, Date(timeIntervalSince1970: 9))
        let bare = SessionCore(filling: TranscriptSummary(id: "c", agent: .claude, locator: locator("/p/-w/c.jsonl"), modifiedAt: .distantPast,
                                                          directoryHint: "/w", laterPromptHint: "hint", legacyTitleHint: "legacy"))
        XCTAssertNil(bare.directory)
        XCTAssertNil(bare.directorySource)
        XCTAssertNil(bare.title, "hints and placeholders are never stored")
    }
}
