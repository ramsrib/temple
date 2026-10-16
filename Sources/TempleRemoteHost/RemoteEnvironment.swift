import Foundation
import TempleCore

/// The remote login environment, resolved the way `LoginShellEnvironment`
/// resolves this Mac's PATH: ask the account's login shell, login and
/// interactive, because a non-interactive ssh command often has not read the
/// rc file that builds the real environment. One query gives the values
/// Temple uses: PATH (for everything run on the host: probe, launch, tmux,
/// reads, the agent), Claude's config root (`CLAUDE_CONFIG_DIR`, where the
/// agent keeps its transcripts, handed to the agent at launch and the root
/// the transcript check inspects) and Codex's home (`CODEX_HOME`, the same
/// for Codex: handed to the pane, and where the identity check and the
/// suggestions look). When resolution fails, everything uses ssh's default
/// environment instead, and says so.
///
/// Memory only, never persisted.
public struct RemoteEnvironment: Sendable, Equatable {
    /// An environment variable as the login environment holds it.
    public enum Variable: Sendable, Equatable {
        /// Not set: the agent uses its default (`~/.claude`, `~/.codex`).
        case unset
        /// Set, to exactly this (newlines and relative values kept).
        case set(String)
    }

    /// Claude's config root (`CLAUDE_CONFIG_DIR`).
    public typealias ClaudeConfig = Variable
    /// Codex's home (`CODEX_HOME`).
    public typealias CodexHome = Variable

    /// The login shell asked (`$SHELL` on the host).
    public let shell: String
    /// The PATH it gave; nil when it could not be read.
    public let path: String?
    /// Claude's config root; nil when the environment could not be read.
    public let claudeConfig: ClaudeConfig?
    /// Codex's home; nil when the environment could not be read.
    public let codexHome: CodexHome?
    /// Why there is no PATH, in words for the user.
    public let problem: String?
    /// Whether the query ran on the host at all: false when ssh, the master
    /// or the network failed first (then `problem` is ssh's line).
    public let reachedHost: Bool

    public init(shell: String, path: String?, claudeConfig: ClaudeConfig? = nil, codexHome: CodexHome? = nil,
                problem: String?, reachedHost: Bool = true) {
        self.shell = shell; self.path = path; self.claudeConfig = claudeConfig; self.codexHome = codexHome
        self.problem = problem; self.reachedHost = reachedHost
    }

    /// The resolution query's deadline: past the script's own 5-second
    /// budget and its watchdog's cleanup, so the script answers first.
    public static let deadline: TimeInterval = 9

    /// What the login shell runs, as a script of its own (`sh -c`,
    /// argument: the marker): `$SHELL` asked with `-lic`, then `-l -c`,
    /// then `-c` (csh and tcsh reject the bundled flags), the attempts
    /// sharing one 5-second budget. The budget is enforced only by
    /// `temple_bounded`'s watchdog on the whole process group, never by
    /// `timeout`: GNU `timeout` moves its command into a process group of
    /// its own, where a hung login shell's children would escape the
    /// group the watchdog kills (measured on Ubuntu, tmux 3.4 host).
    /// Each answer is framed by the marker, `printenv` keeping both
    /// values as the shell holds them (any login shell, fish included);
    /// prints the frame and exits 0, or exits 3.
    static let loginScript = #"""
    _m=$1; _s=${SHELL:-/bin/sh}
    _p="echo $_m; printenv PATH; echo $_m.cfg; printenv CLAUDE_CONFIG_DIR; echo $_m.cdx; printenv CODEX_HOME; echo $_m"
    _end=$(( $(date +%s) + 5 ))
    for _v in 1 2 3; do
      [ "$(date +%s)" -lt "$_end" ] || exit 3
      case $_v in
        1) _o=$("$_s" -lic "$_p" </dev/null 2>/dev/null) ;;
        2) _o=$("$_s" -l -c "$_p" </dev/null 2>/dev/null) ;;
        *) _o=$("$_s" -c "$_p" </dev/null 2>/dev/null) ;;
      esac
      case $_o in *"$_m"*"$_m.cfg"*"$_m.cdx"*"$_m"*)
        _o="$_m${_o#*"$_m"}"; _o="${_o%"$_m"*}$_m"
        printf '%s' "$_o"; exit 0 ;;
      esac
    done
    exit 3
    """#

    /// The one resolver, as shell text, shared by the environment query,
    /// the launch and the transcript check (one policy, section 2).
    ///
    /// - `temple_bounded <marker>` runs `loginScript` contained in a process
    ///   group of its own (`setsid` where the host has it, the shell's job
    ///   control otherwise; `kill -SIG -<pgid>` is the spelling dash and
    ///   bash both take) and never waits past the budget: a group still
    ///   running then is sent TERM, then KILL, and its leader reaped, so no
    ///   login shell or descendant is left behind. Where neither containment
    ///   is available it spawns nothing and answers "no answer" at once.
    /// - `temple_parse_env <frame> <marker>` sets `TEMPLE_ENV_PATH`,
    ///   `TEMPLE_ENV_CFG` (`set` or `unset`) and `TEMPLE_ENV_CFG_VALUE`, and
    ///   `TEMPLE_ENV_CDX` and `TEMPLE_ENV_CDX_VALUE` the same way for
    ///   `CODEX_HOME`. A value set to the empty string is a value.
    /// - `temple_login_path <marker>` prints the PATH, or returns 3.
    public static var resolverFunction: String {
        "TEMPLE_LOGIN_SCRIPT=" + RemoteQuoting.quote(loginScript) + "\n" + #"""
        temple_bounded() {
          _f=$(mktemp "${TMPDIR:-/tmp}/temple-env.XXXXXX" 2>/dev/null) || return 3
          case $- in *m*) _was_m=1 ;; *) _was_m= ;; esac
          if [ -z "$_was_m" ] && command -v setsid >/dev/null 2>&1; then
            setsid sh -c "$TEMPLE_LOGIN_SCRIPT" temple-env "$@" > "$_f" 2>/dev/null &
            _pid=$!
          else
            set -m 2>/dev/null
            case $- in *m*) ;; *) rm -f "$_f"; return 3 ;; esac
            sh -c "$TEMPLE_LOGIN_SCRIPT" temple-env "$@" > "$_f" 2>/dev/null &
            _pid=$!
            [ -n "$_was_m" ] || set +m 2>/dev/null
          fi
          _stop=$(( $(date +%s) + 6 ))
          while kill -0 "$_pid" 2>/dev/null && [ "$(date +%s)" -lt "$_stop" ]; do sleep 0.1 2>/dev/null || sleep 1; done
          if kill -0 "$_pid" 2>/dev/null; then
            kill -TERM "-$_pid" 2>/dev/null
            _i=0
            while kill -0 "-$_pid" 2>/dev/null && [ "$_i" -lt 10 ]; do sleep 0.1 2>/dev/null || sleep 1; _i=$((_i+1)); done
            kill -KILL "-$_pid" 2>/dev/null
            wait "$_pid" 2>/dev/null
            rm -f "$_f"; return 3
          fi
          wait "$_pid" 2>/dev/null; _r=$?
          cat "$_f"; rm -f "$_f"; return $_r
        }
        temple_parse_env() {
          _NL='
        '
          _t=$1; _m=$2
          TEMPLE_ENV_PATH=; TEMPLE_ENV_CFG=; TEMPLE_ENV_CFG_VALUE=; TEMPLE_ENV_CDX=; TEMPLE_ENV_CDX_VALUE=
          case $_t in "$_m$_NL"*) _t=${_t#"$_m$_NL"} ;; *) return 3 ;; esac
          case $_t in
            "$_m.cfg$_NL"*) _c=${_t#"$_m.cfg$_NL"} ;;
            *"$_NL$_m.cfg$_NL"*) TEMPLE_ENV_PATH=${_t%%"$_NL$_m.cfg$_NL"*}; _c=${_t#*"$_NL$_m.cfg$_NL"} ;;
            *) return 3 ;;
          esac
          case $_c in
            "$_m.cdx$_NL"*) TEMPLE_ENV_CFG=unset; _x=${_c#"$_m.cdx$_NL"} ;;
            *"$_NL$_m.cdx$_NL"*) TEMPLE_ENV_CFG=set; TEMPLE_ENV_CFG_VALUE=${_c%%"$_NL$_m.cdx$_NL"*}; _x=${_c#*"$_NL$_m.cdx$_NL"} ;;
            *) return 3 ;;
          esac
          case $_x in
            "$_m") TEMPLE_ENV_CDX=unset ;;
            *"$_NL$_m") TEMPLE_ENV_CDX=set; TEMPLE_ENV_CDX_VALUE=${_x%"$_NL$_m"} ;;
            *) return 3 ;;
          esac
          case $TEMPLE_ENV_PATH in */*) ;; *) TEMPLE_ENV_PATH= ;; esac
        }
        temple_login_path() {
          _e=$(temple_bounded "$1") || return 3
          temple_parse_env "$_e" "$1" || return 3
          [ -n "$TEMPLE_ENV_PATH" ] || return 3
          printf '%s\n' "$TEMPLE_ENV_PATH"
        }
        """#
    }

    /// The query: the shell's name, then the login environment's frame.
    static var script: String {
        resolverFunction + "\n" + #"""
        m=$1
        echo "shell ${SHELL:-/bin/sh}"
        e=$(temple_bounded "$m") || exit 3
        printf '%s\n' "$e"
        """#
    }

    /// Resolves through `exec`, which must carry no PATH of its own.
    public static func resolve(using exec: RemoteExec) async -> RemoteEnvironment {
        let marker = "__temple_path_\(RemoteQuoting.nonce())__"
        do {
            let output = try await exec.run(script: script, args: [marker], deadline: deadline)
            return parse(output, marker: marker)
        } catch let error as RemoteExecError {
            if case .deadline = error {
                return RemoteEnvironment(shell: "", path: nil, problem: "the login shell didn't answer within 5 seconds",
                                         reachedHost: false)
            }
            return RemoteEnvironment(shell: "", path: nil, problem: error.localizedDescription, reachedHost: false)
        } catch {
            return RemoteEnvironment(shell: "", path: nil, problem: error.localizedDescription, reachedHost: false)
        }
    }

    static func parse(_ output: RemoteOutput, marker: String) -> RemoteEnvironment {
        let text = output.stdout
        let shell = text.split(separator: "\n").first { $0.hasPrefix("shell ") }.map { String($0.dropFirst(6)) } ?? ""
        guard output.reachedCommand, output.status == 0 || output.status == 3 else {
            // The command never ran (ssh's 255, a missing sh): ssh's words.
            return RemoteEnvironment(shell: shell, path: nil,
                                     problem: output.firstErrorLine ?? "ssh exited with status \(output.status)",
                                     reachedHost: false)
        }
        let name = shell.isEmpty ? "the login shell" : shell
        guard let frame = Self.frame(text, marker: marker) else {
            return RemoteEnvironment(shell: shell, path: nil, problem: "\(name) printed no PATH")
        }
        let path = frame.path.contains("/") ? frame.path : nil
        return RemoteEnvironment(shell: shell, path: path, claudeConfig: frame.config, codexHome: frame.codexHome,
                                 problem: path == nil ? "\(name) printed no PATH" : nil)
    }

    /// The frame's values, as the shell held them. A frame without the
    /// Codex part (an older resolver) has no Codex home: nil, never a guess.
    static func frame(_ text: String, marker: String) -> (path: String, config: ClaudeConfig, codexHome: CodexHome?)? {
        guard let start = text.range(of: marker + "\n") else { return nil }
        let rest = text[start.upperBound...]
        let cfgMarker = marker + ".cfg\n"
        let path: Substring
        let afterPath: Substring
        if rest.hasPrefix(cfgMarker) {
            path = ""
            afterPath = rest.dropFirst(cfgMarker.count)
        } else if let cfg = rest.range(of: "\n" + cfgMarker) {
            path = rest[..<cfg.lowerBound]
            afterPath = rest[cfg.upperBound...]
        } else {
            return nil
        }
        guard let end = afterPath.range(of: marker, options: .backwards) else { return nil }
        let values = afterPath[..<end.lowerBound]
        // `<cfg>\n` (or nothing, unset), then `<marker>.cdx\n`, then `<cdx>\n` (or nothing).
        let cdxMarker = marker + ".cdx\n"
        let configText: Substring
        var codexHome: CodexHome?
        if values.hasPrefix(cdxMarker) {
            configText = ""
            codexHome = Self.variable(values.dropFirst(cdxMarker.count))
        } else if let cdx = values.range(of: "\n" + cdxMarker) {
            configText = values[..<values.index(after: cdx.lowerBound)]
            codexHome = Self.variable(values[cdx.upperBound...])
        } else {
            configText = values
        }
        return (String(path), Self.variable(configText), codexHome)
    }

    /// What `printenv NAME` printed: nothing for unset, else the value and
    /// its newline (an empty value is a value).
    private static func variable(_ printed: Substring) -> Variable {
        if printed.isEmpty { return .unset }
        var value = String(printed)
        if value.hasSuffix("\n") { value.removeLast() }
        return .set(value)
    }
}
