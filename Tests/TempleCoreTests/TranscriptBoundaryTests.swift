import XCTest
import Foundation

final class TranscriptBoundaryTests: XCTestCase {
    /// A6: unrelated I/O stays where it belongs. These are permission entries for
    /// generic file APIs, never permission to call transcript parsers or roots.
    private let nonTranscriptIO: [String: String] = [
        "TempleCore/AgentToolchain.swift": "executable probes",
        "TempleCore/CommandCapture.swift": "probe subprocess stdin/stdout pipes and null device",
        "TempleCore/LoginShellEnvironment.swift": "shell executable discovery",
        "TempleCore/TempleState.swift": "Temple-owned state directory and environment override",
        "TempleCore/Logging.swift": "application logging",
        "TempleUI/Logging.swift": "application logging",
        "TempleCore/SessionFilter.swift": "project-folder existence for nonmember noise",
        "TempleUI/App/AppModel.swift": "Temple-owned obsolete cache cleanup",
        "TempleUI/App/WindowSnapshot.swift": "snapshot output directory",
        "TempleUI/App/SettingsKeysProbe.swift": "isolated settings probe",
        "TempleUI/Model/SettingsStore.swift": "user settings",
        "TempleUI/Model/OpenSessionsModel.swift": "working-directory launch/exit observations",
        "TempleUI/Model/HistoryModel.swift": "project-folder existence for nonmember noise"
    ]
    private func violations(_ text: String, path: String) throws -> [String] {
        if path.hasPrefix("TempleCore/Hosts/Local/") { return [] }
        // Usage is account-local, explicitly scoped out in §3 (CodexUsageReader).
        if path.hasPrefix("TempleCore/Usage/") { return [] }
        let transcript = #"\bStoreIO\b|\bFSEventStream\w*|\b(?:loadSummary|loadSummaries|catalogParser|verifyIdentity|enumerateSessionFiles|sessionFileURLs|adoptionHeader|metadataHeader)\s*\(|TEMPLE_(?:CLAUDE|CODEX)_ROOT|\.claude/|\.codex/|"\.(?:claude|codex)""#
        let filesystem = #"\b(?:FileManager|FileHandle)\b|\b(?:String|Data)\s*\(\s*contentsOf"#
        let transcriptPattern = try NSRegularExpression(pattern: transcript)
        let filePattern = try NSRegularExpression(pattern: filesystem)
        var hits: [String] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let transcriptLine = path == "TempleCore/TempleState.swift"
                ? line.replacingOccurrences(of: "StoreIO.envRoot(\"TEMPLE_STATE_DIR\")", with: "") : line
            let transcriptRange = NSRange(transcriptLine.startIndex..<transcriptLine.endIndex, in: transcriptLine)
            if transcriptPattern.firstMatch(in: transcriptLine, range: transcriptRange) != nil {
                hits.append("\(path):\(index + 1): transcript access: \(line)")
            } else if filePattern.firstMatch(in: line, range: range) != nil,
                      nonTranscriptIO[path] == nil, !path.hasPrefix("TempleCore/DB/") {
                hits.append("\(path):\(index + 1): unclassified filesystem access: \(line)")
            }
        }
        return hits
    }
    func testNoTranscriptIOOutsideTheLocalHostDirectory() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = repo.appendingPathComponent("Sources")
        var hits: [String] = []
        for target in ["TempleCore", "TempleUI"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: sources.appendingPathComponent(target), includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let path = String(url.path.dropFirst(sources.path.count + 1))
                hits += try violations(String(contentsOf: url, encoding: .utf8), path: path)
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }
    func testTheAuditRejectsTranscriptAccessEvenInANonTranscriptIOFile() throws {
        for code in ["CodexSessionStore().loadSummary(at: url)", "StoreIO.readFirstLine(url)",
                     "FSEventStreamCreate(nil)", "root.appendingPathComponent(\".claude/projects\")",
                     "ProcessInfo.processInfo.environment[\"TEMPLE_CODEX_ROOT\"]"] {
            XCTAssertFalse(try violations(code, path: "TempleUI/App/AppModel.swift").isEmpty)
        }
        XCTAssertFalse(try violations("StoreIO.envRoot(\"TEMPLE_STATE_DIR\"); StoreIO.readFirstLine(url)", path: "TempleCore/TempleState.swift").isEmpty)
        XCTAssertFalse(try violations("Data(contentsOf: url)", path: "TempleCore/Unexpected.swift").isEmpty)
        XCTAssertTrue(try violations("FileManager.default.fileExists(atPath: cwd)", path: "TempleUI/Model/OpenSessionsModel.swift").isEmpty)
    }
}
