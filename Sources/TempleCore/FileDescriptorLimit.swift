import Darwin
import Foundation

/// GUI apps launched by launchd start with a soft limit of 256 open file
/// descriptors (`launchctl limit maxfiles`) — far below what the parallel
/// session-file parse and the per-file watches need across thousands of
/// sessions. Terminal-launched processes inherit the shell's much higher
/// limit, which is why the same binary behaves differently from Finder.
///
/// Raise the soft limit once, early, before any mass file access. Idempotent
/// and cheap; safe to call from every entry path.
public enum FileDescriptorLimit {
    /// Upper bound we ask for — comfortably above worst-case watch + parse
    /// concurrency while staying well under kernel maxfiles.
    private static let target: rlim_t = 65_536

    private static let raiseOnce: Void = {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        // rlim_max may be RLIM_INFINITY (a huge sentinel); min() caps it either way.
        let ceiling = min(lim.rlim_max, target)
        guard lim.rlim_cur < ceiling else { return }
        lim.rlim_cur = ceiling
        setrlimit(RLIMIT_NOFILE, &lim)
    }()

    /// Ensure the soft RLIMIT_NOFILE is raised. Runs at most once per process.
    public static func ensureRaised() {
        _ = raiseOnce
    }
}
