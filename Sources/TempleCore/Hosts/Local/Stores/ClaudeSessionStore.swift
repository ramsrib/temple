import Dispatch
import Foundation

/// Reads Claude Code sessions from `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
/// See SESSION-FORMATS.md.
public struct ClaudeSessionStore: TranscriptSummaryStore {
    public let agent: Agent = .claude
    private let root: URL

    public init(root: URL? = nil) {
        // TEMPLE_CLAUDE_ROOT points the index at an alternate store (testing,
        // demos, screenshots). Defaults to the real one.
        self.root = root
            ?? StoreIO.envRoot("TEMPLE_CLAUDE_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var watchedURLs: [URL] { [root] }

    public func loadSummaries() -> [TranscriptSummary] {
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let session = loadSummary(at: files[index]) {
                collector.append(session)
            }
        }
        return collector.result()
    }

    public func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    public func enumerateSessionFiles() throws -> [URL] {
        let fm = FileManager.default
        let dirs: [URL]
        do { dirs = try fm.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var files: [URL] = []
        for dir in dirs {
            guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            files += try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        }
        return files
    }

    public func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let prefix = SessionPaths.normalized(root.path)
        let path = SessionPaths.normalized(subtree.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        let relative = path.dropFirst(prefix.count + 1).split(separator: "/")
        guard relative.count == 1 else { return [] } // no Claude subagent trees
        do {
            return try FileManager.default.contentsOfDirectory(at: subtree.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    public func acceptsTranscript(_ url: URL) -> Bool {
        let path = SessionPaths.normalized(url.path)
        let prefix = SessionPaths.normalized(root.path)
        return url.pathExtension == "jsonl" && path.hasPrefix(prefix + "/") &&
            path.split(separator: "/").count == prefix.split(separator: "/").count + 2
    }

    public func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        StoreIO.summary(at: fileURL, format: ClaudeFormat(), shared: .empty)
    }
}
