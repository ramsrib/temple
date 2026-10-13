import Darwin
import Foundation

/// Folder spellings the command line and the app compare. An agent records
/// the folder it ran in as the process saw it (`getcwd`, symlinks resolved),
/// so `/tmp/x`, `/private/tmp/x` and a symlinked checkout all name one
/// project once resolved.
public enum ControlPaths {
    /// Absolute, standardized, and with symlinks resolved when the folder
    /// exists. Relative paths are taken from `base`.
    public static func canonical(_ path: String, relativeTo base: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        let standardized = (absolute as NSString).standardizingPath
        // `realpath`, not `resolvingSymlinksInPath`: Foundation's maps
        // `/private/tmp` back to `/tmp`, the opposite of what `getcwd` says.
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Two spellings of one folder.
    public static func sameFolder(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || canonical(lhs) == canonical(rhs)
    }
}
