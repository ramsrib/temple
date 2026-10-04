import Dispatch
import Foundation

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
public struct CodexSessionStore: TranscriptSummaryStore {
    public let agent: Agent = .codex
    let sessionsRoot: URL
    private let historyFile: URL
    private let sessionIndexFile: URL
    /// history.jsonl and session_index.jsonl, read once per change to either
    /// file rather than twice for every rollout parsed.
    let shared = CodexSharedFactsCache()

    public init(root: URL? = nil) {
        // TEMPLE_CODEX_ROOT: see ClaudeSessionStore.
        let base = root
            ?? StoreIO.envRoot("TEMPLE_CODEX_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.historyFile = base.appendingPathComponent("history.jsonl")
        self.sessionIndexFile = base.appendingPathComponent("session_index.jsonl")
    }

    public var watchedURLs: [URL] { [sessionsRoot.deletingLastPathComponent(), sessionsRoot] }
    public var sharedFactURLs: [URL] { [historyFile, sessionIndexFile] }
    public func loadSummaries() -> [TranscriptSummary] {
        let shared = sharedFacts()
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let summary = StoreIO.summary(at: files[index], format: CodexFormat(), shared: shared) {
                collector.append(summary)
            }
        }
        return collector.result()
    }

    public func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        StoreIO.summary(at: fileURL, format: CodexFormat(), shared: sharedFacts())
    }

    /// Titles and history prompts, re-read only when either file's
    /// signature (modification date, size, inode) changes.
    func sharedFacts() -> SharedFacts {
        let signature = [historyFile, sessionIndexFile].map(CodexSharedFactsCache.signature)
        return shared.facts(for: signature) {
            // Each file read once; both maps derive from that.
            var inputs: [String: Data] = [:]
            for (name, url) in [(CodexFormat.historyInput, historyFile), (CodexFormat.sessionIndexInput, sessionIndexFile)] {
                shared.countRead()
                inputs[name] = try? Data(contentsOf: url)
            }
            return CodexFormat().sharedFacts(inputs)
        }
    }

    public func catalogParser() -> @Sendable (URL) -> TranscriptSummary? { catalogSummaryParser() }

    public func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary? {
        let shared = sharedFacts()
        return { StoreIO.summary(at: $0, format: CodexFormat(), shared: shared) }
    }

    public func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    public func enumerateSessionFiles() throws -> [URL] { try enumerateRollouts(in: sessionsRoot) }

    public func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let path = SessionPaths.normalized(subtree.path)
        let prefix = SessionPaths.normalized(sessionsRoot.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        return try enumerateRollouts(in: subtree)
    }

    private func enumerateRollouts(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let physicalRoot = directory.resolvingSymlinksInPath()
        do { _ = try fm.contentsOfDirectory(atPath: physicalRoot.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: physicalRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") { files.append(url) }
        if let failure { throw failure }
        return files
    }

    public func acceptsTranscript(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") &&
            SessionPaths.normalized(url.path).hasPrefix(SessionPaths.normalized(sessionsRoot.path) + "/")
    }
}

/// One read of the shared Codex files per change, for every parse until the
/// next. Keyed by both files' signatures; a missing file has its own.
final class CodexSharedFactsCache: @unchecked Sendable {
    struct Signature: Equatable { let date: Date?; let size: Int?; let inode: UInt64? }
    private let lock = NSLock()
    private var key: [Signature]?
    private var value = SharedFacts.empty
    private(set) var loads = 0
    private let readLock = NSLock()
    private var reads = 0
    /// Shared-file reads attempted (history.jsonl, session_index.jsonl).
    var fileReads: Int { readLock.lock(); defer { readLock.unlock() }; return reads }
    func countRead() { readLock.lock(); reads += 1; readLock.unlock() }

    static func signature(_ url: URL) -> Signature {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Signature(date: attributes?[.modificationDate] as? Date, size: attributes?[.size] as? Int,
                         inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    func facts(for signature: [Signature], load: () -> SharedFacts) -> SharedFacts {
        lock.lock(); defer { lock.unlock() }
        if key != signature {
            value = load(); key = signature; loads += 1
        }
        return value
    }
}
