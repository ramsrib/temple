import Foundation

/// How a tab's launch reaches the host: the launch script, with every
/// variable-length value in it (PATH, Claude's config root, the folder, the
/// agent's argv, the record's locator, the socket), is staged first in the
/// private record directory by a bounded, non-interactive query over
/// Temple's master, its bytes on stdin; the tab's ssh then runs a short,
/// fixed command that names the staged file and nothing else.
///
/// Why not one long command line: a remote command travels inside the mux
/// client's session request, and on macOS a request that ends just below a
/// multiple of the 8 KiB socket buffer cannot hand its descriptors to the
/// master (`mm_send_fd: sendmsg(2): Message too long`; measured, design
/// note 21). The request is the command plus `TERM` and whatever the
/// user's ssh forwards (`SendEnv`, `SetEnv`), which Temple does not
/// control; so the command is kept far below the first band instead of
/// steered around it. With a command of at most `maximumCommandBytes`, the
/// forwarded environment would need about 7 KiB of its own to reach it.
///
/// - Staged files are `~/.temple/launch/<marker>.s-c<nonce>` (a creation)
///   and `<marker>.s-a<nonce>` (an attach): written with noclobber and mode
///   0600 beside, checked for length, then linked into place, so the tab
///   never reads a partial one.
/// - The tab's command waits up to `waitSeconds` for its file (at first
///   contact the tab's own ssh authenticates and becomes the master, and
///   Temple stages once that master answers), reads it, deletes it, and
///   runs it. A file that never comes is said in the tab, never guessed at.
/// - What nothing read is removed when the record is acknowledged (the
///   creation's) or the run's exit has been handled (all of the run's),
///   and by the launch's 24-hour sweep.
public enum LaunchStage {
    /// The longest remote command an interactive launch may send.
    public static let maximumCommandBytes = 1024
    /// How long the tab's command waits for its staged file.
    public static let waitSeconds = 30

    /// A creation's stage name for `marker`.
    public static func creationName(marker: String, nonce: String) -> String { "\(marker).s-c\(nonce)" }
    /// An attach's stage name for `marker`.
    public static func attachName(marker: String, nonce: String) -> String { "\(marker).s-a\(nonce)" }

    /// The tab's command, arguments: the stage name, then how many seconds
    /// to wait for it. One line, so any login shell (csh included) passes
    /// it to `sh` whole.
    static let runner = #"f=$HOME/.temple/launch/$1; e=$(( $(date +%s) + $2 )); "#
        + #"while [ ! -f "$f" ] && [ "$(date +%s)" -lt "$e" ]; do sleep 0.2 2>/dev/null || sleep 1; done; "#
        + #"if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] && s=$(cat "$f"); then rm -f "$f"; exec sh -c "$s" temple-launch; fi; "#
        + #"echo "Temple couldn't find the launch it prepared for this session on this host." >&2; exit 125"#

    /// The remote command for the tab's ssh: short and fixed but for the
    /// stage name.
    public static func command(stage: String, wait: Int = waitSeconds) -> String {
        precondition(RemoteQuoting.isSafeToken(stage))
        return RemoteQuoting.command(["sh", "-c", runner, "temple-launch", stage, String(wait)])
    }

    /// The staging query, arguments `name bytes`, the script on stdin.
    /// Prints `temple-staged`, or `temple-stage-refused <why>` when nothing
    /// was put in place.
    static let writeScript = RecordDirectory.functions + "\n" + #"""
    umask 077
    rd=$(temple_record_dir) || { echo "temple-stage-refused ~/.temple/launch isn't a private folder of this account's"; exit 0; }
    f=$rd/$1; t=$f.tmp
    rm -f "$t"
    ( set -C; cat > "$t" ) 2>/dev/null || { rm -f "$t"; echo "temple-stage-refused couldn't write in $rd"; exit 0; }
    n=$(wc -c < "$t" | tr -d ' ')
    [ "$n" = "$2" ] || { rm -f "$t"; echo "temple-stage-refused only $n of $2 bytes arrived"; exit 0; }
    chmod 600 "$t" && ln "$t" "$f" 2>/dev/null || { rm -f "$t"; echo "temple-stage-refused $f already exists"; exit 0; }
    rm -f "$t"
    echo temple-staged
    """#

    /// Argument: the stage name. Removes it, written or not.
    static let discardScript = RecordDirectory.functions + "\n" + #"""
    rd=$(temple_record_dir) || exit 0
    rm -f "$rd/$1" "$rd/$1.tmp"
    exit 0
    """#

    /// Argument: the marker. Removes every staged launch of that run.
    static let discardRunScript = RecordDirectory.functions + "\n" + #"""
    rd=$(temple_record_dir) || exit 0
    rm -f "$rd/$1".s-*
    exit 0
    """#

    public static let deadline: TimeInterval = 10

    public enum WriteResult: Sendable, Equatable {
        /// In place, whole, for the tab to read.
        case staged
        /// Refused on the host before anything was put in place, or never
        /// sent: no launch can have read it.
        case refused(String)
        /// No answer: it may or may not be in place.
        case unknown(String)
    }

    public static func write(stage: String, script: String, using exec: RemoteExec) async -> WriteResult {
        precondition(RemoteQuoting.isSafeToken(stage))
        let payload = Data(script.utf8)
        do {
            let output = try await exec.run(script: writeScript, args: [stage, String(payload.count)], input: payload,
                                            deadline: deadline)
            let lines = output.stdout.split(whereSeparator: \.isNewline).map(String.init)
            if lines.contains("temple-staged") { return .staged }
            if let refusal = lines.first(where: { $0.hasPrefix("temple-stage-refused ") }) {
                return .refused(String(refusal.dropFirst("temple-stage-refused ".count)))
            }
            return .unknown(output.firstErrorLine ?? "ssh exited with status \(output.status)")
        } catch RemoteExecError.launchFailed(let reason) {
            return .refused("ssh couldn't start: \(reason)")
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Best effort: every staged launch of a run that has ended.
    public static func discardAll(marker: String, using exec: RemoteExec) async {
        precondition(RemoteQuoting.isSafeToken(marker))
        _ = try? await exec.run(script: discardRunScript, args: [marker], deadline: 5)
    }

    /// Best effort: a staged launch nothing will read.
    public static func discard(stage: String, using exec: RemoteExec) async {
        precondition(RemoteQuoting.isSafeToken(stage))
        _ = try? await exec.run(script: discardScript, args: [stage], deadline: 5)
    }
}
