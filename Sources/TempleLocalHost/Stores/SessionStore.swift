import Foundation
import TempleCore

/// A source of agent sessions on disk (one per agent).
protocol SessionStore: Sendable {
    var agent: Agent { get }
    /// Roots whose filesystem changes can affect this store's sessions.
    var watchedURLs: [URL] { get }
    func loadSummaries() -> [TranscriptSummary]
}

extension SessionStore {
    var watchedURLs: [URL] { [] }
}

/// A store's root directory does not exist. Resolution must treat it as a
/// failed listing, never a completed empty one, or every member of that
/// agent would be proven absent (ADR-030); the catalog shows it as empty.
struct StoreRootMissing: Error, LocalizedError {
    let root: URL
    var errorDescription: String? { "\(root.path) does not exist." }

    /// Whether `root` is a directory now (through symlinks).
    static func isDirectory(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.resolvingSymlinksInPath().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Path-level capabilities required by the live engine. Full-disk catalogs
/// continue to accept any SessionStore.
protocol IncrementalSessionStore: SessionStore {
    /// Session files currently owned by this store.
    func sessionFileURLs() -> [URL]
    /// Parses one of the URLs returned by `sessionFileURLs()`.
    func loadSummary(at fileURL: URL) -> TranscriptSummary?
    func verifyIdentity(at url: URL, expectedID: String) throws -> TranscriptVerification
    /// Unlike the catalog's tolerant listing, resolution must distinguish errors
    /// from a completed empty scan.
    func enumerateSessionFiles() throws -> [URL]
    /// A missing subtree is empty only while the store root is there;
    /// without it the listing throws `StoreRootMissing` (ADR-030).
    func enumerateSessionFiles(in subtree: URL) throws -> [URL]
    /// The store's root directory is there. A file or folder gone under a
    /// root that is gone proves nothing about the file.
    func rootAvailable() -> Bool
    func filenameID(at url: URL) -> String?
    /// Codex resume priority from the canonical filename (timestamp + rollout ID).
    func rolloutSelectionKey(at url: URL) -> String?
    func acceptsTranscript(_ url: URL) -> Bool
    /// Files outside any transcript whose contents feed every summary
    /// (Codex's history.jsonl and session_index.jsonl).
    var sharedFactURLs: [URL] { get }
    func adoptionHeader(at url: URL) throws -> AdoptionCandidate?
    /// Shared-input file reads so far (a diagnostic; 0 for an agent with none).
    var sharedTransfers: Int { get }
    /// A parser for many files in one read (`LocalSessionCatalog.stream`): any
    /// input shared by every file is read once, here, not once per file.
    func catalogParser() -> @Sendable (URL) -> TranscriptSummary?
    /// The shared inputs' current revision, from a stat (no read); nil for
    /// an agent with none. It moves whenever the inputs changed.
    func sharedRevision() -> UInt64?
    /// Shared facts with the revision of the inputs they were read from,
    /// acquired together (nil revision: no shared inputs).
    func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?)
    /// The directory the catalog's kept summaries are tied to
    /// (`CatalogRoot`); nil keeps nothing for this store.
    var catalogRoot: URL? { get }
    /// The catalog's parse, saying what it came to (`CatalogParse`), so
    /// only an outcome every read of which succeeded is kept.
    func catalogReader() -> @Sendable (URL) -> CatalogParse
}

/// What one catalog parse of a transcript came to. Only `summary` and
/// `excluded` are ever kept (ADR-032).
enum CatalogParse: Sendable, Equatable {
    /// Every read the facts needed succeeded.
    case summary(TranscriptSummary)
    /// A summary, but a read it needed (the tail, a wider head, the stat)
    /// failed: shown as it always was, never kept.
    case incomplete(TranscriptSummary)
    /// Read whole, and the bytes state no session: a proven exclusion.
    case excluded
    /// The read failed, or what was read proves nothing.
    case failed
}

extension IncrementalSessionStore {
    /// The pure format behind this store's agent; every reading of a file's
    /// name, identity, header and facts goes through it.
    var format: any TranscriptFormat { TranscriptFormats.format(for: agent) }

    /// Identity is independent of enrichment. No shared history is opened here.
    func verifyIdentity(at url: URL, expectedID: String) throws -> TranscriptVerification {
        switch format.identityScan {
        case .firstLine(let maxBytes):
            return format.identity(lines: [try StoreIO.readFirstLine(url, maxBytes: maxBytes)], expecting: expectedID)
        case .lines(let maxBytes):
            let lines = try StoreIO.IdentityLines(url, maxBytes: maxBytes)
            let verdict = format.identity(lines: lines, expecting: expectedID)
            if let error = lines.error { throw error }
            return verdict
        }
    }

    func enumerateSessionFiles() throws -> [URL] { sessionFileURLs() }
    func rootAvailable() -> Bool { true }
    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let prefix = SessionPaths.normalized(subtree.path)
        return try enumerateSessionFiles().filter { SessionPaths.normalized($0.path).hasPrefix(prefix + "/") }
    }
    func filenameID(at url: URL) -> String? { format.name(path: url.path)?.threadID }
    func rolloutSelectionKey(at url: URL) -> String? { format.name(path: url.path)?.selectionKey }
    var sharedFactURLs: [URL] { [] }
    func acceptsTranscript(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && !url.pathComponents.contains("subagents")
    }
    /// Nil proves an exclusion. Invalid/partial eligible metadata throws, so
    /// adoption cannot mistake a failed read for a noncompeting rollout.
    func adoptionHeader(at url: URL) throws -> AdoptionCandidate? {
        guard agent == .codex else { return nil }
        return try format.header(firstLine: StoreIO.readFirstLine(url, maxBytes: CodexFormat.headerLineBytes))
    }
    var sharedTransfers: Int { 0 }
    var catalogRoot: URL? { nil }
    func sharedRevision() -> UInt64? { nil }
    func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?) { (.empty, nil) }
    func catalogParser() -> @Sendable (URL) -> TranscriptSummary? {
        let store = self
        return { store.loadSummary(at: $0) }
    }
    /// A store that only says "summary or nil" cannot tell a failed read
    /// from an exclusion, nor a whole read from a partial one: its summaries
    /// are shown and never kept.
    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        let parser = catalogParser()
        return { url in parser(url).map { .incomplete($0) } ?? .failed }
    }

}

/// Fact-producing stores used by catalog and member enrichment.
protocol TranscriptSummaryStore: IncrementalSessionStore {
    func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary?
}
extension TranscriptSummaryStore {
    func catalogSummaryParser() -> @Sendable (URL) -> TranscriptSummary? { catalogParser() }
}

/// Lexical aliases, preserving case and requiring no access to an event leaf.
enum SessionPaths {
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        let p = "/" + components.joined(separator: "/")
        for prefix in ["/tmp", "/var"] where p == prefix || p.hasPrefix(prefix + "/") {
            return "/private" + p
        }
        return p
    }
}

// MARK: - Shared file/JSON helpers

enum StoreIO {
    static let readWindowBytes = TranscriptBytes.defaultWindow

    /// Read only the first `maxBytes` of a file — enough for metadata + the
    /// first prompt, without loading multi-MB session logs into memory.
    static func readHead(_ url: URL, maxBytes: Int = readWindowBytes) -> String? {
        readHeadData(url, maxBytes: maxBytes).map { String(decoding: $0, as: UTF8.self) }
    }

    static func readHeadData(_ url: URL, maxBytes: Int = readWindowBytes) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: maxBytes)) ?? Data()
    }

    /// Read one JSONL header, never decoding the rest of the prefix or file.
    /// A missing newline at EOF is valid; hitting the cap is incomplete input.
    static func readFirstLine(_ url: URL, maxBytes: Int = readWindowBytes) throws -> Data {
        guard maxBytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line = Data()
        while line.count < maxBytes {
            let chunk = try handle.read(upToCount: min(4096, maxBytes - line.count)) ?? Data()
            if chunk.isEmpty { return line }
            if let newline = chunk.firstIndex(of: 0x0a) {
                line.append(chunk.prefix(upTo: newline))
                return line
            }
            line.append(chunk)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Read at most the last `maxBytes`, keeping large logs memory-bounded.
    static func readTail(_ url: URL, maxBytes: Int = readWindowBytes) -> String? {
        readTailData(url, maxBytes: maxBytes).map { String(decoding: $0, as: UTF8.self) }
    }

    static func readTailData(_ url: URL, maxBytes: Int = readWindowBytes) -> Data? {
        guard maxBytes > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        do {
            try fh.seek(toOffset: start)
            return try fh.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// The bytes a format reads: a head and, only for files larger than the
    /// head window, a non-overlapping tail (for files between one and two
    /// windows, just the remainder). Nil when the file cannot be opened.
    static func transcriptBytes(_ url: URL, fileSize: Int? = nil, maxBytes: Int = readWindowBytes) -> TranscriptBytes? {
        guard maxBytes > 0, let head = readHeadData(url, maxBytes: maxBytes) else { return nil }
        let size = fileSize ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? head.count)
        guard size > maxBytes else { return TranscriptBytes(head: head, tail: nil, fileSize: size, window: maxBytes) }
        let tailBytes = min(maxBytes, max(0, size - maxBytes))
        let tail = tailBytes > 0 ? readTailData(url, maxBytes: tailBytes) : nil
        return TranscriptBytes(head: head, tail: tail, fileSize: size, window: maxBytes)
    }

    /// One transcript's facts through its format: a bounded read, and at most
    /// one wider head when the format asks for it.
    static func summary(at url: URL, format: any TranscriptFormat, shared: SharedFacts) -> TranscriptSummary? {
        let signature = fileSignature(url)
        guard let bytes = transcriptBytes(url, fileSize: signature?.fileSize) else { return nil }
        let name = format.name(path: url.path)
        let locator = TranscriptLocator(localURL: url)
        let modifiedAt = signature?.modificationDate ?? modificationDate(url)
        var facts = format.facts(bytes, name: name, locator: locator, modifiedAt: modifiedAt, shared: shared)
        if case .needsWiderHead(let wider) = facts {
            let widerHead = readHeadData(url, maxBytes: wider) ?? Data()
            facts = format.facts(bytes.with(widerHead: widerHead), name: name, locator: locator,
                                 modifiedAt: modifiedAt, shared: shared)
        }
        if case .summary(let summary) = facts { return summary }
        return nil
    }

    /// The reads a catalog parse makes, so a test can fail any of them.
    struct Reads: Sendable {
        var signature: @Sendable (URL) -> (modificationDate: Date, fileSize: Int)?
        var head: @Sendable (URL, Int) throws -> Data
        var tail: @Sendable (URL, Int) throws -> Data

        static let file = Reads(
            signature: { StoreIO.fileSignature($0) },
            head: { url, maxBytes in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try handle.read(upToCount: maxBytes) ?? Data()
            },
            tail: { url, maxBytes in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                try handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
                return try handle.readToEnd() ?? Data()
            })
    }

    /// `summary(at:)` for the catalog, saying what it came to: the same
    /// bytes, the same facts, but a failed read is never silently empty. A
    /// head that cannot be read fails the parse; a stat, tail or wider head
    /// that cannot be read leaves the summary `incomplete` (it has exactly
    /// the content `summary(at:)` gives, and is never kept). Bytes read
    /// whole that state no session are `excluded`.
    static func catalogParse(at url: URL, format: any TranscriptFormat, shared: SharedFacts,
                             reads: Reads = .file) -> CatalogParse {
        let maxBytes = readWindowBytes
        let signature = reads.signature(url)
        var whole = signature != nil
        let head: Data
        do { head = try reads.head(url, maxBytes) } catch { return .failed }
        let size = signature?.fileSize ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? head.count)
        var tail: Data?
        if size > maxBytes {
            let tailBytes = min(maxBytes, max(0, size - maxBytes))
            if tailBytes > 0 {
                do { tail = try reads.tail(url, tailBytes) } catch { whole = false }
            }
        }
        let bytes = TranscriptBytes(head: head, tail: tail, fileSize: size, window: maxBytes)
        let name = format.name(path: url.path)
        let locator = TranscriptLocator(localURL: url)
        let modifiedAt = signature?.modificationDate ?? modificationDate(url)
        var facts = format.facts(bytes, name: name, locator: locator, modifiedAt: modifiedAt, shared: shared)
        if case .needsWiderHead(let wider) = facts {
            let widerHead: Data
            do { widerHead = try reads.head(url, wider) } catch { widerHead = Data(); whole = false }
            facts = format.facts(bytes.with(widerHead: widerHead), name: name, locator: locator,
                                 modifiedAt: modifiedAt, shared: shared)
        }
        switch facts {
        case .summary(let summary): return whole ? .summary(summary) : .incomplete(summary)
        case .unparseable: return whole ? .excluded : .failed
        case .needsWiderHead: return .failed
        }
    }

    /// `summary(at:)` with what it cost: bytes read, and whether a wider
    /// head was needed. Nil summary for bytes that state no session.
    static func facts(at url: URL, format: any TranscriptFormat, shared: SharedFacts)
        -> (summary: TranscriptSummary?, bytesRead: Int, widerRead: Bool) {
        let signature = fileSignature(url)
        guard let bytes = transcriptBytes(url, fileSize: signature?.fileSize) else { return (nil, 0, false) }
        var read = bytes.head.count + (bytes.tail?.count ?? 0)
        let name = format.name(path: url.path)
        let locator = TranscriptLocator(localURL: url)
        let modifiedAt = signature?.modificationDate ?? modificationDate(url)
        var facts = format.facts(bytes, name: name, locator: locator, modifiedAt: modifiedAt, shared: shared)
        var wider = false
        if case .needsWiderHead(let size) = facts {
            let widerHead = readHeadData(url, maxBytes: size) ?? Data()
            read += widerHead.count
            wider = true
            facts = format.facts(bytes.with(widerHead: widerHead), name: name, locator: locator,
                                 modifiedAt: modifiedAt, shared: shared)
        }
        if case .summary(let summary) = facts { return (summary, read, wider) }
        return (nil, read, wider)
    }

    /// Identity through the format, with the bytes the scan read.
    static func identity(at url: URL, format: any TranscriptFormat, expecting id: String) throws
        -> (verdict: TranscriptVerification, bytesRead: Int) {
        switch format.identityScan {
        case .firstLine(let maxBytes):
            let line = try readFirstLine(url, maxBytes: maxBytes)
            return (format.identity(lines: [line], expecting: id), line.count + 1)
        case .lines(let maxBytes):
            let lines = try IdentityLines(url, maxBytes: maxBytes)
            let verdict = format.identity(lines: lines, expecting: id)
            if let error = lines.error { throw error }
            return (verdict, lines.bytesRead)
        }
    }

    /// Lines for a `.lines` identity scan: every complete line inside the
    /// first `maxBytes`, and the final unterminated line only when the end of
    /// the file came first. A read error ends the sequence and is kept.
    final class IdentityLines: Sequence, IteratorProtocol {
        private let handle: FileHandle
        private let cap: Int
        private var pending = Data()
        private var read = 0
        private var finished = false
        private(set) var error: Error?
        var bytesRead: Int { read }

        init(_ url: URL, maxBytes: Int) throws {
            handle = try FileHandle(forReadingFrom: url)
            cap = maxBytes
        }
        deinit { try? handle.close() }

        func next() -> Data? {
            while !finished {
                if let newline = pending.firstIndex(of: 0x0a) {
                    let line = Data(pending.prefix(upTo: newline))
                    pending.removeSubrange(...newline)
                    return line
                }
                guard read < cap else { finished = true; return nil }
                let chunk: Data
                do { chunk = try handle.read(upToCount: 64 * 1024) ?? Data() }
                catch { self.error = error; finished = true; return nil }
                read += chunk.count
                if chunk.isEmpty { finished = true; return pending }
                pending.append(chunk)
            }
            return nil
        }
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    /// Optional store-root override from the environment (testing / demos).
    static func envRoot(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func fileSignature(_ url: URL) -> (modificationDate: Date, fileSize: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return (date, size)
    }

}

/// Locked sink for parallel transcript parsing.
final class TranscriptSummaryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [TranscriptSummary] = []

    func append(_ summary: TranscriptSummary) {
        lock.lock()
        summaries.append(summary)
        lock.unlock()
    }

    func result() -> [TranscriptSummary] {
        lock.lock()
        defer { lock.unlock() }
        return summaries
    }
}

/// A shared input's stat signature: modification date, size, file identity.
/// A missing file has its own (all nil).
struct SharedInputSignature: Hashable, Sendable {
    let date: Date?
    let size: Int?
    let inode: UInt64?
    /// One `lstat(2)`; a file that is not there has no signature fields.
    init(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { date = nil; size = nil; inode = nil; return }
        date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        size = Int(info.st_size)
        inode = UInt64(info.st_ino)
    }
}
