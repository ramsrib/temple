import Dispatch
import Foundation
import TempleCore

/// Reads Claude Code sessions from `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
/// See SESSION-FORMATS.md.
struct ClaudeSessionStore: TranscriptSummaryStore {
    let agent: Agent = .claude
    private let root: URL

    init(root: URL? = nil) {
        // TEMPLE_CLAUDE_ROOT points the index at an alternate store (testing,
        // demos, screenshots). Defaults to the real one.
        self.root = root
            ?? StoreIO.envRoot("TEMPLE_CLAUDE_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    var watchedURLs: [URL] { [root] }
    var catalogRoot: URL? { root }

    func loadSummaries() -> [TranscriptSummary] {
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let session = loadSummary(at: files[index]) {
                collector.append(session)
            }
        }
        return collector.result()
    }

    func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    func enumerateSessionFiles() throws -> [URL] { try enumerateSessionFilesAudited().files }

    /// Project folders are the root's directories; a symbolic link to a
    /// directory there is not one of them (it is not listed, as always),
    /// so a listing that met one is not exhaustive. Hidden entries are
    /// listed like any other.
    func enumerateSessionFilesAudited() throws -> (files: [URL], exhaustive: Bool) {
        let fm = FileManager.default
        let dirs: [URL]
        // A missing root is not an empty store: it fails the listing, so no
        // member is proven absent by a volume that is not mounted or a
        // store that moved (ADR-030). The catalog reads it as empty.
        do { dirs = try fm.contentsOfDirectory(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw StoreRootMissing(root: root) }
        var files: [URL] = []
        var exhaustive = true
        for dir in dirs {
            guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                if StoreRootMissing.isLinkToDirectory(dir) { exhaustive = false }
                continue
            }
            files += try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        }
        return (files, exhaustive)
    }

    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let prefix = SessionPaths.normalized(root.path)
        let path = SessionPaths.normalized(subtree.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        let relative = path.dropFirst(prefix.count + 1).split(separator: "/")
        guard relative.count == 1 else { return [] } // no Claude subagent trees
        do {
            return try FileManager.default.contentsOfDirectory(at: subtree.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A project folder gone from a store that is there is empty; one
            // gone with the store proves nothing.
            guard rootAvailable() else { throw StoreRootMissing(root: root) }
            return []
        }
    }

    func rootAvailable() -> Bool { StoreRootMissing.isDirectory(root) }

    func acceptsTranscript(_ url: URL) -> Bool {
        let path = SessionPaths.normalized(url.path)
        let prefix = SessionPaths.normalized(root.path)
        return url.pathExtension == "jsonl" && path.hasPrefix(prefix + "/") &&
            path.split(separator: "/").count == prefix.split(separator: "/").count + 2
    }

    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        StoreIO.summary(at: fileURL, format: ClaudeFormat(), shared: .empty)
    }

    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        { StoreIO.catalogParse(at: $0, format: ClaudeFormat(), shared: .empty) }
    }
}
