import Foundation
import TempleCore

// Codex identity on a host (docs/designs/remote-ssh.md section 3, phase 1b).
// Codex mints its own session id, so a new Codex run starts pending. Temple
// learns the id in one of two ways and no other:
//
// - **Verified**, automatically: the run's own process tree holds exactly
//   one rollout open for writing, whose header names the same id as its
//   file name, and the tree was read whole. Anything else is inconclusive.
// - **Confirmed** by the user: rollouts in the run's folder that began
//   while it ran are offered as a question; nothing is adopted without a
//   yes. This is not discovery: it runs only for a run Temple started, and
//   shows nothing that is not a candidate for that run.

/// Where a run's Codex keeps its sessions, as its pane recorded it: set
/// (absolute, or relative to the folder the pane ran in, as Codex reads
/// it) or unset (`~/.codex`). Nil when Temple doesn't know, or the value is
/// empty (how Codex reads that is not established): never a guess.
public enum CodexHomeRoot {
    static func arguments(_ home: RemoteEnvironment.CodexHome?, base: String?) -> (state: String, value: String, base: String)? {
        switch home {
        case .unset?: return ("unset", "", base ?? "")
        case .set(let value)? where value.isEmpty: return nil
        case .set(let value)? where value.hasPrefix("/"): return ("set", value, base ?? "")
        case .set(let value)?:
            guard let base else { return nil }
            return ("set", value, base)
        case nil: return nil
        }
    }

    /// Shell: resolves the home from `$hs $hv $base` into `$h` (canonical,
    /// `pwd -P`, captured with a sentinel so a name ending in a newline
    /// keeps it), or calls `nohome <reason>`.
    static let resolve = #"""
    CODEX_NL='
    '
    case $hs in
      set) case $hv in /*) d=$hv ;; *) d=$base/$hv ;; esac ;;
      unset) d=$HOME/.codex ;;
      *) nohome "Temple doesn't know which Codex home this session used" ;;
    esac
    h=$(cd -- "$d" 2>/dev/null && pwd -P && printf x) || nohome "the Codex home $d can't be entered"
    h=${h%x}; h=${h%"$CODEX_NL"}
    """#
}

/// The automatic check: the pane's process tree, by `/proc`.
public enum CodexIdentityCheck {
    /// Why a check proved nothing, and whether trying again can help.
    public enum Inconclusive: Sendable, Equatable {
        /// Nothing conclusive at this instant: tried again on schedule.
        case retry(String)
        /// It never will be for this run (no `/proc`, a shared Codex
        /// server writes the transcript, the home is unknown): the
        /// suggestions take over at once.
        case lasting(String)
        /// The run's process has ended: only the suggestions can help.
        case ended(String)

        public var reason: String {
            switch self {
            case .retry(let reason), .lasting(let reason), .ended(let reason): reason
            }
        }
    }

    public enum Answer: Sendable, Equatable {
        /// Exactly one rollout open for writing in the tree: its path and
        /// its first line (the header), raw.
        case found(path: String, header: Data)
        case inconclusive(Inconclusive)
    }

    /// Arguments `proc pid start socket session hs hv base`. Verifies the
    /// pane pid is alive with its recorded start time and that tmux names
    /// it as the session's pane; walks the processes whose parent chain
    /// leads to it (descendants only, each started no earlier than its
    /// parent, to a depth of 4); collects every descriptor in that tree that
    /// links to `<home>/sessions/**/rollout-*.jsonl` and is open for writing
    /// (`fdinfo` flags, octal, access mode exactly 1 or 2); re-reads each
    /// process's start time after its descriptors, so a process that
    /// vanished or whose pid was reused makes the walk inconclusive. Any
    /// read that fails (a `stat`, a descriptor's link, its `fdinfo`) is
    /// inconclusive, never skipped.
    ///
    /// Only the run's own process counts as a writer (round 2): the pane's
    /// process itself, the one the launch `exec`ed. A rollout held by
    /// anything else in the tree (any child, any deeper descendant, a codex
    /// behind an npm launcher, Codex's shared app server) proves nothing
    /// about this run: when only such processes hold one, the walk is
    /// inconclusive for good and the question takes over. (Round 1 also
    /// accepted a launcher's child by its arguments; two review rounds found
    /// that evidence insufficient, so the exception is gone.)
    ///
    /// Prints `inconclusive<TAB><kind><TAB><reason>`, or `found<TAB><hex
    /// path>`, then `header`, then the rollout's first line. `stat` is read
    /// with `read` (no process per entry) and past its last `)`.
    static let script = #"""
    P=$1; pid=$2; start=$3; sock=$4; s=$5; hs=$6; hv=$7; base=$8
    NL='
    '
    no() { printf 'inconclusive\t%s\t%s\n' "$1" "$2"; exit 0; }
    nohome() { no lasting "$1"; }
    st() { _s=; IFS= read -r _s < "$P/$1/stat" 2>/dev/null || return 1; _s=${_s##*)}; set -- $_s; [ $# -ge 20 ] || return 1; ppid=$2; begin=${20}; return 0; }
    t() { if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux -L temple "$@"; fi; }
    [ -d "$P" ] || no lasting "this host has no /proc"
    \#(CodexHomeRoot.resolve)
    sess=$h/sessions
    st "$pid" || no ended "the session's process has ended"
    [ "$begin" = "$start" ] || no ended "the session's process has ended"
    pp=$(t display-message -p -t "=$s:" '#{pane_pid}' 2>/dev/null)
    [ "$pp" = "$pid" ] || no retry "tmux doesn't name this process as the session's pane"
    list=
    for d in "$P"/[0-9]*; do
      [ -d "$d" ] || continue
      p=${d##*/}
      if st "$p"; then list="$list$p $ppid $begin$NL"
      elif [ -e "$d/stat" ]; then no retry "a process's stat couldn't be read"
      fi
    done
    tree="$pid:$start:0"; frontier=$tree; depth=0
    while [ -n "$frontier" ] && [ "$depth" -lt 4 ]; do
      next=
      for f in $frontier; do
        fp=${f%%:*}; rest=${f#*:}; fb=${rest%%:*}
        while read -r cp cpp cb; do
          [ "$cpp" = "$fp" ] && [ "$cb" -ge "$fb" ] && next="$next $cp:$cb:$((depth + 1))"
        done <<EOF
    $list
    EOF
      done
      tree="$tree$next"; frontier=$next; depth=$((depth + 1))
    done
    found=; n=0; foreign=
    for m in $tree; do
      p=${m%%:*}; rest=${m#*:}; b=${rest%%:*}; dp=${rest#*:}
      [ -d "$P/$p/fd" ] || no retry "a process ended during the check"
      { [ -r "$P/$p/fd" ] && [ -x "$P/$p/fd" ]; } || no retry "a process's open files couldn't be read"
      for fd in "$P/$p/fd"/*; do
        [ -e "$fd" ] || [ -L "$fd" ] || continue
        l=$(readlink "$fd" 2>/dev/null) || no retry "a process's open file couldn't be read"
        case $l in "$sess"/*rollout-*.jsonl) ;; *) continue ;; esac
        fl=
        while IFS= read -r line; do case $line in flags:*) fl=${line#flags:}; break ;; esac; done < "$P/$p/fdinfo/${fd##*/}" 2>/dev/null
        fl=${fl#"${fl%%[!	 ]*}"}
        case $fl in ''|*[!0-7]*) no retry "a session file's flags couldn't be read" ;; esac
        am=$(( 0$fl % 4 ))
        [ "$am" -eq 1 ] || [ "$am" -eq 2 ] || continue
        if [ "$dp" -ne 0 ]; then foreign=yes; continue; fi
        case "$NL$found" in *"$NL$l$NL"*) ;; *) found="$found$l$NL"; n=$((n + 1)) ;; esac
      done
      st "$p" && [ "$begin" = "$b" ] || no retry "a process ended during the check"
    done
    if [ "$n" -eq 0 ]; then
      [ -n "$foreign" ] && no lasting "the session file is held by a process Temple didn't start"
      no retry "no session file is open right now"
    fi
    [ "$n" -gt 1 ] && no retry "more than one session file is open"
    r=${found%"$NL"}
    printf 'found\t%s\n' "$(printf '%s' "$r" | od -An -tx1 | tr -d ' \n')"
    printf 'header\n'
    head -c 65536 "$r" | head -n 1
    """#

    public static let deadline: TimeInterval = 15

    public static func run(proc: String, panePID: Int, paneStart: String, socket: String?, session: String,
                           home: (state: String, value: String, base: String), using exec: RemoteExec) async -> Answer {
        precondition(RemoteQuoting.isSafeToken(session))
        do {
            let output = try await exec.run(script: script,
                                            args: [proc, String(panePID), paneStart, socket ?? "", session,
                                                   home.state, home.value, home.base],
                                            deadline: deadline)
            guard output.reachedCommand, output.status == 0 else {
                return .inconclusive(.retry(output.firstErrorLine ?? "ssh exited with status \(output.status)"))
            }
            return parse(Data(output.stdout.utf8))
        } catch {
            return .inconclusive(.retry(error.localizedDescription))
        }
    }

    static func parse(_ data: Data) -> Answer {
        guard let newline = data.firstIndex(of: 0x0a) else { return .inconclusive(.retry("the check printed nothing Temple expected")) }
        let head = String(decoding: data[..<newline], as: UTF8.self)
        let fields = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if fields.first == "inconclusive", fields.count == 3 {
            switch fields[1] {
            case "lasting": return .inconclusive(.lasting(fields[2]))
            case "ended": return .inconclusive(.ended(fields[2]))
            default: return .inconclusive(.retry(fields[2]))
            }
        }
        guard fields.first == "found", fields.count == 2, let path = LaunchRecords.hex(fields[1]) else {
            return .inconclusive(.retry("the check printed nothing Temple expected"))
        }
        let rest = data[data.index(after: newline)...]
        let marker = Data("header\n".utf8)
        guard rest.starts(with: marker) else { return .inconclusive(.retry("the check printed no header")) }
        var header = Data(rest.dropFirst(marker.count))
        if header.last == 0x0a { header.removeLast() }
        return .found(path: path, header: header)
    }

    /// Whether a found rollout is the run's: its header names the same id
    /// as its file name, it is a session a person started (not a subagent's
    /// thread), and it runs in the run's own folder. The id, or nil.
    static func verify(path: String, header: Data, directory: String) -> String? {
        let format = CodexFormat()
        guard let named = format.name(path: path)?.threadID,
              let candidate = (try? format.header(firstLine: header)) ?? nil,
              candidate.id.lowercased() == named, candidate.cwd == directory else { return nil }
        return candidate.id
    }
}

/// A rollout that may be a pending run's session, for the user to confirm
/// or decline. Never adopted without a yes.
public struct CodexSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { rolloutPath }
    public let rolloutPath: String
    public let sessionID: String
    /// The first thing typed into it; nil when it has none yet (or, when
    /// `promptKnown` is false, when its head couldn't be read).
    public let firstPrompt: String?
    /// Whether `firstPrompt` is known: false when the head could not be read
    /// or was cut short before a prompt; never shown as "no prompt" then.
    public let promptKnown: Bool
    /// When it began, on the host's clock.
    public let startedAt: Date
    /// Its folder (the run's own).
    public let directory: String

    public init(rolloutPath: String, sessionID: String, firstPrompt: String?, startedAt: Date, directory: String,
                promptKnown: Bool = true) {
        self.rolloutPath = rolloutPath; self.sessionID = sessionID; self.firstPrompt = firstPrompt
        self.startedAt = startedAt; self.directory = directory; self.promptKnown = promptKnown
    }
}

/// The suggestion lookup: rollouts under the run's Codex home touched since
/// the run's `ok`, whose first line names the run's folder. The caller keeps
/// those that are eligible (begun inside the run's window, not declined, not
/// an id another run holds), then reads the heads of at most `limit` of them
/// for their first prompt. Paths travel as arguments and hex, never split on
/// a newline; a file that can't be read, a traversal that fails, or output
/// that is not framed whole makes the lookup unavailable, never a partial
/// list.
public enum CodexSuggestionLookup {
    public enum Listing: Sendable, Equatable {
        /// The host's clock now, and each candidate's path and first line.
        case headers(remoteNow: Int, [Candidate])
        case unavailable(String)
    }

    public struct Candidate: Sendable, Equatable {
        public let path: String
        public let header: Data
    }

    /// How much of each offered candidate is read: the header and the first
    /// prompt (Codex puts its instructions in the header line, about 20 KB).
    public static let headBytes = 256 * 1024
    /// At most this many eligible candidates are offered (newest first).
    public static let limit = 20
    /// A folder with more rollouts than this since the run began is not
    /// listed (unavailable, never truncated).
    public static let listLimit = 500

    /// Arguments `hs hv base since needle`: `needle` is the run's folder as
    /// JSON spells it, quoted. Prints `now<TAB><epoch>`, then per file whose
    /// first line contains the needle `file<TAB><hex path><TAB><bytes>`, that
    /// line, and `\nend`; then `done`, or `unavailable<TAB><reason>`.
    static let listScript = #"""
    hs=$1; hv=$2; base=$3; since=$4; needle=$5
    nohome() { printf 'unavailable\t%s\n' "$1"; exit 0; }
    \#(CodexHomeRoot.resolve)
    now=$(date +%s)
    printf 'now\t%s\n' "$now"
    [ -d "$h/sessions" ] || { printf 'done\n'; exit 0; }
    m=$(( (now - since) / 60 + 2 ))
    if find "$h/sessions" -type f -name 'rollout-*.jsonl' -mmin "-$m" -exec sh -c '
      NL="
    "
      needle=$1; shift
      for f; do
        l=$(head -c 65536 -- "$f") || exit 3
        l=${l%%"$NL"*}
        case $l in *"$needle"*) ;; *) continue ;; esac
        printf "file\t%s\t%s\n" "$(printf "%s" "$f" | od -An -tx1 | tr -d " \n")" "$(printf "%s" "$l" | wc -c | tr -d " ")"
        printf "%s\nend\n" "$l"
      done' temple-scan "$needle" {} +; then
      printf 'done\n'
    else
      printf 'unavailable\t%s\n' "not every session file could be read"
    fi
    """#

    /// Arguments: paths. Prints per path `head<TAB><hex path><TAB><bytes>`,
    /// that much of its head and `\nend`, or `skip<TAB><hex path>` when it
    /// can't be read; then `done`. The head is captured with a sentinel, so
    /// trailing newlines are kept and a head cut at the cap reads as cut.
    static let headsScript = #"""
    for f; do
      x=$(printf '%s' "$f" | od -An -tx1 | tr -d ' \n')
      t=$(head -c \#(headBytes) -- "$f" && printf x) || { printf 'skip\t%s\n' "$x"; continue; }
      t=${t%x}
      printf 'head\t%s\t%s\n' "$x" "$(printf '%s' "$t" | wc -c | tr -d ' ')"
      printf '%s\nend\n' "$t"
    done
    printf 'done\n'
    """#

    public static let deadline: TimeInterval = 20

    /// The folder as serde_json writes it inside a string: `"` and `\`
    /// escaped, control characters as `\n` and friends or `\u00XX`, and
    /// nothing else (`/` and non-ASCII stay as they are), quoted.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    public static func list(home: (state: String, value: String, base: String), since: Int, directory: String,
                            using exec: RemoteExec) async -> Listing {
        do {
            let output = try await exec.run(script: listScript,
                                            args: [home.state, home.value, home.base, String(since), jsonString(directory)],
                                            deadline: deadline)
            guard output.reachedCommand, output.status == 0 else {
                return .unavailable(output.firstErrorLine ?? "ssh exited with status \(output.status)")
            }
            return parseList(Data(output.stdout.utf8))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// The heads of `paths`, by path; one that can't be read is missing
    /// (its question shows no prompt). Nil when the answer is not whole.
    public static func heads(_ paths: [String], using exec: RemoteExec) async -> [String: Data]? {
        guard !paths.isEmpty else { return [:] }
        guard let output = try? await exec.run(script: headsScript, args: paths, deadline: deadline),
              output.reachedCommand, output.status == 0,
              let frames = frames(Data(output.stdout.utf8), tags: ["head"], skips: ["skip"]) else { return nil }
        return Dictionary(frames.map { ($0.path, $0.body) }, uniquingKeysWith: { first, _ in first })
    }

    static func parseList(_ data: Data) -> Listing {
        guard let newline = data.firstIndex(of: 0x0a) else { return .unavailable("the lookup printed nothing Temple expected") }
        let first = String(decoding: data[..<newline], as: UTF8.self)
        if first.hasPrefix("unavailable\t") { return .unavailable(String(first.dropFirst("unavailable\t".count))) }
        guard first.hasPrefix("now\t"), let now = Int(first.dropFirst(4)) else {
            return .unavailable("the lookup printed nothing Temple expected")
        }
        let rest = Data(data[data.index(after: newline)...])
        if let unavailable = lastLine(rest), unavailable.hasPrefix("unavailable\t") {
            return .unavailable(String(unavailable.dropFirst("unavailable\t".count)))
        }
        guard let frames = frames(rest, tags: ["file"], skips: []) else {
            return .unavailable("the lookup's answer was cut short")
        }
        guard frames.count <= listLimit else { return .unavailable("too many sessions in this folder to list") }
        return .headers(remoteNow: now, frames.map { Candidate(path: $0.path, header: $0.body) })
    }

    private static func lastLine(_ data: Data) -> String? {
        var trimmed = data
        if trimmed.last == 0x0a { trimmed.removeLast() }
        let start = trimmed.lastIndex(of: 0x0a).map { trimmed.index(after: $0) } ?? trimmed.startIndex
        return String(decoding: trimmed[start...], as: UTF8.self)
    }

    /// Strict framing: `<tag><TAB><hex path><TAB><bytes>`, exactly that many
    /// bytes, `\nend\n`; `<skip><TAB><hex path>` lines; and a final `done`
    /// with nothing after it. Anything else is nil.
    static func frames(_ data: Data, tags: Set<String>, skips: Set<String>) -> [(path: String, body: Data)]? {
        var index = data.startIndex
        var frames: [(path: String, body: Data)] = []
        let end = Data("\nend\n".utf8)
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: 0x0a) else { return nil }
            let line = String(decoding: data[index..<newline], as: UTF8.self)
            index = data.index(after: newline)
            if line == "done" { return index == data.endIndex ? frames : nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if let tag = fields.first, skips.contains(tag), fields.count == 2, LaunchRecords.hex(fields[1]) != nil { continue }
            guard let tag = fields.first, tags.contains(tag), fields.count == 3, let path = LaunchRecords.hex(fields[1]),
                  let count = Int(fields[2]), count >= 0 else { return nil }
            // By subtraction: a length near Int.max must not overflow.
            let remaining = data.distance(from: index, to: data.endIndex)
            guard remaining >= end.count, count <= remaining - end.count else { return nil }
            let bodyEnd = data.index(index, offsetBy: count)
            guard data[bodyEnd..<data.index(bodyEnd, offsetBy: end.count)].elementsEqual(end) else { return nil }
            frames.append((path, Data(data[index..<bodyEnd])))
            index = data.index(bodyEnd, offsetBy: end.count)
        }
        return nil
    }

    /// The eligible candidates for a run: a header that parses as a session
    /// a person started, whose id is also its file name's, in the run's
    /// folder, begun inside [`since`, `until`] on the host's clock; not
    /// declined, and not an id another run holds. Newest first, without
    /// their prompts yet.
    static func eligible(_ candidates: [Candidate], directory: String, since: Int, until: Date,
                         declined: Set<String>, held: Set<String>) -> [CodexSuggestion] {
        let format = CodexFormat()
        let from = Date(timeIntervalSince1970: TimeInterval(since - 1))
        var seen = Set<String>()
        return candidates.compactMap { file -> CodexSuggestion? in
            guard !declined.contains(file.path), seen.insert(file.path).inserted else { return nil }
            guard let named = format.name(path: file.path)?.threadID,
                  let candidate = (try? format.header(firstLine: file.header)) ?? nil,
                  candidate.id.lowercased() == named, candidate.cwd == directory,
                  candidate.createdAt >= from, candidate.createdAt <= until,
                  !held.contains(candidate.id) else { return nil }
            return CodexSuggestion(rolloutPath: file.path, sessionID: candidate.id, firstPrompt: nil,
                                   startedAt: candidate.createdAt, directory: candidate.cwd)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// The same suggestions with the first prompt each head holds. `heads`
    /// nil (the query failed or its answer was not whole), a head that
    /// couldn't be read, or one cut short before any prompt: the prompt is
    /// unknown, never "no prompt" (round 2).
    static func withPrompts(_ suggestions: [CodexSuggestion], heads: [String: Data]?) -> [CodexSuggestion] {
        suggestions.map {
            let head = heads?[$0.rolloutPath]
            let prompt = head.flatMap(CodexFormat.firstTypedPrompt(in:))
            let known = head.map { prompt != nil || $0.count < headBytes } ?? false
            return CodexSuggestion(rolloutPath: $0.rolloutPath, sessionID: $0.sessionID, firstPrompt: prompt,
                                   startedAt: $0.startedAt, directory: $0.directory, promptKnown: known)
        }
    }
}
