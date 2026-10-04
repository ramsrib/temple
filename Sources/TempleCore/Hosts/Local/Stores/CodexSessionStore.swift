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
    func sharedFacts() -> SharedFacts { sharedFactsSnapshot().facts }

    /// The shared facts and the revision they belong to, as one value: the
    /// cache owns both, so a reader holding old facts keeps their revision.
    public func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?) {
        let snapshot = shared.snapshot(currentKey: sharedInputKey) {
            // Each file read once; both maps derive from that.
            var inputs: [String: Data] = [:]
            for (name, url) in [(CodexFormat.historyInput, historyFile), (CodexFormat.sessionIndexInput, sessionIndexFile)] {
                shared.countRead()
                inputs[name] = try? Data(contentsOf: url)
            }
            return CodexFormat().sharedFacts(inputs)
        }
        return (snapshot.facts, snapshot.revision)
    }

    /// The inputs' current revision, from a stat of each; nothing is read.
    public func sharedRevision() -> UInt64? { shared.revision(currentKey: sharedInputKey) }

    private func sharedInputKey() -> [SharedInputSignature] { sharedFactURLs.map(SharedInputSignature.init) }

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
    private let lock = NSLock()
    private var key: [SharedInputSignature]?
    private var value: SharedFacts?
    private var currentRevision: UInt64 = 0
    private(set) var loads = 0
    private let readLock = NSLock()
    private var reads = 0
    /// Shared-file reads attempted (history.jsonl, session_index.jsonl).
    var fileReads: Int { readLock.lock(); defer { readLock.unlock() }; return reads }
    func countRead() { readLock.lock(); reads += 1; readLock.unlock() }

    /// Stats the inputs (under the lock, so no two callers disagree on the
    /// order of changes) and moves to a new revision when they changed.
    func revision(currentKey: () -> [SharedInputSignature]) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        rekeyLocked(currentKey())
        return currentRevision
    }

    /// The facts for the current inputs with their revision, as one value.
    /// The facts are read at most once per revision.
    func snapshot(currentKey: () -> [SharedInputSignature], load: () -> SharedFacts) -> (facts: SharedFacts, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }
        rekeyLocked(currentKey())
        if value == nil { value = load(); loads += 1 }
        return (value ?? .empty, currentRevision)
    }

    private func rekeyLocked(_ next: [SharedInputSignature]) {
        guard key != next else { return }
        if key != nil { currentRevision &+= 1 }
        key = next
        value = nil
    }
}
