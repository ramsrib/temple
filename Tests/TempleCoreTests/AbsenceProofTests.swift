import XCTest
@testable import TempleCore

/// `AbsenceProof.decide`, row by row (ADR-030): what a host saw, judged the
/// same way for every host.
final class AbsenceProofTests: XCTestCase {
    private let claude = ClaudeFormat()
    private let codex = CodexFormat()
    private let asked = "0199a213-81c0-7800-8aa1-bbab2a035a53"
    private let other = "0199a213-81c0-7800-8aa1-bbab2a035a54"
    private var askedFile: String { "/r/-p/\(asked).jsonl" }
    private var otherFile: String { "/r/-p/\(other).jsonl" }

    private func decide(listed: [String]? = [], exhaustive: Bool = true, events: [ScopeEvent] = [],
                        observing: Bool = true, format: (any TranscriptFormat)? = nil, ids: Set<String>? = nil) -> AbsenceProof {
        AbsenceProof.decide(ids: ids ?? [asked], format: format ?? claude, listed: listed, exhaustive: exhaustive,
                            events: events, observing: observing)
    }

    func testAnExhaustiveQuiescentListingWithoutTheFileProvesIt() {
        let proof = decide(listed: [otherFile])
        XCTAssertEqual(proof, AbsenceProof(exhaustive: true, quiescent: true, missing: [asked]))
        XCTAssertTrue(proof.proves(asked))
    }

    func testAListedFileNamedForTheIdIsNotMissing() {
        XCTAssertFalse(decide(listed: [askedFile]).proves(asked))
        // In the agent's own spelling: a capitalised name is the same id.
        let upper = "/r/s/rollout-2026-10-01T10-00-00-\(asked.uppercased()).jsonl"
        XCTAssertFalse(decide(listed: [upper], format: codex).proves(asked))
        XCTAssertFalse(decide(listed: [askedFile], ids: [asked.uppercased()]).proves(asked.uppercased()))
    }

    func testAFailedOrNonExhaustiveListingProvesNothing() {
        XCTAssertEqual(decide(listed: nil), AbsenceProof(exhaustive: false, quiescent: true, missing: []))
        XCTAssertFalse(decide(exhaustive: false).proves(asked))
    }

    func testNotObservingProvesNothing() {
        XCTAssertFalse(decide(observing: false).quiescent)
    }

    func testWhatDisturbsAndWhatDoesNot() {
        let rows: [(ScopeEvent, Bool, String)] = [
            (ScopeEvent(path: otherFile, kind: .file), false, "another session's transcript written, made or removed"),
            (ScopeEvent(path: "/r/-p/notes.txt", kind: .file), false, "a plain file named for no session"),
            (ScopeEvent(path: "/r/-p/.DS_Store", kind: .file), false, "Finder's .DS_Store"),
            (ScopeEvent(path: askedFile, kind: .file), true, "a file named for the asked id"),
            (ScopeEvent(path: "/r/-p/\(asked.uppercased()).jsonl", kind: .file), true, "named for it in another case"),
            (ScopeEvent(path: "/r/-p/.swap", kind: .file), true, "a hidden name"),
            (ScopeEvent(path: "/r/-new", kind: .directory), true, "a folder"),
            (ScopeEvent(path: "/r/-p/x.jsonl", kind: .link), true, "a link"),
            (ScopeEvent(path: "/r/-p/x", kind: .unknown), true, "an entry of unknown kind"),
            (ScopeEvent(path: "", kind: .lost), true, "lost events, a root changed, observation restarted"),
        ]
        for (event, disturbs, why) in rows {
            XCTAssertEqual(decide(listed: [otherFile], events: [event]).quiescent, !disturbs, why)
        }
        // A stream of writes to another transcript is still quiescent.
        let busy = Array(repeating: ScopeEvent(path: otherFile, kind: .file), count: 200)
        XCTAssertTrue(decide(listed: [otherFile], events: busy).proves(asked))
    }
}
