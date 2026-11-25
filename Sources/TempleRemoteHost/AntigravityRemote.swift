import Foundation
import TempleCore

// Antigravity (`agy`) on a host (ADR-044). Its store is SQLite under
// `$HOME/.gemini/antigravity-cli` (`agy` has no variable to move it), so a
// read runs the host's own `sqlite3` (part of macOS) and prints each column
// hex-encoded: the columns travel as bytes, and `AntigravityFormat`
// interprets them exactly as it does on this Mac.
//
// Nothing here creates a file in the store. Measured (2026-11-25, sqlite3
// 3.46 and 3.53 on Linux, 3.54 on macOS): a `mode=ro` open creates `-wal`
// and `-shm` beside a database that has neither (Linux), and `-shm` beside
// a log a crashed writer left without one (everywhere); `mode=ro&immutable=1`
// creates nothing. So a database is read one of three ways, as
// `ReadOnlySQLite` does on this Mac:
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

    /// Shell (after `RemoteTranscripts.common`): `$AGY_SQ`, the host's
    /// `sqlite3` (empty with none), and `temple_read_db <db> <sql>`, which
    /// leaves the rows of `sql` (statements separated by `;`, read in one
    /// transaction), TAB-separated, in `$AGY_OUT`, inside the private folder
    /// `$AGY_DIR`. Status 0, 5 (busy, or a database that kept changing:
    /// read again), 4 (failed; `$AGY_ERR` has the reader's words), 6 (no
    /// reader).
    static let sqlite = #"""
    AGY_SQ=
    if command -v sqlite3 >/dev/null 2>&1; then AGY_SQ=sqlite3; fi
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
            # The writer closed meanwhile: pick again.
            [ "$_s" -eq 4 ] && ! temple_there "$1-wal" && continue
            return "$_s"
          fi
          _b=$(temple_stat "$1") && _bw=$(temple_stat "$1-wal") || continue
          rm -f "$AGY_DIR/c.db" "$AGY_DIR/c.db-wal" "$AGY_DIR/c.db-shm"
          { cp "$1" "$AGY_DIR/c.db" && cp "$1-wal" "$AGY_DIR/c.db-wal"; } 2>/dev/null || continue
          _a=$(temple_stat "$1") && _aw=$(temple_stat "$1-wal") || continue
          { [ "$_a" = "$_b" ] && [ "$_aw" = "$_bw" ] && ! temple_there "$1-shm"; } || continue
          temple_sql mode=rw "$AGY_DIR/c.db" "$2"; _s=$?
          [ "$_s" -eq 5 ] && continue
          return "$_s"
        fi
        _b=$(temple_stat "$1") || return 4
        temple_sql 'mode=ro&immutable=1' "$1" "$2"; _s=$?
        [ "$_s" -eq 5 ] && continue
        [ "$_s" -eq 4 ] && temple_there "$1-wal" && continue
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

    /// Arguments `db summaries id facts`. Prints the database's and its
    /// log's stat (`db<TAB>…`, `wal<TAB>…` or `wal<TAB>none`), the rows
    /// (`id`, `step`, `summary`, every column hex), the stats again, then
    /// `done`. Or `missing`, `busy` (read again), or `unreadable<TAB><why>`
    /// instead, at any point (then nothing more); a session whose rows pass
    /// `$BUDGET` bytes is that session's `unreadable`, never the host's
    /// transport failure.
    static let readScript = RemoteTranscripts.common + "\n" + sqlite + "\n" + #"""
    f=$1; s=$2; id=$3; facts=$4
    case $id in ''|*[!0-9a-f-]*) printf 'unreadable\tnot a conversation id\n'; exit 0 ;; esac
    [ -n "$AGY_SQ" ] || { printf 'unreadable\t%s\n' "$NOREADER"; exit 0; }
    temple_agy_dir || { printf 'unreadable\tno temporary folder on the host\n'; exit 0; }
    stamp() {
      if x=$(temple_stat "$f"); then :
      elif temple_gone "$f"; then printf 'missing\n'; exit 0
      else printf 'unreadable\tthe conversation cannot be examined\n'; exit 0; fi
      if y=$(temple_stat "$f-wal"); then :
      elif temple_gone "$f-wal"; then y=none
      else printf 'unreadable\tthe conversation log cannot be examined\n'; exit 0; fi
      printf 'db\t%s\nwal\t%s\n' "$x" "$y"
    }
    rows() {
      temple_read_db "$1" "$2"
      case $? in
        0) n=$(wc -c < "$AGY_OUT" | tr -d ' ')
           [ "$n" -le "$BUDGET" ] || { printf 'unreadable\tthis session is larger than Temple reads (%s bytes, limit %s)\n' "$n" "$BUDGET"; exit 0; }
           r=$(cat "$AGY_OUT") || { printf 'unreadable\tthe answer could not be read back\n'; exit 0; }
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
    static let noReader = "this host has no sqlite3 to read Antigravity's sessions with"

    /// The read's script with its fixed queries in place (as shell words).
    static var readProgram: String {
        ["IDS=" + RemoteQuoting.quote(idsQuery), "STEP=" + RemoteQuoting.quote(stepQuery(limit: 1 << 20)),
         "SUMMARY=" + RemoteQuoting.quote(summaryQuery), "NOREADER=" + RemoteQuoting.quote(noReader),
         // Two reads of rows (the conversation's, its summary): together
         // inside what one answer may carry.
         "BUDGET=\(RemoteTranscripts.responseBudget / 2)"]
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
        var raw: [String] = []
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
                raw.append(line + "\n" + lines[index + 1])
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
                // Any part of either file's stat that moved, even one the
                // combined version folds away: read again.
                if raw[0] != raw[1] { return .busy }
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
    /// (`AntigravitySessionStore.signature`): a commit lands in the log first,
    /// and a log replaced by one of the same size and time is still another
    /// version.
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
    /// of: `presence/<id>.lock` directly under the store, open in that
    /// process and no other one (a subagent's process holds its own). tmux
    /// names the pid as the session's live pane before and after; the
    /// process's start time is the one the pane recorded at launch and the
    /// same after its descriptors are read: from `/proc` (descriptors by
    /// `readlink`, each matched whole; one that can't be read fails the
    /// check), or where there is none from `ps -o lstart=` before and after
    /// (descriptors by `lsof`, numbered ones only, names with a newline
    /// escaped).
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
      out=$("$L" -n -P -w -a -p "$pid" -Ffn 2>/dev/null </dev/null) || no retry "lsof couldn't list the session's open files"
      a=$(lst "$pid") && [ "$a" = "$b" ] || no ended "the session's process has ended"
      fd=
      while IFS= read -r line; do
        case $line in
          f*) fd=${line#f} ;;
          n*) case $fd in ''|*[!0-9]*) ;; *) match "${line#n}" ;; esac ;;
        esac
      done <<EOF
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

}
