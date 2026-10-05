import XCTest
@testable import TempleCore

/// `TranscriptText.cleanTitle` stops collapsing once its result is decided.
/// It must give exactly what collapsing the whole text did, byte for byte.
final class TranscriptTextTests: XCTestCase {
    /// The cleaner as it was: collapse everything, then cap.
    private func reference(_ s: String, cap: Int) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }

    private func assertParity(_ s: String, caps: [Int] = [0, 1, 2, 3, 5, 10, 159, 160, 161, 199, 200, 201],
                              file: StaticString = #filePath, line: UInt = #line) {
        for cap in caps {
            let actual = TranscriptText.cleanTitle(s, cap: cap)
            let expected = reference(s, cap: cap)
            XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), "cap \(cap): \(s.debugDescription)", file: file, line: line)
        }
    }

    func testPlainTextAndWhitespaceRuns() {
        for s in ["", " ", "\n\t \r\n", "a", " a ", "a  b\t\tc\n\nd", "  leading", "trailing  ",
                  "nbsp\u{a0}\u{a0}gap", "para\u{2029}sep\u{2028}line", "crlf\r\nline\r\rcr", "\u{85}next\u{3000}ideo"] {
            assertParity(s)
        }
    }

    /// Graphemes that a space put in place of a whitespace run can merge
    /// with: a combining mark after a newline or a tab, a prepend before one,
    /// ZWJ after one; and clusters the cap must not split.
    func testGraphemesAtTheJoinsAndTheCap() {
        let tricky = ["\n\u{301}accent", "\t\u{200D}zwj", "\u{600}\nprepend", "\u{600}\n\u{301}both",
                      "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F1FA}\u{1F1F8}\u{1F1EC}", "e\u{301}\u{302}",
                      "\u{1100}\u{1161}\u{11A8}", "\r\n\u{301}", "\u{65E5}\u{672C}"]
        for piece in tricky {
            assertParity(piece)
            for count in [1, 40, 70, 120] {
                assertParity(Array(repeating: piece, count: count).joined(separator: " \n"))
                assertParity(Array(repeating: piece, count: count).joined())
            }
        }
    }

    func testLongMessagesStopEarlyWithTheSameResult() {
        let words = (0..<5_000).map { "w\($0)" }.joined(separator: " \t\n ")
        assertParity(words)
        assertParity(String(repeating: "x", count: 100_000))
        assertParity(String(repeating: " ", count: 100_000) + "tail")
        assertParity(String(repeating: "a ", count: 50_000))
    }

    /// Random strings over the alphabet that matters, against the reference.
    func testRandomTextMatchesTheReference() {
        let alphabet: [String] = [" ", "  ", "\n", "\t", "\r\n", "\r", "\u{a0}", "\u{2029}", "a", "b", "Z", "1",
                                  "\u{301}", "\u{200D}", "\u{600}", "\u{1F468}", "\u{1F1FA}", "\u{1F1F8}", "\u{FE0F}",
                                  "\u{1100}", "\u{1161}", "\u{11A8}", "\u{65E5}", "e", "\u{308}", "\u{915}", "\u{94D}"]
        var generator = SplitMix64(seed: 0x7E3B1E)
        for _ in 0..<3_000 {
            let length = Int(generator.next() % 400)
            var s = ""
            for _ in 0..<length { s += alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            assertParity(s, caps: [0, 1, 4, 17, 160, 200])
        }
    }

    /// The byte splitter gives the lines the grapheme splitter gave, as the
    /// same bytes: CRLF kept whole, empty lines dropped, ill-formed UTF-8
    /// repaired, cut multi-byte characters at either end of a window.
    func testLineDataMatchesSplittingTheDecodedText() {
        func reference(_ data: Data) -> [Data] {
            TranscriptText.lines(data).map { $0.data(using: .utf8)! }
        }
        let fixed: [[UInt8]] = [[], [0x0a], [0x0a, 0x0a], [0x0d, 0x0a], [0x61, 0x0d, 0x0a, 0x0a, 0x62], [0x0d, 0x0d, 0x0a],
                                [0x61, 0x0d], [0xe2, 0x0a, 0x82], [0xff, 0xfe, 0x0a, 0x61], [0x80, 0x0a, 0xcc, 0x81],
                                Array("x\n\u{301}y\r\n\u{1F468}\u{200D}\n".utf8), Array("\u{1F600}".utf8).dropFirst(1).map { $0 }]
        for bytes in fixed {
            XCTAssertEqual(TranscriptText.lineData(Data(bytes)), reference(Data(bytes)), "\(bytes)")
        }
        let alphabet: [[UInt8]] = [[0x0a], [0x0d], [0x0d, 0x0a], [0x61], [0x7b, 0x7d], [0x20], [0xcc, 0x81], [0xe2, 0x80, 0x8d],
                                   [0xf0, 0x9f, 0x98, 0x80], [0xf0, 0x9f], [0x80], [0xff], [0xc3], [0xed, 0xa0, 0x80], [0xc0, 0xaf]]
        var generator = SplitMix64(seed: 0xB17E5)
        for _ in 0..<5_000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int(generator.next() % 120) { bytes += alphabet[Int(generator.next() % UInt64(alphabet.count))] }
            XCTAssertEqual(TranscriptText.lineData(Data(bytes)), reference(Data(bytes)), "\(bytes)")
        }
    }

    /// A summary kept with its shared fields stripped is brought up to date
    /// by `withShared` alone: for any shared facts, what `facts` returns.
    func testFactsApplySharedFactsOnlyThroughWithShared() {
        let id = "0199a213-81c0-7800-8aa1-bbab2a035a53"
        let bytes = TranscriptBytes(head: Data("""
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/w"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"rollout prompt"}}
            """.utf8), tail: nil, fileSize: 120)
        let locator = TranscriptLocator(host: .local, path: "/r/rollout-2026-10-01T10-00-00-\(id).jsonl")
        let format = CodexFormat()
        let sharedSets = [SharedFacts.empty, SharedFacts(titles: [id: "a title"], prompts: [id: "a prompt"]),
                          SharedFacts(titles: [id: "only a title"]), SharedFacts(titles: ["other": "x"], prompts: ["other": "y"])]
        func facts(_ shared: SharedFacts) -> TranscriptSummary? {
            if case .summary(let summary) = format.facts(bytes, name: format.name(path: locator.path), locator: locator,
                                                         modifiedAt: Date(timeIntervalSince1970: 1), shared: shared) { return summary }
            return nil
        }
        for parsedWith in sharedSets {
            let stripped = format.withShared(try! XCTUnwrap(facts(parsedWith)), .empty)
            for applied in sharedSets {
                XCTAssertEqual(format.withShared(stripped, applied), facts(applied))
            }
        }
        XCTAssertEqual(facts(sharedSets[1])?.sharedTitle, "a title")
        // Claude has no shared inputs: withShared is the identity.
        let claude = TranscriptSummary(id: "c", agent: .claude, locator: locator, modifiedAt: Date(), sharedTitle: nil)
        XCTAssertEqual(ClaudeFormat().withShared(claude, sharedSets[1]), claude)
    }
}

/// A small deterministic generator, so a failure reproduces.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
