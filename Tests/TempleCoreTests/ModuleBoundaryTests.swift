import XCTest
import Foundation

/// Where local transcript I/O may be named, checked at the module level.
///
/// `TempleLocalHost` owns this Mac's transcript I/O (stores, byte reads,
/// FSEvents, the shared-facts cache); its stores are internal and
/// `LocalSessionSource` is the public type composition needs. These tests pin
/// two things: only the composition file and templectl import that module,
/// and the pure agent formats in `TempleCore/Formats` touch no filesystem API.
///
/// What they cannot do: stop a new direct Foundation read of a transcript
/// path anywhere else. Any file in TempleCore or TempleUI can still call
/// `Data(contentsOf:)` on a path it built itself, and no import list sees
/// that. Keeping transcript reads behind `HostSessionSource` remains a
/// review rule.
final class ModuleBoundaryTests: XCTestCase {
    /// Package-relative paths of the only sources outside the module itself
    /// that may import it. Test targets use `@testable import` freely; this
    /// scans `Sources/` only.
    static let allowedImporters: Set<String> = [
        "Sources/TempleUI/Hosts/LocalHost.swift",
        "Sources/templectl/main.swift",
    ]

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Any spelling of an import of the module: plain, `@testable`,
    /// `@_exported`, `@preconcurrency`, `@_implementationOnly`, or a scoped
    /// `import struct TempleLocalHost.X`.
    private static let importPattern = try! NSRegularExpression(
        pattern: #"(?:^|;)\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor)\s+)?TempleLocalHost\b"#,
        options: [.anchorsMatchLines])

    /// Filesystem reach a pure format must not have.
    private static let filesystemPattern = try! NSRegularExpression(
        pattern: #"\b(?:FileManager|FileHandle|InputStream|OutputStream)\b|\bcontentsOf\b|\b(?:open|openat|fopen|mmap|stat|lstat|fstat)\s*\("#)

    static func importsLocalHost(_ text: String) -> Bool {
        importPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func filesystemHits(_ text: String, path: String) -> [String] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            filesystemPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
                ? nil : "\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))"
        }
    }

    private func swiftFiles(under relative: String) throws -> [(path: String, text: String)] {
        let root = Self.repo.appendingPathComponent(relative)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [(String, String)] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = String(url.standardizedFileURL.path.dropFirst(Self.repo.standardizedFileURL.path.count + 1))
            result.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(result.isEmpty, "no Swift sources under \(relative)")
        return result
    }

    func testOnlyTheCompositionFileAndTemplectlImportTheLocalHost() throws {
        let importers = Set(try swiftFiles(under: "Sources")
            .filter { !$0.path.hasPrefix("Sources/TempleLocalHost/") && Self.importsLocalHost($0.text) }
            .map(\.path))
        XCTAssertEqual(importers, Self.allowedImporters,
                       "TempleLocalHost may be imported only by \(Self.allowedImporters.sorted()); found \(importers.sorted())")
    }

    func testFormatsTouchNoFilesystem() throws {
        let hits = try swiftFiles(under: "Sources/TempleCore/Formats").flatMap { Self.filesystemHits($0.text, path: $0.path) }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    /// The detectors themselves: each spelling they exist to catch is caught,
    /// and look-alikes are not.
    func testTheDetectorsCatchWhatTheyClaim() {
        for code in ["import TempleLocalHost", "@testable import TempleLocalHost", "  @_exported import TempleLocalHost",
                     "@preconcurrency import TempleLocalHost", "import struct TempleLocalHost.LocalSessionSource",
                     "import Foundation\nimport TempleLocalHost\n", "public import TempleLocalHost",
                     "internal import TempleLocalHost", "@preconcurrency package import TempleLocalHost",
                     "import Foundation; import TempleLocalHost"] {
            XCTAssertTrue(Self.importsLocalHost(code), code)
        }
        for code in ["import TempleCore", "// import TempleLocalHost is reserved for LocalHost.swift",
                     "import TempleLocalHostExtras", "let x = \"TempleLocalHost\""] {
            XCTAssertFalse(Self.importsLocalHost(code), code)
        }
        for code in ["FileManager.default.fileExists(atPath: p)", "let h = try FileHandle(forReadingFrom: url)",
                     "try Data(contentsOf: url)", "String(contentsOf: url, encoding: .utf8)",
                     "let fd = open(path, O_RDONLY)", "Darwin.open(path, O_RDONLY)", "lstat(path, &info)",
                     "InputStream(url: url)"] {
            XCTAssertFalse(Self.filesystemHits(code, path: "x").isEmpty, code)
        }
        for code in ["let lines = text.split(separator: \"\\n\")", "func parse(_ bytes: TranscriptBytes)",
                     "JSONSerialization.jsonObject(with: data)", "reopened = true",
                     "case read(Value)", "case .read(let value): return value"] {
            XCTAssertTrue(Self.filesystemHits(code, path: "x").isEmpty, code)
        }
    }
}
