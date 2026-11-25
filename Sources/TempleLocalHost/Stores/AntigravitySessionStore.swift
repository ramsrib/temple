import Dispatch
import Foundation
import TempleCore

/// Reads Antigravity CLI conversations (`agy`, ADR-043) from
/// `~/.gemini/antigravity-cli/`: one SQLite database per conversation in
/// `conversations/<id>.db`, and a row per conversation in
/// `conversation_summaries.db`. Each read queries both and hands
/// `AntigravityFormat` one record; nothing here interprets a column. See
/// SESSION-FORMATS.md ("Antigravity CLI").
struct AntigravitySessionStore: TranscriptSummaryStore {
    let agent: Agent = .antigravity
    /// `~/.gemini/antigravity-cli`, or `TEMPLE_ANTIGRAVITY_ROOT`.
    let root: URL
    let conversationsRoot: URL
    /// `conversationsRoot` normalized once, with a trailing slash.
    private let conversationsPrefix: String
    let summariesFile: URL
    /// Where a running `agy` holds `<id>.lock` open for the conversation it
    /// has loaded.
    let presenceRoot: URL
    private let inspector: EntryInspector

    init(root: URL? = nil, inspector: EntryInspector = .live) {
        self.inspector = inspector
        // TEMPLE_ANTIGRAVITY_ROOT: see ClaudeSessionStore.
        let base = root
            ?? StoreIO.envRoot("TEMPLE_ANTIGRAVITY_ROOT")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        self.root = base
        conversationsRoot = base.appendingPathComponent("conversations", isDirectory: true)
        conversationsPrefix = SessionPaths.normalized(conversationsRoot.path) + "/"
        summariesFile = base.appendingPathComponent("conversation_summaries.db")
        presenceRoot = base.appendingPathComponent("presence", isDirectory: true)
    }

    var watchedURLs: [URL] { [root, conversationsRoot] }
    /// The summaries file and its log: a change to them alone (the title
    /// `agy` generates, the row written a moment after the database) moves
    /// the shared revision, and the engine reads again every member still
    /// wanting a title. No facts are shared through it: each read takes the
    /// row as it is then.
    var sharedFactURLs: [URL] { [summariesFile, URL(fileURLWithPath: summariesFile.path + "-wal")] }
    private let summaries = CodexSharedFactsCache()
    func sharedRevision() -> UInt64? { summaries.revision(currentKey: { sharedFactURLs.map(SharedInputSignature.init) }) }
    func sharedFactsSnapshot() -> (facts: SharedFacts, revision: UInt64?) {
        let snapshot = summaries.snapshot(currentKey: { sharedFactURLs.map(SharedInputSignature.init) }, load: { .empty })
        return (snapshot.facts, snapshot.revision)
    }
    var catalogRoot: URL? { conversationsRoot }
    /// A commit can change only a database's `-wal`, which the catalog's
    /// stamps do not see: nothing is kept across reads (ADR-043).
    var keepsCatalogSummaries: Bool { false }

    func loadSummaries() -> [TranscriptSummary] {
        let files = sessionFileURLs()
        let collector = TranscriptSummaryCollector()
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            if let summary = loadSummary(at: files[index]) { collector.append(summary) }
        }
        return collector.result()
    }

    func loadSummary(at fileURL: URL) -> TranscriptSummary? {
        if case .summary(let summary) = parse(fileURL) { return summary }
        if case .incomplete(let summary) = parse(fileURL) { return summary }
        return nil
    }

    func catalogReader() -> @Sendable (URL) -> CatalogParse {
        let store = self
        return { store.parse($0) }
    }

    // MARK: Reading

    /// The conversation's ids, from its own database.
    func verifyIdentity(at url: URL, expectedID: String) throws -> TranscriptVerification {
        let ids = try conversationRows(url, firstStep: false).ids
        return format.identity(lines: [AntigravityFormat.Record(ids: ids, summary: nil, firstUserStep: nil).encoded()],
                               expecting: expectedID)
    }

    func readTranscript(at url: URL, expecting id: String, facts: Bool,
                        shared: () -> SharedFacts) throws -> StoreTranscriptRead {
        let conversation = try conversationRows(url, firstStep: facts)
        let identityLine = AntigravityFormat.Record(ids: conversation.ids, summary: nil, firstUserStep: nil).encoded()
        let verdict = format.identity(lines: [identityLine], expecting: id)
        guard facts, verdict == .verified else { return StoreTranscriptRead(verdict: verdict, summary: nil, bytesRead: identityLine.count) }
        // The summaries' revision before their row is read: what is read is
        // at least as new as the revision these facts are stamped with.
        _ = shared()
        let record = AntigravityFormat.Record(ids: conversation.ids, summary: try summaryRow(for: url),
                                              firstUserStep: conversation.firstUserStep)
        return StoreTranscriptRead(verdict: verdict, summary: self.facts(of: record, at: url),
                                   bytesRead: record.encoded().count)
    }

    /// The catalog's parse: the record read whole is a summary or a proven
    /// exclusion; a read that failed is `failed`.
    func parse(_ url: URL) -> CatalogParse {
        let record: AntigravityFormat.Record
        do {
            let conversation = try conversationRows(url, firstStep: true)
            record = AntigravityFormat.Record(ids: conversation.ids, summary: try summaryRow(for: url),
                                              firstUserStep: conversation.firstUserStep)
        } catch { return .failed }
        return facts(of: record, at: url).map { .summary($0) } ?? .excluded
    }

    private func facts(of record: AntigravityFormat.Record, at url: URL) -> TranscriptSummary? {
        let data = record.encoded()
        let bytes = TranscriptBytes(head: data, tail: nil, fileSize: data.count, window: max(data.count + 1, TranscriptBytes.defaultWindow))
        let modifiedAt = (try? signature(at: url).date) ?? StoreIO.modificationDate(url)
        if case .summary(let summary) = format.facts(bytes, name: format.name(path: url.path),
                                                     locator: TranscriptLocator(localURL: url),
                                                     modifiedAt: modifiedAt, shared: .empty) {
            return summary
        }
        return nil
    }

    static let payloadLimit = 1 << 20

    private func conversationRows(_ url: URL, firstStep: Bool) throws -> (ids: [String], firstUserStep: String?) {
        var queries = [ReadOnlySQLite.Query(sql: "SELECT cascade_id FROM trajectory_meta")]
        if firstStep {
            // Bounded: a pasted first prompt can be megabytes. A payload cut
            // short is not a whole message, and states no prompt.
            queries.append(.init(sql: "SELECT substr(step_payload, 1, \(Self.payloadLimit)) FROM steps WHERE step_type = 14 ORDER BY idx LIMIT 1"))
        }
        let results = try ReadOnlySQLite.read(url, queries)
        let ids = results[0].compactMap { $0.first?.text }.filter { !$0.isEmpty }
        let payload = firstStep ? results[1].first?.first?.blob?.base64EncodedString() : nil
        return (ids, payload)
    }

    /// The conversation's summary row; nil when the summaries file or the
    /// row is not there yet (`agy` writes the row as the first prompt is
    /// sent, a moment after the database).
    private func summaryRow(for url: URL) throws -> AntigravityFormat.Record.Summary? {
        guard let id = format.name(path: url.path)?.threadID else { return nil }
        let rows: [[ReadOnlySQLite.Value]]
        do {
            rows = try ReadOnlySQLite.read(summariesFile, [.init(
                sql: """
                    SELECT title, workspace_uris, parent_conversation_id, step_count, last_modified_time
                    FROM conversation_summaries WHERE conversation_id = ?
                    """,
                arguments: [id])])[0]
        } catch let error as POSIXError where error.code == .ENOENT { return nil }
        guard let row = rows.first, row.count == 5 else { return nil }
        return .init(title: row[0].text ?? "", workspaceURIs: row[1].text ?? "[]", parent: row[2].text ?? "",
                     stepCount: Int(row[3].integer ?? 0), lastModified: row[4].text ?? "")
    }

    /// The database and its WAL together: a commit lands in the WAL first,
    /// and changes the main file only when it is checkpointed.
    func signature(at url: URL) throws -> FileSignature {
        let main = try FileSignature(url)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        guard let log = try? FileSignature(wal) else { return main }
        // The log's identity too: a log replaced by one of the same size and
        // time is still another version; and the main file's time, so a
        // checkpoint still older than the log's time counts as a change
        // (as `AntigravityRemote.combined` does on a host).
        let mainTime = UInt64(bitPattern: Int64((main.date.timeIntervalSince1970 * 1_000_000).rounded()))
        return FileSignature(date: max(main.date, log.date), size: main.size &+ log.size &* 0x1_0000_0000,
                             fileNumber: (main.fileNumber &* 1_000_003 &+ log.fileNumber) ^ (mainTime &* 0x9E37_79B9_7F4A_7C15))
    }

    // MARK: Listing

    func sessionFileURLs() -> [URL] { (try? enumerateSessionFiles()) ?? [] }

    func enumerateSessionFiles() throws -> [URL] { try enumerateSessionFilesAudited().files }

    /// The conversations folder's databases. Every entry met goes through
    /// `ListingAudit`: the folder is all the listing walks.
    func enumerateSessionFilesAudited() throws -> (files: [URL], exhaustive: Bool) {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: conversationsRoot.resolvingSymlinksInPath(),
                                                                  includingPropertiesForKeys: Array(ListingAudit.keys))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw StoreRootMissing(root: conversationsRoot)
        }
        var audit = ListingAudit(inspector)
        var files: [URL] = []
        for entry in entries {
            _ = audit.meet(entry)
            let url = conversationsRoot.appendingPathComponent(entry.lastPathComponent)
            if acceptsTranscript(url) { files.append(url) }
        }
        return (files, audit.exhaustive)
    }

    func enumerateSessionFiles(in subtree: URL) throws -> [URL] {
        let path = SessionPaths.normalized(subtree.path)
        let prefix = SessionPaths.normalized(conversationsRoot.path)
        if path == prefix || prefix.hasPrefix(path + "/") { return try enumerateSessionFiles() }
        return []
    }

    func rootAvailable() -> Bool { StoreRootMissing.isDirectory(conversationsRoot) }

    /// The conversations folder's own entries.
    func inAuditScope(_ path: String) -> Bool {
        path.hasPrefix(conversationsPrefix) && !path.dropFirst(conversationsPrefix.count).contains("/")
    }

    func acceptsTranscript(_ url: URL) -> Bool {
        let path = SessionPaths.normalized(url.path)
        return inAuditScope(path) && format.name(path: path) != nil
    }

    /// A write to `<id>.db-wal` is a write to the conversation.
    func transcriptURL(forEvent url: URL) -> URL? {
        if acceptsTranscript(url) { return url }
        let path = url.path
        guard path.hasSuffix(".db-wal") else { return nil }
        let database = URL(fileURLWithPath: String(path.dropLast(4)))
        return acceptsTranscript(database) ? database : nil
    }
}
