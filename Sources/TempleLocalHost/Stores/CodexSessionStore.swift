import Dispatch
import Foundation
import TempleCore

/// Reads Codex sessions from `~/.codex/sessions/**/rollout-*.jsonl`, titling them
/// from `~/.codex/history.jsonl`. See SESSION-FORMATS.md.
struct CodexSessionStore: TranscriptSummaryStore {
    let agent: Agent = .codex
    let sessionsRoot: URL
    /// `sessionsRoot` normalized once: every observed path is checked against it.
    private let sessionsPrefix: String
    private let historyFile: URL
    private let sessionIndexFile: URL
    /// history.jsonl and session_index.jsonl, read once per change to either
    /// file rather than twice for every rollout parsed.
    let shared = CodexSharedFactsCache()

    private let inspector: EntryInspector

    init(root: URL? = nil, inspector: EntryInspector = .live) {
        self.inspector = inspector
        // TEMPLE_CODEX_ROOT: see ClaudeSessionStore.
        let base = root
            ?? StoreIO.envRoot("TEMPLE_CODEX_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        self.sessionsPrefix = SessionPaths.normalized(sessionsRoot.path) + "/"
        self.historyFile = base.appendingPathComponent("history.jsonl")
        self.sessionIndexFile = base.appendingPathComponent("session_index.jsonl")
    }

    var watchedURLs: [URL] { [sessionsRoot.deletingLastPathComponent(), sessionsRoot] }
    var sharedFactURLs: [URL] { [historyFile, sessionIndexFile] }
    var catalogRoot: URL? { sessionsRoot }
    func loadSummaries() -> [TranscriptSummary] {
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

    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        StoreIO.summary(at: fileURL, format: CodexFormat(), shared: sharedFacts())
    }

    /// Titles and history prompts, re-read only when either file's
    /// signature (modification date, size, inode) changes.
    func sharedFacts() -> SharedFacts { sharedFactsSnapshot().facts }

    /// The shared facts and the revision they belong to, as one value: the
    /// cache owns both, so a reader holding old facts keeps their revision.
    func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?) {
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

    var sharedTransfers: Int { shared.fileReads }

    /// The inputs' current revision, from a stat of each; nothing is read.
    func sharedRevision() -> UInt64? { shared.revision(currentKey: sharedInputKey) }

    private func sharedInputKey() -> [SharedInputSignature] { sharedFactURLs.map(SharedInputSignature.init) }

    func catalogParser() -> @Sendable (URL) -> TranscriptSummary? { catalogSummaryParser() }

    func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary? {
        let shared = sharedFacts()
        return { StoreIO.summary(at: $0, format: CodexFormat(), shared: shared) }
    }

    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        let shared = sharedFacts()
        return { StoreIO.catalogParse(at: $0, format: CodexFormat(), shared: shared) }
    }

    func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    func enumerateSessionFiles() throws -> [URL] { try enumerateRollouts(in: sessionsRoot).files }

    func enumerateSessionFilesAudited() throws -> (files: [URL], exhaustive: Bool) { try enumerateRollouts(in: sessionsRoot) }

    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let path = SessionPaths.normalized(subtree.path)
        let prefix = SessionPaths.normalized(sessionsRoot.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        guard path.hasPrefix(prefix + "/") else { return [] }
        return try enumerateRollouts(in: subtree).files
    }

    /// Rollouts under `directory`, hidden entries passed over and links not
    /// followed, as always; every entry met goes through `ListingAudit`.
    private func enumerateRollouts(in directory: URL) throws -> (files: [URL], exhaustive: Bool) {
        let fm = FileManager.default
        let physicalRoot = directory.resolvingSymlinksInPath()
        // A missing day folder inside an available store is an empty one; a
        // missing store root is a failed listing, never a completed empty
        // scan (ADR-030), as for Claude. The catalog reads it as empty.
        do { _ = try fm.contentsOfDirectory(atPath: physicalRoot.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if SessionPaths.normalized(directory.path) == SessionPaths.normalized(sessionsRoot.path) || !rootAvailable() {
                throw StoreRootMissing(root: sessionsRoot)
            }
            return ([], true)
        }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: physicalRoot, includingPropertiesForKeys: Array(ListingAudit.keys),
            options: [], errorHandler: { _, error in failure = error; return false })
        else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        var audit = ListingAudit(inspector)
        for case let url as URL in enumerator {
            let values = audit.meet(url)
            // What `.skipsHiddenFiles` passed over, passed over still.
            if values?.isHidden ?? url.lastPathComponent.hasPrefix(".") {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") { files.append(url) }
        }
        if let failure { throw failure }
        return (files, audit.exhaustive)
    }

    func rootAvailable() -> Bool { StoreRootMissing.isDirectory(sessionsRoot) }

    /// Everything under `sessions/`: the listing walks it to any depth.
    func inAuditScope(_ path: String) -> Bool { path.hasPrefix(sessionsPrefix) }

    func acceptsTranscript(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") &&
            SessionPaths.normalized(url.path).hasPrefix(sessionsPrefix)
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
