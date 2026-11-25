import Foundation
import TempleCore

// Antigravity (`agy`) on a host (ADR-044). Its store is SQLite under
// `$HOME/.gemini/antigravity-cli` (`agy` has no variable to move it), so
// every read runs the host's own `sqlite3`, or `python3`'s sqlite module
// where there is no working `sqlite3`, and prints each column hex-encoded:
// the columns travel as bytes, and `AntigravityFormat` interprets them
// exactly as it does on this Mac.
//
// Nothing here creates a file in the store. Measured (2026-11-25, sqlite3
// 3.46 and 3.53 on Linux, 3.54 on macOS, Python's module on both): a
// `mode=ro` open creates `-wal` and `-shm` beside a database that has
// neither (Linux), and `-shm` beside a log a crashed writer left without
// one (everywhere); `mode=ro&immutable=1` creates nothing. So a database is
// read one of three ways, as `ReadOnlySQLite` does on this Mac:
// - no `-wal`: no writer has it open; read `immutable` as a checked
//   snapshot (no `-wal`, and the same size, modification time and inode,
//   before and after);
// - a `-wal` and a `-shm`: `agy` has it open; read `mode=ro`, as any reader
//   of a live database does;
// - a `-wal` and no `-shm`: a writer died; nothing has it open, and a
//   reader there would make a `-shm`. The two files are copied into a
//   private folder (stats the same before and after) and the copy is read.
enum AntigravityRemote {
    /// The store's folder under `$HOME`.
    static let storeFolder = ".gemini/antigravity-cli"

    /// Shell (after `RemoteTranscripts.common`): which reader the host has
    /// (`$AGY_SQ` or `$AGY_PY`: one that ran a query just now; `python3` is
    /// never tried on macOS, whose may be a stub that offers to install
    /// developer tools), and `temple_read_db <db> <sql>`, which leaves the
    /// rows of `sql` (statements separated by `;`, read in one transaction),
    /// TAB-separated, in `$AGY_OUT`, inside the private folder `$AGY_DIR`.
    /// Status 0, 5 (busy, or a database that kept changing: read again), 4
    /// (failed; `$AGY_ERR` has the reader's words), 6 (no reader).
    static let sqlite = #"""
    AGY_SQ=; AGY_PY=
    if command -v sqlite3 >/dev/null 2>&1 && sqlite3 -init /dev/null -batch :memory: 'SELECT 1' </dev/null >/dev/null 2>&1; then
      AGY_SQ=sqlite3
    elif [ "$(uname -s 2>/dev/null)" != Darwin ] && command -v python3 >/dev/null 2>&1 \
      && python3 -c 'import sqlite3; sqlite3.connect(":memory:").execute("SELECT 1")' </dev/null >/dev/null 2>&1; then
      AGY_PY=python3
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
        code = getattr(e, "sqlite_errorcode", None)
        if code is not None:
            busy = (code & 255) in (5, 6, 15)
        else:
            busy = any(w in str(e) for w in ("database is locked", "database table is locked", "locking protocol"))
        sys.exit(5 if busy else 4)'
    AGY_ERR=; AGY_DIR=; AGY_OUT=
    temple_agy_dir() {
      AGY_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/temple-agy.XXXXXX" 2>/dev/null) || return 1
      AGY_OUT=$AGY_DIR/out
      trap 'rm -rf "$AGY_DIR"' EXIT
      trap 'exit 1' HUP INT TERM
    }
    temple_uri() { printf '%s' "$1" | sed 's/%/%25/g; s/?/%3f/g; s/#/%23/g'; }
    temple_sql() {
      if [ -n "$AGY_SQ" ]; then
        AGY_ERR=$("$AGY_SQ" -init /dev/null -batch -bail -noheader -separator "$TAB" -cmd '.timeout 250' \
          "file:$(temple_uri "$2")?$1" "BEGIN; $3; COMMIT;" 2>&1 >"$AGY_OUT" </dev/null) && return 0
        case $AGY_ERR in *"database is locked"*|*"database table is locked"*|*"locking protocol"*) return 5 ;; esac
        return 4
      elif [ -n "$AGY_PY" ]; then
        AGY_ERR=$("$AGY_PY" -c "$AGY_PROG" "$1" "$2" "$3" 2>&1 >"$AGY_OUT" </dev/null) && return 0
        [ $? -eq 5 ] && return 5
        return 4
      fi
      return 6
    }
    temple_there() { [ -e "$1" ] || [ -L "$1" ]; }
    temple_read_db() {
      _n=0
      while [ "$_n" -lt 3 ]; do
        _n=$((_n + 1))
        if temple_there "$1-wal"; then
          if temple_there "$1-shm"; then
            temple_sql mode=ro "$1" "$2"; _s=$?
            [ "$_s" -eq 5 ] && continue
            return "$_s"
          fi
          _b=$(temple_stat "$1") && _bw=$(temple_stat "$1-wal") || return 4
          rm -f "$AGY_DIR/c.db" "$AGY_DIR/c.db-wal" "$AGY_DIR/c.db-shm"
          { cp "$1" "$AGY_DIR/c.db" && cp "$1-wal" "$AGY_DIR/c.db-wal"; } 2>/dev/null || return 4
          _a=$(temple_stat "$1") && _aw=$(temple_stat "$1-wal") || continue
          { [ "$_a" = "$_b" ] && [ "$_aw" = "$_bw" ] && ! temple_there "$1-shm"; } || continue
          temple_sql mode=rw "$AGY_DIR/c.db" "$2"; _s=$?
          [ "$_s" -eq 5 ] && continue
          return "$_s"
        fi
        _b=$(temple_stat "$1") || return 4
        temple_sql 'mode=ro&immutable=1' "$1" "$2"; _s=$?
        [ "$_s" -eq 5 ] && continue
        [ "$_s" -eq 0 ] || return "$_s"
        if ! temple_there "$1-wal" && _a=$(temple_stat "$1") && [ "$_a" = "$_b" ]; then return 0; fi
      done
      return 5
    }
    """#

    // MARK: Read

    /// What one conversation's read takes: its ids, its first user step
    /// (bounded as on this Mac) and its summary row.
    static let idsQuery = "SELECT 'id', hex(cascade_id) FROM trajectory_meta"
    static func stepQuery(limit: Int) -> String {
        """
        SELECT 'step', hex(p) FROM (SELECT substr(step_payload, 1, \(limit)) AS p FROM steps \
        WHERE step_type = 14 ORDER BY idx LIMIT 1)
        """
    }
    static let summaryQuery = """
        SELECT 'summary', hex(conversation_id), hex(title), hex(workspace_uris), hex(parent_conversation_id), \
        step_count, hex(last_modified_time) FROM conversation_summaries WHERE conversation_id = '%s'
        """

    /// Arguments `db summaries id facts`; a path that begins `~/` is under
    /// `$HOME`. Prints the database's and its log's stat (`db<TAB>…`,
    /// `wal<TAB>…` or `wal<TAB>none`), the rows (`id`, `step`, `summary`,
    /// every column hex), the stats again, then `done`. Or `missing`,
    /// `busy` (read again), or `unreadable<TAB><why>` instead, at any point
    /// (then nothing more).
    static let readScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    f=$1; s=$2; id=$3; facts=$4
    case $f in "~/"*) f=$HOME/${f#"~/"} ;; esac
    case $s in "~/"*) s=$HOME/${s#"~/"} ;; esac
    case $id in ''|*[!0-9a-f-]*) printf 'unreadable\tnot a conversation id\n'; exit 0 ;; esac
    [ -n "$AGY_SQ$AGY_PY" ] || { printf 'unreadable\t%s\n' "$NOREADER"; exit 0; }
    temple_agy_dir || { printf 'unreadable\tno temporary folder on the host\n'; exit 0; }
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
        0) r=$(cat "$AGY_OUT") || { printf 'unreadable\tthe answer could not be read back\n'; exit 0; }
           [ -z "$r" ] || printf '%s\n' "$r" ;;
        5) printf 'busy\n'; exit 0 ;;
        *) printf 'unreadable\t%s\n' "$(printf '%s' "${AGY_ERR:-the database could not be read}" | head -n 1)"; exit 0 ;;
      esac
    }
    stamp
    if [ "$facts" = 1 ]; then rows "$f" "$IDS; $STEP"; else rows "$f" "$IDS"; fi
    if [ "$facts" = 1 ] && temple_there "$s"; then rows "$s" "$(printf "$SUMMARY" "$id")"; fi
    stamp
    printf 'done\n'
    """#

    /// Why a host can't read Antigravity's sessions at all.
    static let noReader = "this host has no working sqlite3 or python3 to read Antigravity's sessions with"

    /// The read's script with its fixed queries in place (as shell words).
    static var readProgram: String {
        ["IDS=" + RemoteQuoting.quote(idsQuery), "STEP=" + RemoteQuoting.quote(stepQuery(limit: 1 << 20)),
         "SUMMARY=" + RemoteQuoting.quote(summaryQuery), "NOREADER=" + RemoteQuoting.quote(noReader)]
            .joined(separator: "\n") + "\n" + readScript
    }

    static let readDeadline: TimeInterval = 20

    enum ReadAnswer: Equatable {
        case missing
        /// Another connection held a lock, or the database kept changing.
        case busy
        case unreadable(String)
        case rows(opening: TranscriptSignature, closing: TranscriptSignature, record: AntigravityFormat.Record)
    }

    /// Strict: the shape `readScript` prints and nothing else, `done` last;
    /// a terminal line (`missing`, `busy`, `unreadable`) only last, after
    /// lines of that shape. `id` is the conversation asked for: a summary
    /// row for any other is no answer.
    static func parseRead(_ data: Data, id: String) -> ReadAnswer? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        var stamps: [TranscriptSignature] = []
        var ids: [String] = []
        var sawStep = false
        var step: String?
        var summary: AntigravityFormat.Record.Summary?
        while index < lines.count {
            let line = lines[index]
            if let stop = terminal(line) { return index == lines.count - 1 ? stop : nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "db":
                // A stamp: this line and the log's after it.
                guard stamps.count < 2, index + 1 < lines.count, lines[index + 1].hasPrefix("wal\t"),
                      let main = RemoteTranscripts.signature(String(line.dropFirst(3))) else { return nil }
                let walText = String(lines[index + 1].dropFirst(4))
                if walText == "none" {
                    stamps.append(main)
                } else {
                    guard let log = RemoteTranscripts.signature(walText) else { return nil }
                    stamps.append(combined(main, log))
                }
                index += 2
                continue
            case "id" where fields.count == 2 && stamps.count == 1:
                guard let value = utf8(fields[1]) else { return nil }
                if !value.isEmpty { ids.append(value) }
            case "step" where fields.count == 2 && stamps.count == 1 && !sawStep:
                guard let bytes = RemoteTranscripts.hexBytes(fields[1]) else { return nil }
                sawStep = true
                step = bytes.isEmpty ? nil : bytes.base64EncodedString()
            case "summary" where fields.count == 7 && stamps.count == 1 && summary == nil:
                guard let named = utf8(fields[1]), named.lowercased() == id.lowercased(), let title = utf8(fields[2]),
                      let uris = utf8(fields[3]), let parent = utf8(fields[4]), let count = Int(fields[5]),
                      let modified = utf8(fields[6]) else { return nil }
                summary = .init(title: title, workspaceURIs: uris, parent: parent, stepCount: count, lastModified: modified)
            case "done" where fields.count == 1 && stamps.count == 2 && index == lines.count - 1:
                return .rows(opening: stamps[0], closing: stamps[1],
                             record: AntigravityFormat.Record(ids: ids, summary: summary, firstUserStep: step))
            default:
                return nil
            }
            index += 1
        }
        return nil
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
    /// Every part of both stats moves it: the main file's time is folded
    /// into the identity, so a checkpoint older than the log's time still
    /// counts as a change.
    static func combined(_ main: TranscriptSignature, _ log: TranscriptSignature) -> TranscriptSignature {
        let mainTime = UInt64(bitPattern: Int64((main.modifiedAt.timeIntervalSince1970 * 1_000_000).rounded()))
        return TranscriptSignature(modifiedAt: max(main.modifiedAt, log.modifiedAt),
                                   size: main.size &+ log.size &* 0x1_0000_0000,
                                   identity: (main.identity &* 1_000_003 &+ log.identity) ^ (mainTime &* 0x9E37_79B9_7F4A_7C15))
    }

    static func utf8(_ hex: String) -> String? {
        guard let bytes = RemoteTranscripts.hexBytes(hex) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    // MARK: Identity

    /// Arguments `proc pid start socket session`. The conversation the
    /// pane's own process (the `agy` the launch `exec`ed) holds the lock
    /// of: `presence/<id>.lock` directly under the store, open in that
    /// process and no other one (a subagent's process holds its own). tmux
    /// names the pid as the session's live pane before and after; the
    /// process's start time is the one the pane recorded at launch and the
    /// same after its descriptors are read: from `/proc` (descriptors by
    /// `readlink`, each matched whole; one that can't be read fails the
    /// check), or where there is none from `ps -o lstart=` (descriptors by
    /// `lsof`, which escapes a newline in a name).
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
    lst() { _l=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1; set -- $_l; [ $# -gt 0 ] || return 1; printf '%s' "$*"; }
    pane() { _p=$(t display-message -p -t "=$s:" '#{pane_pid} #{pane_dead}' 2>/dev/null) || return 1; set -- $_p; [ "$1" = "$pid" ] && [ "${2:-0}" = 0 ]; }
    root=$HOME/.gemini/antigravity-cli/presence
    canon=$(cd -- "$root" 2>/dev/null && pwd -P && printf x) && { canon=${canon%x}; canon=${canon%"$NL"}; } || canon=
    ids=; n=0
    match() {
      _name=
      case $1 in "$root"/*) _name=${1#"$root"/} ;; esac
      if [ -z "$_name" ] && [ -n "$canon" ]; then case $1 in "$canon"/*) _name=${1#"$canon"/} ;; esac; fi
      case $_name in *.lock) _id=${_name%.lock} ;; *) return 0 ;; esac
      case $_id in ''|*[!0-9a-f-]*) return 0 ;; esac
      case "$NL$ids" in *"$NL$_id$NL"*) ;; *) ids="$ids$_id$NL"; n=$((n + 1)) ;; esac
    }
    pane || no retry "tmux doesn't name this process as the session's live pane"
    if [ -d "$P" ]; then
      [ -n "$start" ] || no retry "Temple hasn't seen this session's process start"
      st "$pid" || no ended "the session's process has ended"
      [ "$begin" = "$start" ] || no ended "the session's process has ended"
      [ -d "$P/$pid/fd" ] || no ended "the session's process has ended"
      { [ -r "$P/$pid/fd" ] && [ -x "$P/$pid/fd" ]; } || no lasting "the session's open files can't be read"
      for fd in "$P/$pid/fd"/*; do
        [ -e "$fd" ] || [ -L "$fd" ] || continue
        l=$(readlink "$fd" 2>/dev/null && printf x) || no retry "one of the session's open files couldn't be read"
        l=${l%x}; l=${l%"$NL"}
        match "$l"
      done
      st "$pid" && [ "$begin" = "$start" ] || no ended "the session's process has ended"
    else
      L=$(command -v lsof 2>/dev/null) || { [ -x /usr/sbin/lsof ] && L=/usr/sbin/lsof; } || no lasting "this host has neither /proc nor lsof"
      b=$(lst "$pid") || no ended "the session's process has ended"
      [ -z "$start" ] || [ "$b" = "$start" ] || no ended "the session's process has ended"
      out=$("$L" -n -P -w -a -p "$pid" -Fn 2>/dev/null </dev/null) || no retry "lsof couldn't list the session's open files"
      a=$(lst "$pid") && [ "$a" = "$b" ] || no ended "the session's process has ended"
      while IFS= read -r line; do case $line in n*) match "${line#n}" ;; esac; done <<EOF
    $out
    EOF
    fi
    pane || no retry "tmux doesn't name this process as the session's live pane"
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

    /// Where a conversation's database is, as a read takes it (`~` is the
    /// host's home), and its summaries.
    static func database(_ id: String) -> String { "~/" + storeFolder + "/conversations/" + id + ".db" }
    static let summaries = "~/" + storeFolder + "/conversation_summaries.db"

    // MARK: Suggestions

    /// Arguments `since` (`agy`'s time text, UTC). Prints `now<TAB><epoch>`,
    /// then, per conversation whose summary row changed since then,
    /// `conv<TAB><hex id><TAB><hex workspace_uris><TAB><hex parent>`, newest
    /// first, then `done`; or `unavailable<TAB><why>`. Only the summaries
    /// are read: the candidates' own databases are read afterwards, for the
    /// few in the run's folder (`headsScript`).
    static let listScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    since=$1
    sum=$HOME/.gemini/antigravity-cli/conversation_summaries.db
    printf 'now\t%s\n' "$(date +%s)"
    temple_there "$sum" || { printf 'done\n'; exit 0; }
    [ -n "$AGY_SQ$AGY_PY" ] || { printf 'unavailable\t%s\n' "$NOREADER"; exit 0; }
    case $since in ''|*[!0-9:.\ +-]*) printf 'unavailable\tno start time\n'; exit 0 ;; esac
    temple_agy_dir || { printf 'unavailable\tno temporary folder on the host\n'; exit 0; }
    temple_read_db "$sum" "SELECT 'conv', hex(conversation_id), hex(workspace_uris), hex(parent_conversation_id) FROM conversation_summaries WHERE last_modified_time >= '$since' ORDER BY last_modified_time DESC LIMIT 501"
    case $? in
      0) r=$(cat "$AGY_OUT") || { printf 'unavailable\tthe answer could not be read back\n'; exit 0; }
         [ -z "$r" ] || printf '%s\n' "$r" ;;
      *) printf 'unavailable\t%s\n' "$(printf '%s' "${AGY_ERR:-the conversations could not be listed}" | head -n 1)"; exit 0 ;;
    esac
    printf 'done\n'
    """#

    static var listProgram: String { "NOREADER=" + RemoteQuoting.quote(noReader) + "\n" + listScript }

    /// Arguments: conversation ids. Per id `head<TAB><hex id>`, its
    /// database's rows (`id`, `step`, every column hex) and `end`, or
    /// `skip<TAB><hex id>` when its database can't be read; then `done`.
    static let headsScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    [ -n "$AGY_SQ$AGY_PY" ] || { printf 'unavailable\t%s\n' "$NOREADER"; exit 0; }
    temple_agy_dir || { printf 'unavailable\tno temporary folder on the host\n'; exit 0; }
    for c; do
      x=$(printf '%s' "$c" | temple_hex)
      case $c in ''|*[!0-9a-f-]*) printf 'skip\t%s\n' "$x"; continue ;; esac
      db=$HOME/.gemini/antigravity-cli/conversations/$c.db
      if [ -f "$db" ] && [ ! -L "$db" ] && temple_read_db "$db" "$IDS; $STEP" && r=$(cat "$AGY_OUT"); then
        printf 'head\t%s\n' "$x"; [ -z "$r" ] || printf '%s\n' "$r"; printf 'end\n'
      else
        printf 'skip\t%s\n' "$x"
      fi
    done
    printf 'done\n'
    """#

    /// A candidate's first step, read up to this much: the prompt and its
    /// time (a longer first prompt is "couldn't be read").
    static let headBytes = 256 * 1024
    /// At most this many candidates are read and offered (newest first):
    /// their heads, hex-encoded, stay well inside one answer's cap.
    static let offerLimit = 8

    static var headsProgram: String {
        ["IDS=" + RemoteQuoting.quote(idsQuery), "STEP=" + RemoteQuoting.quote(stepQuery(limit: headBytes)),
         "NOREADER=" + RemoteQuoting.quote(noReader)].joined(separator: "\n") + "\n" + headsScript
    }

    static let listDeadline: TimeInterval = 30
    static let listLimit = 500

    struct Listed: Equatable {
        let id: String
        let workspaceURIs: String
        let parent: String
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
        if let last = lines.last, last.hasPrefix("unavailable\t") { return .unavailable(String(last.dropFirst(12))) }
        guard let first = lines.first, first.hasPrefix("now\t"), let now = Int(first.dropFirst(4)) else {
            return .unavailable("the lookup printed nothing Temple expected")
        }
        guard lines.count >= 2, lines.last == "done" else { return .unavailable("the lookup's answer was cut short") }
        var found: [Listed] = []
        for line in lines.dropFirst().dropLast() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[0] == "conv", let id = utf8(fields[1]), let uris = utf8(fields[2]),
                  let parent = utf8(fields[3]) else { return .unavailable("the lookup printed nothing Temple expected") }
            found.append(Listed(id: id, workspaceURIs: uris, parent: parent))
        }
        guard found.count <= listLimit else { return .unavailable("too many conversations to list") }
        return .conversations(remoteNow: now, found)
    }

    /// The conversations that may be the run's, before their databases are
    /// read: a person's (no parent), in the run's folder (its one
    /// workspace, by bytes), not another run's, not declined; newest first,
    /// at most `offerLimit`.
    static func inFolder(_ listed: [Listed], directory: String, declined: Set<RemotePath>,
                         held: Set<String>) -> [Listed] {
        let folder = RemotePath(directory)
        var seen = Set<String>()
        return Array(listed.filter { conversation in
            let id = conversation.id
            return UUID(uuidString: id) != nil && id == id.lowercased() && seen.insert(id).inserted
                && conversation.parent.isEmpty && !held.contains(id) && !declined.contains(RemotePath(declineKey(id)))
                && AntigravityFormat.folder(conversation.workspaceURIs).map { RemotePath($0) == folder } == true
        }.prefix(offerLimit))
    }

    /// What one candidate's database said.
    enum Head: Equatable {
        case read(AntigravityFormat.Record)
        case unreadable
    }

    /// The candidates' databases, by id; nil when the answer is not whole.
    static func heads(_ ids: [String], using exec: RemoteExec) async -> [String: Head]? {
        guard !ids.isEmpty else { return [:] }
        guard let output = try? await exec.run(script: headsProgram, args: ids, deadline: listDeadline),
              output.reachedCommand, output.status == 0 else { return nil }
        return parseHeads(output.data)
    }

    static func parseHeads(_ data: Data) -> [String: Head]? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("done\n") else { return nil }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var heads: [String: Head] = [:]
        var index = 0
        while index < lines.count - 1 {
            let fields = lines[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, let id = utf8(fields[1]), heads[id] == nil else { return nil }
            switch fields[0] {
            case "skip":
                heads[id] = .unreadable
                index += 1
            case "head":
                index += 1
                var ids: [String] = []
                var sawStep = false
                var step: String?
                while index < lines.count - 1, lines[index] != "end" {
                    let row = lines[index].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    switch (row.first, row.count) {
                    case ("id", 2):
                        guard let value = utf8(row[1]) else { return nil }
                        if !value.isEmpty { ids.append(value) }
                    case ("step", 2) where !sawStep:
                        guard let bytes = RemoteTranscripts.hexBytes(row[1]) else { return nil }
                        sawStep = true
                        step = bytes.isEmpty ? nil : bytes.base64EncodedString()
                    default:
                        return nil
                    }
                    index += 1
                }
                guard index < lines.count - 1 else { return nil }
                heads[id] = .read(AntigravityFormat.Record(ids: ids, summary: nil, firstUserStep: step))
                index += 1
            default:
                return nil
            }
        }
        guard lines.last == "done" else { return nil }
        return heads
    }

    /// The question's candidates from their heads: the database must be the
    /// conversation the summary named (its own ids), and its first prompt
    /// sent inside [`since`, `until`] on the host's clock. Nil when one in
    /// the folder couldn't be read, or its first step isn't whole: the
    /// question would then be incomplete, and is not asked.
    static func eligible(_ candidates: [Listed], heads: [String: Head], since: Int, until: Date) -> [CodexSuggestion]? {
        let from = Date(timeIntervalSince1970: TimeInterval(since - 1))
        var offered: [CodexSuggestion] = []
        for candidate in candidates {
            guard case .read(let record)? = heads[candidate.id] else { return nil }
            guard record.ids.contains(where: { $0.lowercased() == candidate.id }) else { continue }
            guard let step = record.firstUserStep else { continue }
            guard let first = AntigravityFormat.firstPrompt(step), let started = first.at else { return nil }
            guard started >= from, started <= until, let folder = AntigravityFormat.folder(candidate.workspaceURIs) else { continue }
            offered.append(CodexSuggestion(rolloutPath: declineKey(candidate.id), sessionID: candidate.id,
                                           firstPrompt: first.prompt, startedAt: started, directory: folder,
                                           promptKnown: true))
        }
        return offered.sorted { $0.startedAt > $1.startedAt }
    }

    /// What a declined conversation is kept under (the run store's
    /// `rollout_path`): its database, named from the store's folder.
    static func declineKey(_ id: String) -> String { database(id) }
}
