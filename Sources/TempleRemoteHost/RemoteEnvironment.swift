import Foundation
import TempleCore

/// The remote login environment, resolved the way `LoginShellEnvironment`
/// resolves this Mac's PATH: ask the account's login shell, login and
/// interactive, because a non-interactive ssh command often has not read the
/// rc file that builds the real environment. One query gives the two values
/// Temple uses: PATH (for everything run on the host: probe, launch, tmux,
/// reads, the agent) and Claude's config root (`CLAUDE_CONFIG_DIR`, where
/// the agent keeps its transcripts, handed to the agent at launch and the
/// root the transcript check inspects). When resolution fails, everything
/// uses ssh's default environment instead, and says so.
///
/// Memory only, never persisted.
public struct RemoteEnvironment: Sendable, Equatable {
    /// Claude's config root as the login environment sets it.
    public enum ClaudeConfig: Sendable, Equatable {
        /// `CLAUDE_CONFIG_DIR` is not set: Claude uses `~/.claude`.
        case unset
        /// Set, to exactly this (newlines and relative values kept).
        case set(String)
    }

    /// The login shell asked (`$SHELL` on the host).
    public let shell: String
    /// The PATH it gave; nil when it could not be read.
    public let path: String?
    /// Claude's config root; nil when the environment could not be read.
    public let claudeConfig: ClaudeConfig?
    /// Why there is no PATH, in words for the user.
    public let problem: String?
    /// Whether the query ran on the host at all: false when ssh, the master
    /// or the network failed first (then `problem` is ssh's line).
    public let reachedHost: Bool

    public init(shell: String, path: String?, claudeConfig: ClaudeConfig? = nil, problem: String?, reachedHost: Bool = true) {
        self.shell = shell; self.path = path; self.claudeConfig = claudeConfig; self.problem = problem
        self.reachedHost = reachedHost
    }

    /// The resolution query's deadline: past the script's own 5-second
    /// budget and its watchdog's cleanup, so the script answers first.
    public static let deadline: TimeInterval = 9

    /// What the login shell runs, as a script of its own (`sh -c`,
    /// argument: the marker): `$SHELL` asked with `-lic`, then `-l -c`,
    /// then `-c` (csh and tcsh reject the bundled flags), the attempts
    /// sharing one 5-second budget (through `timeout` where the host has
    /// it). Each answer is framed by the marker, `printenv` keeping both
    /// values as the shell holds them (any login shell, fish included);
    /// prints the frame and exits 0, or exits 3.
    static let loginScript = #"""
    _m=$1; _s=${SHELL:-/bin/sh}
    _p="echo $_m; printenv PATH; echo $_m.cfg; printenv CLAUDE_CONFIG_DIR; echo $_m"
    _end=$(( $(date +%s) + 5 ))
    for _v in 1 2 3; do
      _left=$(( _end - $(date +%s) )); [ "$_left" -gt 0 ] || exit 3
      _t=; command -v timeout >/dev/null 2>&1 && _t="timeout $_left"
      case $_v in
        1) _o=$($_t "$_s" -lic "$_p" </dev/null 2>/dev/null) ;;
        2) _o=$($_t "$_s" -l -c "$_p" </dev/null 2>/dev/null) ;;
        *) _o=$($_t "$_s" -c "$_p" </dev/null 2>/dev/null) ;;
      esac
      [ $? -eq 124 ] && exit 3
      case $_o in *"$_m"*"$_m.cfg"*"$_m"*)
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
    ///   `TEMPLE_ENV_CFG` (`set` or `unset`) and `TEMPLE_ENV_CFG_VALUE`.
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
          TEMPLE_ENV_PATH=; TEMPLE_ENV_CFG=; TEMPLE_ENV_CFG_VALUE=
          case $_t in "$_m$_NL"*) _t=${_t#"$_m$_NL"} ;; *) return 3 ;; esac
          case $_t in
            "$_m.cfg$_NL"*) _c=${_t#"$_m.cfg$_NL"} ;;
            *"$_NL$_m.cfg$_NL"*) TEMPLE_ENV_PATH=${_t%%"$_NL$_m.cfg$_NL"*}; _c=${_t#*"$_NL$_m.cfg$_NL"} ;;
            *) return 3 ;;
          esac
          _c=${_c%"$_m"}
          if [ -n "$_c" ]; then TEMPLE_ENV_CFG=set; TEMPLE_ENV_CFG_VALUE=${_c%"$_NL"}; else TEMPLE_ENV_CFG=unset; fi
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
        return RemoteEnvironment(shell: shell, path: path, claudeConfig: frame.config,
                                 problem: path == nil ? "\(name) printed no PATH" : nil)
    }

    /// The frame's two values, as the shell held them.
    static func frame(_ text: String, marker: String) -> (path: String, config: ClaudeConfig)? {
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
        let config = afterPath[..<end.lowerBound]
        if config.isEmpty { return (String(path), .unset) }
        var value = String(config)
        if value.hasSuffix("\n") { value.removeLast() }
        return (String(path), .set(value))
    }
}
