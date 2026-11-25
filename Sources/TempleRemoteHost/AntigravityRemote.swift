import Foundation
import TempleCore

// Antigravity (`agy`) on a host (ADR-044). Its store is SQLite under
// `$HOME/.gemini/antigravity-cli` (`agy` has no variable to move it), so
// every read runs the host's own `sqlite3`, or `python3`'s sqlite module
// where there is no `sqlite3`, and prints each column hex-encoded: the
// columns travel as bytes, and `AntigravityFormat` interprets them exactly
// as it does on this Mac. Nothing here writes to the store.
//
// The read is the local one's (`ReadOnlySQLite`), in shell: a database with
// a `-wal` is opened `mode=ro` (a writer has, or had, it open); one without
// is read `immutable=1` as a checked snapshot, before and after which it
// has no `-wal` and the same size, modification time and file number.
// `immutable` takes no locks, so it never makes `agy` wait.
enum AntigravityRemote {
    /// The store's folder under `$HOME`.
    static let storeFolder = ".gemini/antigravity-cli"

    /// Shell (after `RemoteTranscripts.common`): which reader the host has
    /// (`$AGY_SQ` or `$AGY_PY`), and `temple_read_db <db> <sql>`, which
    /// prints the rows of `sql` (statements separated by `;`, read in one
    /// transaction), TAB-separated, from a private temp file `$AGY_OUT`.
    /// Status 0, 5 (busy, or a snapshot that kept changing: read again),
    /// 4 (failed; `$AGY_ERR` has the reader's line), 6 (no reader).
    static let sqlite = #"""
    AGY_SQ=; AGY_PY=
    if command -v sqlite3 >/dev/null 2>&1; then AGY_SQ=sqlite3
    elif command -v python3 >/dev/null 2>&1; then AGY_PY=python3
    fi
    AGY_PROG='import sqlite3, sys
    from urllib.parse import quote
    m, db, sql = sys.argv[1:4]
    try:
        c = sqlite3.connect("file:" + quote(db) + "?" + m, uri=True, timeout=0.25, isolation_level=None)
        c.execute("BEGIN")
        for st in sql.split(";"):
            if st.strip():
                for r in c.execute(st):
                    print("\t".join("" if v is None else str(v) for v in r))
        c.execute("COMMIT")
    except sqlite3.Error as e:
        sys.stderr.write(str(e) + "\n")
        sys.exit(5 if ("locked" in str(e) or "busy" in str(e)) else 4)'
    AGY_ERR=
    temple_uri() { printf '%s' "$1" | sed 's/%/%25/g; s/?/%3f/g; s/#/%23/g'; }
    temple_sql() {
      if [ -n "$AGY_SQ" ]; then
        AGY_ERR=$("$AGY_SQ" -init /dev/null -batch -bail -noheader -separator "$TAB" -cmd '.timeout 250' \
          "file:$(temple_uri "$2")?$1" "BEGIN; $3; COMMIT;" 2>&1 >"$AGY_OUT" </dev/null) && return 0
        case $AGY_ERR in *locked*|*busy*) return 5 ;; esac
        return 4
      elif [ -n "$AGY_PY" ]; then
        AGY_ERR=$("$AGY_PY" -c "$AGY_PROG" "$1" "$2" "$3" 2>&1 >"$AGY_OUT" </dev/null) && return 0
        [ $? -eq 5 ] && return 5
        return 4
      fi
      return 6
    }
    temple_read_db() {
      _n=0
      while [ "$_n" -lt 3 ]; do
        _n=$((_n + 1))
        if [ -e "$1-wal" ] || [ -L "$1-wal" ]; then
          temple_sql mode=ro "$1" "$2"; _s=$?
          [ "$_s" -eq 5 ] && continue
          return "$_s"
        fi
        _b=$(temple_stat "$1") || return 4
        temple_sql immutable=1 "$1" "$2"; _s=$?
        [ "$_s" -eq 5 ] && continue
        [ "$_s" -eq 0 ] || return "$_s"
        if [ ! -e "$1-wal" ] && [ ! -L "$1-wal" ] && _a=$(temple_stat "$1") && [ "$_a" = "$_b" ]; then return 0; fi
      done
      return 5
    }
    """#

    // MARK: Read

    /// What one conversation's read takes: its ids, its first user step
    /// (bounded as on this Mac) and its summary row.
    static let idsQuery = "SELECT 'id', hex(cascade_id) FROM trajectory_meta"
    static let stepQuery = """
        SELECT 'step', hex(p) FROM (SELECT substr(step_payload, 1, \(1 << 20)) AS p FROM steps \
        WHERE step_type = 14 ORDER BY idx LIMIT 1)
        """
    static func summaryQuery(_ ids: String) -> String {
        """
        SELECT 'summary', hex(conversation_id), hex(title), hex(workspace_uris), hex(parent_conversation_id), \
        step_count, hex(last_modified_time) FROM conversation_summaries WHERE conversation_id IN (\(ids))
        """
    }

    /// Arguments `db summaries id facts`. Prints the database's and its
    /// log's stat (`db<TAB>…`, `wal<TAB>…` or `wal<TAB>none`), the rows
    /// (`id`, `step`, `summary`, every column hex), the stats again, then
    /// `done`. Or `missing`, `busy` (read again), or `unreadable<TAB><why>`
    /// instead, at any point (then nothing more).
    static let readScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    f=$1; s=$2; id=$3; facts=$4
    case $id in ''|*[!0-9a-f-]*) printf 'unreadable\tnot a conversation id\n'; exit 0 ;; esac
    [ -n "$AGY_SQ$AGY_PY" ] || { printf 'unreadable\tthis host has neither sqlite3 nor python3 to read Antigravity conversations with\n'; exit 0; }
    AGY_OUT=$(umask 077; mktemp "${TMPDIR:-/tmp}/temple-agy.XXXXXX" 2>/dev/null) || { printf 'unreadable\tno temporary file on the host\n'; exit 0; }
    trap 'rm -f "$AGY_OUT"' EXIT
    trap 'exit 1' HUP INT TERM
    stamp() {
      if x=$(temple_stat "$f"); then printf 'db\t%s\n' "$x"
      elif temple_gone "$f"; then printf 'missing\n'; exit 0
      else printf 'unreadable\tthe conversation cannot be examined\n'; exit 0; fi
      if y=$(temple_stat "$f-wal"); then printf 'wal\t%s\n' "$y"
      elif temple_gone "$f-wal"; then printf 'wal\tnone\n'
      else printf 'unreadable\tthe conversation log cannot be examined\n'; exit 0; fi
    }
    rows() {
      temple_read_db "$1" "$2"
      case $? in
        0) cat "$AGY_OUT" ;;
        5) printf 'busy\n'; exit 0 ;;
        *) printf 'unreadable\t%s\n' "$(printf '%s' "${AGY_ERR:-the database could not be read}" | head -n 1)"; exit 0 ;;
      esac
    }
    stamp
    if [ "$facts" = 1 ]; then rows "$f" "$IDS; $STEP"; else rows "$f" "$IDS"; fi
    if [ "$facts" = 1 ] && { [ -e "$s" ] || [ -L "$s" ]; }; then rows "$s" "$(printf "$SUMMARY" "'$id'")"; fi
    stamp
    printf 'done\n'
    """#

    /// The read's script with its fixed queries in place (as shell words).
    static var readProgram: String {
        "IDS=" + RemoteQuoting.quote(idsQuery) + "\nSTEP=" + RemoteQuoting.quote(stepQuery)
            + "\nSUMMARY=" + RemoteQuoting.quote(summaryQuery("%s")) + "\n" + readScript
    }

    static let readDeadline: TimeInterval = 20

    enum ReadAnswer: Equatable {
        case missing
        /// Another connection held a lock, or the snapshot kept changing.
        case busy
        case unreadable(String)
        case rows(opening: TranscriptSignature, closing: TranscriptSignature, record: AntigravityFormat.Record)
    }

    /// Strict: the shape `readScript` prints and nothing else, `done` last.
    /// `id` is the conversation asked for: its summary row is the one named.
    static func parseRead(_ data: Data, id: String) -> ReadAnswer? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A terminal line ends the read: it must be the last one.
        if let stop = lines.firstIndex(where: { terminal($0) != nil }) {
            return stop == lines.count - 1 ? terminal(lines[stop]) : nil
        }
        var index = 0
        func stamp() -> TranscriptSignature? {
            guard index + 1 < lines.count, lines[index].hasPrefix("db\t"), lines[index + 1].hasPrefix("wal\t"),
                  let main = RemoteTranscripts.signature(String(lines[index].dropFirst(3))) else { return nil }
            let walText = String(lines[index + 1].dropFirst(4))
            index += 2
            if walText == "none" { return main }
            guard let log = RemoteTranscripts.signature(walText) else { return nil }
            return combined(main, log)
        }
        guard let opening = stamp() else { return nil }
        var ids: [String] = []
        var step: String?
        var summary: AntigravityFormat.Record.Summary?
        while index < lines.count, !lines[index].hasPrefix("db\t") {
            let fields = lines[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "id" where fields.count == 2:
                guard let value = utf8(fields[1]) else { return nil }
                if !value.isEmpty { ids.append(value) }
            case "step" where fields.count == 2 && step == nil:
                guard let bytes = RemoteTranscripts.hexBytes(fields[1]) else { return nil }
                step = bytes.isEmpty ? nil : bytes.base64EncodedString()
            case "summary" where fields.count == 7:
                guard let named = utf8(fields[1]), let title = utf8(fields[2]), let uris = utf8(fields[3]),
                      let parent = utf8(fields[4]), let count = Int(fields[5]), let modified = utf8(fields[6]) else { return nil }
                if named.lowercased() == id.lowercased(), summary == nil {
                    summary = .init(title: title, workspaceURIs: uris, parent: parent, stepCount: count, lastModified: modified)
                }
            default:
                return nil
            }
            index += 1
        }
        guard let closing = stamp(), index == lines.count - 1, lines[index] == "done" else { return nil }
        return .rows(opening: opening, closing: closing,
                     record: AntigravityFormat.Record(ids: ids, summary: summary, firstUserStep: step))
    }

    /// A line that ends the read, if this is one.
    private static func terminal(_ line: String) -> ReadAnswer? {
        if line == "busy" { return .busy }
        if line == "missing" { return .missing }
        if line.hasPrefix("unreadable\t") { return .unreadable(String(line.dropFirst("unreadable\t".count))) }
        return nil
    }

    /// The database and its log together, as on this Mac
    /// (`AntigravitySessionStore.signature`): a commit lands in the log first.
    static func combined(_ main: TranscriptSignature, _ log: TranscriptSignature) -> TranscriptSignature {
        TranscriptSignature(modifiedAt: max(main.modifiedAt, log.modifiedAt),
                            size: main.size &+ log.size &* 0x1_0000_0000,
                            identity: main.identity &* 1_000_003 &+ log.identity)
    }

    static func utf8(_ hex: String) -> String? {
        guard let bytes = RemoteTranscripts.hexBytes(hex) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    // MARK: Identity

    /// Arguments `proc pid start socket session`. The conversation the
    /// pane's own process (the `agy` the launch `exec`ed) holds the lock
    /// of: `presence/<id>.lock` under the store, open in that process and
    /// no other one counts (a subagent's process holds its own). Checked
    /// as Codex's is: tmux names the pid as the session's pane, and the
    /// process's start time is the same before and after its descriptors
    /// are read (from `/proc`; from `ps` where there is no `/proc`, its
    /// descriptors then from `lsof`).
    ///
    /// Prints `found<TAB><id>`, `none` (no conversation yet: `agy` makes
    /// one at the first prompt), or `inconclusive<TAB><kind><TAB><reason>`.
    static let identityScript = #"""
    P=$1; pid=$2; start=$3; sock=$4; s=$5
    NL='
    '
    no() { printf 'inconclusive\t%s\t%s\n' "$1" "$2"; exit 0; }
    t() { if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux -L temple "$@"; fi; }
    st() { _s=; IFS= read -r _s < "$P/$1/stat" 2>/dev/null || return 1; _s=${_s##*)}; set -- $_s; [ $# -ge 20 ] || return 1; begin=${20}; return 0; }
    lstart() { ps -o lstart= -p "$1" 2>/dev/null; }
    pane() { pp=$(t display-message -p -t "=$s:" '#{pane_pid}' 2>/dev/null); [ "$pp" = "$pid" ]; }
    root=$HOME/.gemini/antigravity-cli/presence
    canon=$(cd -- "$root" 2>/dev/null && pwd -P && printf x) && { canon=${canon%x}; canon=${canon%"$NL"}; } || canon=
    pane || no retry "tmux doesn't name this process as the session's pane"
    paths=
    if [ -d "$P" ]; then
      [ -n "$start" ] || no retry "Temple hasn't seen this session's process start"
      st "$pid" || no ended "the session's process has ended"
      [ "$begin" = "$start" ] || no ended "the session's process has ended"
      [ -d "$P/$pid/fd" ] || no ended "the session's process has ended"
      { [ -r "$P/$pid/fd" ] && [ -x "$P/$pid/fd" ]; } || no lasting "the session's open files can't be read"
      for fd in "$P/$pid/fd"/*; do
        [ -e "$fd" ] || [ -L "$fd" ] || continue
        l=$(readlink "$fd" 2>/dev/null) || continue
        paths="$paths$l$NL"
      done
      st "$pid" && [ "$begin" = "$start" ] || no ended "the session's process has ended"
    else
      # lsof is in /usr/sbin on macOS, which a login PATH may leave out.
      L=$(command -v lsof 2>/dev/null) || { [ -x /usr/sbin/lsof ] && L=/usr/sbin/lsof; } || no lasting "this host has neither /proc nor lsof"
      b=$(lstart "$pid"); [ -n "$b" ] || no ended "the session's process has ended"
      out=$("$L" -n -P -w -a -p "$pid" -Fn 2>/dev/null </dev/null) || no retry "lsof couldn't list the session's open files"
      a=$(lstart "$pid"); [ "$a" = "$b" ] || no ended "the session's process has ended"
      while IFS= read -r line; do case $line in n*) paths="$paths${line#n}$NL" ;; esac; done <<EOF
    $out
    EOF
    fi
    pane || no retry "tmux doesn't name this process as the session's pane"
    ids=; n=0
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      name=
      case $l in "$root"/*) name=${l#"$root"/} ;; esac
      if [ -z "$name" ] && [ -n "$canon" ]; then case $l in "$canon"/*) name=${l#"$canon"/} ;; esac; fi
      [ -n "$name" ] || continue
      case $name in */*|'') continue ;; *.lock) id=${name%.lock} ;; *) continue ;; esac
      case "$NL$ids" in *"$NL$id$NL"*) ;; *) ids="$ids$id$NL"; n=$((n + 1)) ;; esac
    done <<EOF
    $paths
    EOF
    [ "$n" -eq 0 ] && { printf 'none\n'; exit 0; }
    [ "$n" -gt 1 ] && no retry "the session's process holds more than one conversation"
    printf 'found\t%s\n' "${ids%"$NL"}"
    """#

    static let identityDeadline: TimeInterval = 15

    enum IdentityAnswer: Equatable {
        case found(String)
        case none
        case inconclusive(CodexIdentityCheck.Inconclusive)
    }

    static func identify(proc: String, panePID: Int, paneStart: String?, socket: String?, session: String,
                         using exec: RemoteExec) async -> IdentityAnswer {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            let output = try await exec.run(script: identityScript,
                                            args: [proc, String(panePID), paneStart ?? "", socket ?? "", session],
                                            deadline: identityDeadline)
            guard output.reachedCommand, output.status == 0 else {
                return .inconclusive(.retry(output.firstErrorLine ?? "ssh exited with status \(output.status)"))
            }
            return parseIdentity(output.stdout)
        } catch {
            return .inconclusive(.retry(error.localizedDescription))
        }
    }

    static func parseIdentity(_ text: String) -> IdentityAnswer {
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !line.contains("\n") else { return .inconclusive(.retry("the check printed nothing Temple expected")) }
        if line == "none" { return .none }
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if fields.first == "inconclusive", fields.count == 3 {
            switch fields[1] {
            case "lasting": return .inconclusive(.lasting(fields[2]))
            case "ended": return .inconclusive(.ended(fields[2]))
            default: return .inconclusive(.retry(fields[2]))
            }
        }
        // The lock's name, as `agy` writes it: a lowercase UUID.
        if fields.first == "found", fields.count == 2, UUID(uuidString: fields[1]) != nil, fields[1] == fields[1].lowercased() {
            return .found(fields[1])
        }
        return .inconclusive(.retry("the check printed nothing Temple expected"))
    }

    // MARK: Suggestions

    /// Arguments `since` (`agy`'s time text, UTC). Prints `now<TAB><epoch>`,
    /// then per conversation whose summary row changed since then
    /// `conv<TAB><hex id><TAB><hex workspace_uris><TAB><hex parent><TAB>
    /// <hex first step>` (the step empty when its database has none, `-`
    /// when it couldn't be read), then `done`; or `unavailable<TAB><why>`.
    static let listScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    since=$1
    base=$HOME/.gemini/antigravity-cli
    sum=$base/conversation_summaries.db
    printf 'now\t%s\n' "$(date +%s)"
    if [ ! -e "$sum" ] && [ ! -L "$sum" ]; then printf 'done\n'; exit 0; fi
    [ -n "$AGY_SQ$AGY_PY" ] || { printf 'unavailable\tthis host has neither sqlite3 nor python3 to read Antigravity conversations with\n'; exit 0; }
    case $since in ''|*[!0-9:.\ +-]*) printf 'unavailable\tno start time\n'; exit 0 ;; esac
    AGY_OUT=$(umask 077; mktemp "${TMPDIR:-/tmp}/temple-agy.XXXXXX" 2>/dev/null) || { printf 'unavailable\tno temporary file on the host\n'; exit 0; }
    trap 'rm -f "$AGY_OUT"' EXIT
    trap 'exit 1' HUP INT TERM
    temple_read_db "$sum" "SELECT conversation_id, hex(workspace_uris), hex(parent_conversation_id) FROM conversation_summaries WHERE last_modified_time >= '$since' ORDER BY last_modified_time DESC LIMIT 501"
    case $? in
      0) ;;
      *) printf 'unavailable\t%s\n' "$(printf '%s' "${AGY_ERR:-the conversations could not be listed}" | head -n 1)"; exit 0 ;;
    esac
    list=$(cat "$AGY_OUT")
    while IFS="$TAB" read -r cid ws parent; do
      [ -n "$cid" ] || continue
      case $cid in *[!0-9a-f-]*) continue ;; esac
      db=$base/conversations/$cid.db
      step=-
      if [ -f "$db" ] && [ ! -L "$db" ] && temple_read_db "$db" "$STEP"; then
        step=$(sed -n "1s/^step$TAB//p" "$AGY_OUT")
      fi
      printf 'conv\t%s\t%s\t%s\t%s\n' "$(printf '%s' "$cid" | temple_hex)" "$ws" "$parent" "$step"
    done <<EOF
    $list
    EOF
    printf 'done\n'
    """#

    /// What a declined conversation is kept under (the run store's
    /// `rollout_path`): its database, named from the store's folder.
    static let declineKeyPrefix = "~/" + storeFolder + "/conversations/"
    static func declineKey(_ id: String) -> String { declineKeyPrefix + id + ".db" }

    static var listProgram: String { "STEP=" + RemoteQuoting.quote(stepQuery) + "\n" + listScript }

    static let listDeadline: TimeInterval = 30
    static let listLimit = 500

    struct Listed: Equatable {
        let id: String
        let workspaceURIs: String
        let parent: String
        /// The first user step's payload, base64; nil when the database has
        /// none (no prompt yet).
        let firstUserStep: String?
        /// Whether the step could be read at all.
        let stepKnown: Bool
    }

    enum Listing: Equatable {
        case conversations(remoteNow: Int, [Listed])
        case unavailable(String)
    }

    static func list(since: Date, using exec: RemoteExec) async -> Listing {
        do {
            let output = try await exec.run(script: listProgram, args: [timeText(since)], deadline: listDeadline)
            guard output.reachedCommand, output.status == 0 else {
                return .unavailable(output.firstErrorLine ?? "ssh exited with status \(output.status)")
            }
            return parseList(output.data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// `agy`'s own spelling of a time, to compare its columns against as
    /// text: `2026-11-24 20:55:44+00:00` sorts before every later time it
    /// writes, fractions included.
    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + "+00:00"
    }

    static func parseList(_ data: Data) -> Listing {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else {
            return .unavailable("the lookup's answer was cut short")
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix("now\t"), let now = Int(first.dropFirst(4)) else {
            if let first = lines.first, first.hasPrefix("unavailable\t") { return .unavailable(String(first.dropFirst(12))) }
            return .unavailable("the lookup printed nothing Temple expected")
        }
        if let last = lines.last, last.hasPrefix("unavailable\t") { return .unavailable(String(last.dropFirst(12))) }
        guard lines.last == "done" else { return .unavailable("the lookup's answer was cut short") }
        var found: [Listed] = []
        for line in lines.dropFirst().dropLast() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[0] == "conv", let id = utf8(fields[1]), let uris = utf8(fields[2]),
                  let parent = utf8(fields[3]) else { return .unavailable("the lookup printed nothing Temple expected") }
            if fields[4] == "-" {
                found.append(Listed(id: id, workspaceURIs: uris, parent: parent, firstUserStep: nil, stepKnown: false))
                continue
            }
            guard let step = RemoteTranscripts.hexBytes(fields[4]) else { return .unavailable("the lookup printed nothing Temple expected") }
            found.append(Listed(id: id, workspaceURIs: uris, parent: parent,
                                firstUserStep: step.isEmpty ? nil : step.base64EncodedString(), stepKnown: true))
        }
        guard found.count <= listLimit else { return .unavailable("too many conversations to list") }
        return .conversations(remoteNow: now, found)
    }

    /// The candidates for a run: a conversation a person started (no
    /// parent), in the run's folder (its one workspace, by bytes), whose
    /// first prompt was sent inside [`since`, `until`] on the host's clock;
    /// not declined, and not an id another run holds. Newest first, each
    /// with its first prompt. `database` names a conversation's file, the
    /// key a decline is kept under.
    static func eligible(_ listed: [Listed], directory: String, since: Int, until: Date,
                         declined: Set<RemotePath>, held: Set<String>,
                         database: (String) -> String) -> [CodexSuggestion] {
        let from = Date(timeIntervalSince1970: TimeInterval(since - 1))
        let folder = RemotePath(directory)
        var seen = Set<String>()
        return listed.compactMap { conversation -> CodexSuggestion? in
            let id = conversation.id.lowercased()
            guard UUID(uuidString: id) != nil, seen.insert(id).inserted, conversation.parent.isEmpty,
                  !held.contains(id), let path = AntigravityFormat.folder(conversation.workspaceURIs),
                  RemotePath(path) == folder else { return nil }
            let file = database(id)
            guard !declined.contains(RemotePath(file)) else { return nil }
            let step = conversation.firstUserStep.flatMap(AntigravityFormat.firstPrompt)
            guard let started = step?.at, started >= from, started <= until else { return nil }
            return CodexSuggestion(rolloutPath: file, sessionID: id, firstPrompt: step?.prompt, startedAt: started,
                                   directory: path, promptKnown: true)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
