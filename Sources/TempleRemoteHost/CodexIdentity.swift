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
    /// read that fails (a `stat`, a descriptor's link, its `fdinfo`, a
    /// `cmdline` or an `exe`) is inconclusive, never skipped.
    ///
    /// Only the run's own process counts as a writer (round 1): the pane's
    /// process itself, or, when the pane is a launcher shim (an interpreter
    /// running a script named `codex` or `codex.js`, as Codex's npm package
    /// installs), its direct child that is the launched CLI: an executable
    /// whose name begins with `codex`, given exactly the arguments the pane
    /// was given after the script. A rollout held by anything else in the
    /// tree (another child, any deeper descendant, Codex's shared app
    /// server) proves nothing about this run: when only such processes hold
    /// one, the walk is inconclusive for good and the question takes over.
    ///
    /// Prints `inconclusive<TAB><kind><TAB><reason>`, or `found<TAB><hex
    /// path>`, then `header`, then the rollout's first line. `stat` is read
    /// with `read` (no process per entry) and past its last `)`.
    static let script = #"""
    P=$1; pid=$2; start=$3; sock=$4; s=$5; hs=$6; hv=$7; base=$8
    NL='
    '
    SEP=$(printf '\001')
    no() { printf 'inconclusive\t%s\t%s\n' "$1" "$2"; exit 0; }
    nohome() { no lasting "$1"; }
    st() { _s=; IFS= read -r _s < "$P/$1/stat" 2>/dev/null || return 1; _s=${_s##*)}; set -- $_s; [ $# -ge 20 ] || return 1; ppid=$2; begin=${20}; return 0; }
    t() { if [ -n "$sock" ]; then tmux -S "$sock" "$@"; else tmux -L temple "$@"; fi; }
    args() { tr '\0' "$SEP" < "$P/$1/cmdline" 2>/dev/null; }
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
    # The pane as a launcher shim: the script it runs, and the arguments
    # after it, which the launched CLI must have been given.
    pa=$(args "$pid") || no retry "the session's process couldn't be read"
    pexe=$(readlink "$P/$pid/exe" 2>/dev/null) || no retry "the session's process couldn't be read"
    shim=; tail=
    case ${pexe##*/} in codex*) ;; *)
      rest=${pa#*"$SEP"}
      while [ -n "$rest" ]; do
        case $rest in *"$SEP"*) ;; *) break ;; esac
        a=${rest%%"$SEP"*}; rest=${rest#*"$SEP"}
        case ${a##*/} in codex|codex.js) shim=yes; tail=$rest; break ;; esac
      done ;;
    esac
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
        own=
        if [ "$dp" -eq 0 ]; then own=yes
        elif [ "$dp" -eq 1 ] && [ -n "$shim" ]; then
          ca=$(args "$p") || no retry "a process's arguments couldn't be read"
          ce=$(readlink "$P/$p/exe" 2>/dev/null) || no retry "a process's executable couldn't be read"
          case ${ce##*/} in codex*) [ "${ca#*"$SEP"}" = "$tail" ] && own=yes ;; esac
        fi
        if [ -z "$own" ]; then foreign=yes; continue; fi
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
    /// The first thing typed into it; nil when it has none yet.
    public let firstPrompt: String?
    /// When it began, on the host's clock.
    public let startedAt: Date
    /// Its folder (the run's own).
    public let directory: String

    public init(rolloutPath: String, sessionID: String, firstPrompt: String?, startedAt: Date, directory: String) {
        self.rolloutPath = rolloutPath; self.sessionID = sessionID; self.firstPrompt = firstPrompt
        self.startedAt = startedAt; self.directory = directory
    }
}

/// The suggestion lookup: rollouts under the run's Codex home touched since
/// the run's `ok`, whose header names the run's folder; the caller keeps
/// those that began inside the run's window.
public enum CodexSuggestionLookup {
    public enum Answer: Sendable, Equatable {
        /// The host's clock now, and each candidate's path and the head of
        /// its file (the header first).
        case files(remoteNow: Int, [(path: String, head: Data)])
        case unavailable(String)

        public static func == (lhs: Answer, rhs: Answer) -> Bool {
            switch (lhs, rhs) {
            case (.unavailable(let a), .unavailable(let b)): a == b
            case (.files(let n1, let f1), .files(let n2, let f2)):
                n1 == n2 && f1.map(\.path) == f2.map(\.path) && f1.map(\.head) == f2.map(\.head)
            default: false
            }
        }
    }

    /// How much of each candidate is read: the header and the first prompt
    /// (Codex puts its instructions in the header line, about 20 KB).
    public static let headBytes = 256 * 1024
    /// At most this many candidates are read.
    public static let limit = 20

    /// Arguments `hs hv base since needle`: `needle` is the run's folder as
    /// JSON spells it, quoted; only files whose first line contains it are
    /// read. Prints `now<TAB><epoch>`, then per candidate
    /// `file<TAB><hex path><TAB><bytes>` and that many bytes of its head;
    /// `unavailable<TAB><reason>` when the home can't be read.
    static let script = #"""
    hs=$1; hv=$2; base=$3; since=$4; needle=$5
    nohome() { printf 'unavailable\t%s\n' "$1"; exit 0; }
    \#(CodexHomeRoot.resolve)
    now=$(date +%s)
    printf 'now\t%s\n' "$now"
    [ -d "$h/sessions" ] || exit 0
    m=$(( (now - since) / 60 + 2 ))
    k=0
    find "$h/sessions" -type f -name 'rollout-*.jsonl' -mmin "-$m" 2>/dev/null | while IFS= read -r f; do
      [ "$k" -lt \#(limit) ] || break
      l=$(head -c 65536 "$f" 2>/dev/null | head -n 1)
      case $l in *"$needle"*) ;; *) continue ;; esac
      n=$(head -c \#(headBytes) "$f" 2>/dev/null | wc -c | tr -d ' ')
      printf 'file\t%s\t%s\n' "$(printf '%s' "$f" | od -An -tx1 | tr -d ' \n')" "$n"
      head -c "$n" "$f"
      k=$((k + 1))
    done
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

    public static func run(home: (state: String, value: String, base: String), since: Int, directory: String,
                           using exec: RemoteExec) async -> Answer {
        do {
            let output = try await exec.run(script: script,
                                            args: [home.state, home.value, home.base, String(since), jsonString(directory)],
                                            deadline: deadline)
            guard output.reachedCommand, output.status == 0 else {
                return .unavailable(output.firstErrorLine ?? "ssh exited with status \(output.status)")
            }
            return parse(Data(output.stdout.utf8))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) -> Answer {
        var index = data.startIndex
        var now: Int?
        var files: [(path: String, head: Data)] = []
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: 0x0a) else { break }
            let line = String(decoding: data[index..<newline], as: UTF8.self)
            index = data.index(after: newline)
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "unavailable":
                return .unavailable(fields.dropFirst().joined(separator: "\t"))
            case "now":
                now = fields.count > 1 ? Int(fields[1]) : nil
            case "file":
                guard fields.count == 3, let path = LaunchRecords.hex(fields[1]), let count = Int(fields[2]), count >= 0,
                      data.distance(from: index, to: data.endIndex) >= count else {
                    return .unavailable("the lookup printed something Temple didn't expect")
                }
                let end = data.index(index, offsetBy: count)
                files.append((path, Data(data[index..<end])))
                index = end
            default:
                return .unavailable("the lookup printed something Temple didn't expect")
            }
        }
        guard let now else { return .unavailable("the lookup printed nothing Temple expected") }
        return .files(remoteNow: now, files)
    }

    /// The candidates for a run: a header that parses as a session a person
    /// started, whose id is also its file name's, in the run's folder,
    /// begun inside [`since`, `until`] on the host's clock; not declined,
    /// and not an id another run holds. Newest first.
    static func candidates(_ files: [(path: String, head: Data)], directory: String, since: Int, until: Date,
                           declined: Set<String>, held: Set<String>) -> [CodexSuggestion] {
        let format = CodexFormat()
        let from = Date(timeIntervalSince1970: TimeInterval(since - 1))
        var seen = Set<String>()
        return files.compactMap { file -> CodexSuggestion? in
            guard !declined.contains(file.path), seen.insert(file.path).inserted else { return nil }
            let firstLine = file.head.split(separator: 0x0a, maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
            guard let named = format.name(path: file.path)?.threadID,
                  let candidate = (try? format.header(firstLine: Data(firstLine))) ?? nil,
                  candidate.id.lowercased() == named, candidate.cwd == directory,
                  candidate.createdAt >= from, candidate.createdAt <= until,
                  !held.contains(candidate.id) else { return nil }
            return CodexSuggestion(rolloutPath: file.path, sessionID: candidate.id,
                                   firstPrompt: CodexFormat.firstTypedPrompt(in: file.head),
                                   startedAt: candidate.createdAt, directory: candidate.cwd)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}
