import XCTest
@testable import TempleCore

/// Characterization of the agent formats. `Fixtures/format-golden.json` was
/// recorded from the store parsers as they stood before the formats moved to
/// `TempleCore/Formats` (the bodies that produced it were deleted in the same
/// commit). Every fact, identity verdict, adoption header and filename reading
/// the stores report over `FormatCorpus` must still match it exactly.
///
/// Behaviour that changes on purpose is tested elsewhere, against its own
/// expectation, never by re-recording this file. (Re-recording is possible —
/// run with `TEMPLE_RECORD_FORMAT_GOLDEN=1` — but it records the current
/// code, so it is only for adding a fixture whose output was checked by hand.)
final class FormatGoldenTests: XCTestCase {
    private var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/format-golden.json")
    }

    func testStoresReproduceTheRecordedFactsOverTheWholeCorpus() throws {
        let root = URL(fileURLWithPath: "/private/tmp/temple-format-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = try FormatCorpus.build(at: root)
        let actual = FormatGoldenRecord.capture(fixtures, root: root)
        if ProcessInfo.processInfo.environment["TEMPLE_RECORD_FORMAT_GOLDEN"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: goldenURL)
            return
        }
        let expected = try JSONDecoder().decode([FormatGoldenRecord].self, from: Data(contentsOf: goldenURL))
        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, a.file)
        }
    }
}
