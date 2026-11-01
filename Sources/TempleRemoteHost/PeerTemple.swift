import Foundation
import GRDB
import TempleCore

// Another Temple's sessions, read from its own database on a host
// (docs/designs/open-existing-sessions.md section 2). One fixed script, run
// like every query: it finds `temple.sqlite` in Temple's default state
// folder, reads it with the host's `sqlite3` in one read-only transaction
// under a host-side watchdog, writes the answer to a private temporary
// file, and only once the transaction has ended measures it and sends it.
// No session file is read, and nothing is written to the other Temple.

/// One of the other Temple's own sessions (its rows with no host), as its
/// database records it. Evidence for a launch, never this Temple's
/// decisions: only a join writes anything here (section 3).
public struct PeerSession: Sendable, Equatable {
    public let id: String
    public let agent: Agent
    /// Where the session runs on that host: the other Temple's word.
    public let directory: String
    public let transcriptPath: String?
    public let customName: String?
    public let title: String?
    public let color: String?
    /// The session's own archive there (its project's is `PeerSnapshot`'s).
    public let archived: Bool
    public let lastActiveAt: Date?
    public let lastOpenedAt: Date?

    public init(id: String, agent: Agent, directory: String, transcriptPath: String? = nil,
                customName: String? = nil, title: String? = nil, color: String? = nil,
                archived: Bool = false, lastActiveAt: Date? = nil, lastOpenedAt: Date? = nil) {
        self.id = id; self.agent = agent; self.directory = directory; self.transcriptPath = transcriptPath
        self.customName = customName; self.title = title; self.color = color; self.archived = archived
        self.lastActiveAt = lastActiveAt; self.lastOpenedAt = lastOpenedAt
    }

    /// The title the other Temple shows, by `Session.displayTitle`'s chain
    /// short of its placeholder: nil when it has neither a name nor a title.
    public var displayTitle: String? { customName ?? title }
}

/// Everything one read of the other Temple saw, from one snapshot.
public struct PeerSnapshot: Sendable, Equatable {
    public let sessions: [PeerSession]
    /// Sessions with a saved tab there (a saved tab, not proof one runs).
    public let openTabIDs: Set<String>
    /// Project folders archived there.
    public let archivedProjects: Set<String>
    /// Rows left out as unusable: no agent or folder, an agent this build
    /// doesn't know, a field that isn't text.
    public let skipped: Int

    public init(sessions: [PeerSession], openTabIDs: Set<String> = [], archivedProjects: Set<String> = [], skipped: Int = 0) {
        self.sessions = sessions; self.openTabIDs = openTabIDs
        self.archivedProjects = archivedProjects; self.skipped = skipped
    }

    /// Archived there: the session itself, or its project.
    public func isArchived(_ session: PeerSession) -> Bool {
        session.archived || archivedProjects.contains(session.directory)
    }
}

/// What asking a host for its Temple answered. A transport failure is
/// thrown instead (`PeerTempleError`); none of these is one.
public enum PeerTempleAnswer: Sendable, Equatable {
    case snapshot(PeerSnapshot)
    /// No database in Temple's default state folder.
    case noTemple
    /// A database, and no `sqlite3` to read it with.
    case noReader
    /// The database was locked, or the read ran past the watchdog.
    case busy
    /// A read-only open met the journal of a write that never finished:
    /// only that Temple, opened again, recovers it.
    case needsOpen
    /// The database's shape is not the one this build reads.
    case incompatible
    /// More than the response budget, measured before anything was sent.
    case tooLarge
    /// The read failed for another reason: `sqlite3`'s first line.
    case unreadable(String)
}

public enum PeerTempleError: Error, Equatable, LocalizedError {
    /// The command never ran on the host: ssh's own words.
    case transport(String)
    /// The answer was not one this script gives.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let line): line
        case .malformed(let what): "The host's answer was malformed (\(what))."
        }
    }
}

public enum PeerTemple {
    /// The other Temple's database, relative to the host's `$HOME`
    /// (`TempleState.defaultDirectory`). A Temple run with its state
    /// elsewhere is not found, by design.
    static let databasePath = "Library/Application Support/Temple/temple.sqlite"
    /// How long `sqlite3` may hold the database before the host kills it:
    /// under the other Temple's 5 s busy timeout, so its next write waits
    /// at most this long.
    static let watchdogSeconds = 2
    /// What one answer may carry: the remote queries' response budget.
    public static let budget = RemoteTranscripts.responseBudget
    /// The ssh deadline: transport only.
    static let deadline: TimeInterval = 10
    /// The required `session_state` columns, all present since v10.
    static let sessionColumns = ["id", "host", "agent", "directory", "transcript_path", "custom_name", "title",
                                 "color", "archived", "last_active_at", "last_opened_at"]
    /// The record fields after the `session` tag.
    static let sessionFields = 10

    /// Ask the host. `budget`: bytes the answer may carry; `reader`: where
    /// `sqlite3` is when the PATH has none (a test names a missing one).
    public static func read(exec: RemoteExec, budget: Int = PeerTemple.budget,
                            reader: String = "/usr/bin/sqlite3") async throws -> PeerTempleAnswer {
        let output = try await exec.run(script: script, args: [String(budget), String(watchdogSeconds), reader],
                                        deadline: deadline)
        guard output.reachedCommand else {
            throw PeerTempleError.transport(output.firstErrorLine ?? "ssh ended with status \(output.status)")
        }
        return try parse(output.data)
    }

    /// The SQL, one read transaction. The first two statements say whether
    /// the shape is readable before anything depends on it: a missing
    /// column makes a later statement fail, and `-bail` stops there, so the
    /// counts already printed decide "incompatible". NULL is `-`, apart
    /// from an empty string's empty field; every other field is hex, so no
    /// byte in a title can break a record.
    static let sql = #"""
    BEGIN;
    SELECT 'columns',
      (SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'grdb_migrations'),
      (SELECT count(*) FROM pragma_table_info('session_state') WHERE name IN
        ('id','host','agent','directory','transcript_path','custom_name','title','color','archived','last_active_at','last_opened_at')),
      (SELECT count(*) FROM pragma_table_info('open_tabs') WHERE name = 'session_id'),
      (SELECT count(*) FROM pragma_table_info('project_state') WHERE name IN ('path','archived'));
    SELECT 'migration', count(*) FROM grdb_migrations WHERE identifier = 'v10-session-core';
    SELECT 'session',
      CASE WHEN id IS NULL THEN '-' ELSE hex(id) END,
      CASE WHEN agent IS NULL THEN '-' ELSE hex(agent) END,
      CASE WHEN directory IS NULL THEN '-' ELSE hex(directory) END,
      CASE WHEN transcript_path IS NULL THEN '-' ELSE hex(transcript_path) END,
      CASE WHEN custom_name IS NULL THEN '-' ELSE hex(custom_name) END,
      CASE WHEN title IS NULL THEN '-' ELSE hex(title) END,
      CASE WHEN color IS NULL THEN '-' ELSE hex(color) END,
      CASE WHEN archived THEN 1 ELSE 0 END,
      CASE WHEN last_active_at IS NULL THEN '-' ELSE hex(last_active_at) END,
      CASE WHEN last_opened_at IS NULL THEN '-' ELSE hex(last_opened_at) END
      FROM session_state WHERE host = '';
    SELECT DISTINCT 'tab', hex(session_id) FROM open_tabs WHERE session_id IS NOT NULL;
    SELECT 'project', hex(path) FROM project_state WHERE archived AND path IS NOT NULL;
    COMMIT;
    """#

    /// Arguments: the budget in bytes, the watchdog's seconds, the reader's
    /// fallback path. Prints `peer<TAB>none` (no database), `peer<TAB>noreader`,
    /// `peer<TAB>failed` (no private folder), or `peer<TAB>ran<TAB><status>
    /// <TAB><killed 0|1><TAB><journal 0|1><TAB><hex first stderr line>`
    /// followed by `peer<TAB>toolarge` or the records as `sqlite3` printed
    /// them; then `done`. After a failed read only its `columns` line is
    /// sent (complete: `sqlite3` stopped on its own), and after a kill
    /// nothing, so a record cut off by the kill is never read as one.
    ///
    /// The watchdog kills first and needs nothing else: if this shell goes
    /// (the read cancelled, its connection gone), its cleanup kills
    /// `sqlite3` too, and a watchdog left behind still kills it on time.
    /// A kill is told by `sqlite3`'s status, not by a file: SIGKILL, because
    /// `sqlite3` catches SIGTERM and exits 1 (measured), which reads as an
    /// ordinary failure. The operating system releases the lock either way.
    static let script = #"""
    TAB=$(printf '\t')
    set -f
    temple_hex() { od -An -v -tx1 | tr -d ' \n'; }
    db="$HOME/Library/Application Support/Temple/temple.sqlite"
    if [ ! -e "$db" ]; then printf 'peer\tnone\ndone\n'; exit 0; fi
    sq=$(command -v sqlite3 2>/dev/null) || sq=
    case $sq in /*) ;; *) sq= ;; esac
    if [ -z "$sq" ] && [ -x "$3" ]; then sq=$3; fi
    if [ -z "$sq" ]; then printf 'peer\tnoreader\ndone\n'; exit 0; fi
    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/temple-peer.XXXXXX" 2>/dev/null) || { printf 'peer\tfailed\ndone\n'; exit 0; }
    qp=
    trap '[ -n "$qp" ] && kill -9 "$qp" 2>/dev/null; rm -rf "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    cat > "$tmp/sql" <<'TEMPLE_SQL'
    __SQL__
    TEMPLE_SQL
    "$sq" -batch -bail -readonly -noheader -list -separator "$TAB" -cmd '.timeout 1000' "$db" \
      < "$tmp/sql" > "$tmp/out" 2> "$tmp/err" &
    qp=$!
    ( sleep "$2"; kill -9 "$qp" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
    wp=$!
    wait "$qp"; qs=$?
    qp=
    kill "$wp" 2>/dev/null
    wait "$wp" 2>/dev/null
    killed=0; [ "$qs" -gt 128 ] && killed=1
    journal=0; [ "$qs" -ne 0 ] && [ -e "$db-journal" ] && journal=1
    err=$(head -n 1 "$tmp/err" | temple_hex)
    printf 'peer\tran\t%s\t%s\t%s\t%s\n' "$qs" "$killed" "$journal" "$err"
    if [ "$qs" -ne 0 ]; then
      [ "$killed" = 0 ] && grep "^columns$TAB" "$tmp/out" 2>/dev/null
    else
      size=$(wc -c < "$tmp/out" | tr -d ' ')
      if [ "$size" -gt "$1" ]; then printf 'peer\ttoolarge\n'; else cat "$tmp/out"; fi
    fi
    printf 'done\n'
    """#.replacingOccurrences(of: "__SQL__", with: sql)

    // MARK: Parsing

    static func parse(_ data: Data) throws -> PeerTempleAnswer {
        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if lines.last == "" { lines.removeLast() }
        guard lines.last == "done" else { throw PeerTempleError.malformed("no end") }
        lines.removeLast()
        guard let head = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init),
              head.first == "peer", head.count >= 2 else { throw PeerTempleError.malformed("no status") }
        switch head[1] {
        case "none": return .noTemple
        case "noreader": return .noReader
        case "failed": return .unreadable("Temple couldn't make a private temporary folder there.")
        case "ran": break
        default: throw PeerTempleError.malformed("status \(head[1])")
        }
        guard head.count == 6, let status = Int(head[2]), let killed = Int(head[3]), let journal = Int(head[4]),
              let errorBytes = RemoteTranscripts.hexBytes(head[5]) else { throw PeerTempleError.malformed("ran line") }
        let errorLine = String(decoding: errorBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Array(lines.dropFirst())
        if body == ["peer\ttoolarge"] { return .tooLarge }

        var shapeKnown = false, shapeReadable = false, migrated: Bool?
        var sessions: [PeerSession] = [], tabs = Set<String>(), projects = Set<String>(), skipped = 0
        for line in body {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "columns":
                guard fields.count == 5 else { throw PeerTempleError.malformed("columns") }
                shapeKnown = true
                shapeReadable = fields.dropFirst().map { Int($0) } == [1, sessionColumns.count, 1, 2].map(Optional.some)
            case "migration":
                guard fields.count == 2, let count = Int(fields[1]) else { throw PeerTempleError.malformed("migration") }
                migrated = count > 0
            case "session":
                if let session = decodeSession(Array(fields.dropFirst())) { sessions.append(session) } else { skipped += 1 }
            case "tab":
                if fields.count == 2, let id = text(fields[1]) { tabs.insert(id) }
            case "project":
                if fields.count == 2, let path = text(fields[1]) { projects.insert(path) }
            default:
                throw PeerTempleError.malformed("record")
            }
        }
        if shapeKnown, !shapeReadable { return .incompatible }
        if status != 0 {
            // A live writer has a journal too, and says "locked": only a
            // journal a read-only open was told to roll back is a crashed
            // write ("attempt to write a readonly database", measured).
            let lowered = errorLine.lowercased()
            if killed == 1 || lowered.contains("locked") || lowered.contains("busy") { return .busy }
            if journal == 1, lowered.contains("readonly") { return .needsOpen }
            return .unreadable(errorLine.isEmpty ? "sqlite3 ended with status \(status)" : errorLine)
        }
        guard shapeKnown else { throw PeerTempleError.malformed("no shape") }
        guard migrated == true else { return .incompatible }
        return .snapshot(PeerSnapshot(sessions: sessions, openTabIDs: tabs, archivedProjects: projects, skipped: skipped))
    }

    /// One `session` record, or nil to skip it: a field count that isn't
    /// the projection's, a field that isn't hex or isn't UTF-8, no id, an
    /// agent this build doesn't know, no folder.
    static func decodeSession(_ fields: [String]) -> PeerSession? {
        guard fields.count == sessionFields else { return nil }
        var values: [String?] = []
        for (index, field) in fields.enumerated() where index != 7 {
            if field == "-" { values.append(nil); continue }
            guard let value = text(field) else { return nil }
            values.append(value)
        }
        guard let id = values[0], !id.isEmpty,
              let agent = values[1].flatMap(Agent.init(rawValue:)),
              let directory = values[2], !directory.isEmpty,
              let archived = Int(fields[7]) else { return nil }
        return PeerSession(id: id, agent: agent, directory: directory, transcriptPath: values[3],
                           customName: values[4], title: values[5], color: values[6], archived: archived != 0,
                           lastActiveAt: values[7].flatMap(date), lastOpenedAt: values[8].flatMap(date))
    }

    /// A hex field as UTF-8 text; nil when it is neither.
    static func text(_ hex: String) -> String? {
        guard let bytes = RemoteTranscripts.hexBytes(hex) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// A date as GRDB stores one.
    static func date(_ text: String) -> Date? {
        Date.fromDatabaseValue(text.databaseValue)
    }
}
