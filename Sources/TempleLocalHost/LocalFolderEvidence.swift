import Darwin
import Foundation
import TempleCore

/// The one answer this Mac gives about a folder, for the session source
/// (History, the archive sweep) and the launcher alike (wired through
/// TempleUI's `LocalHost.swift`).
public enum LocalFolderEvidence {
    /// `.missing` only when the path is provably gone (ADR-030 archives on
    /// it). A folder on a drive that is not mounted stats as ENOENT exactly
    /// like a deleted one, so the nearest ancestor that does exist is
    /// resolved through its symlinks, and when the path physically lives
    /// under `/Volumes/<name>/` the ancestor's filesystem must be the one
    /// mounted at `/Volumes/<name>`: a leftover empty mount point, or the
    /// volumes directory itself, is not the volume. A symlink on the way
    /// whose target is gone, or anything that cannot be established, is
    /// `.unknown`: an unplugged drive is not a deleted project.
    public static func evidence(_ path: String, volumesRoot: String = "/Volumes") -> DirectoryEvidence {
        var info = stat()
        if stat(path, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR ? .exists : .missing }
        guard errno == ENOENT || errno == ENOTDIR, path.hasPrefix("/") else { return .unknown }
        let components = (path as NSString).standardizingPath.split(separator: "/").map(String.init)
        var existing = "/"
        var remaining: [String]?
        for (index, component) in components.enumerated() {
            let next = existing == "/" ? "/" + component : existing + "/" + component
            if stat(next, &info) == 0 { existing = next; continue }
            let code = errno
            // There, but not reachable: a symlink whose target is gone.
            if lstat(next, &info) == 0 { return .unknown }
            guard code == ENOENT || code == ENOTDIR else { return .unknown }
            remaining = Array(components[index...])
            break
        }
        // Every component is there after all (it appeared meanwhile).
        guard let remaining, let real = realPath(existing) else { return .unknown }
        let physical = (real == "/" ? "" : real) + "/" + remaining.joined(separator: "/")
        let volumes = realPath(volumesRoot) ?? volumesRoot
        if physical.hasPrefix(volumes + "/") {
            guard let name = physical.dropFirst(volumes.count + 1).split(separator: "/").first,
                  let mounted = mountPoint(of: existing),
                  mounted == volumes + "/" + name else { return .unknown }
        }
        return .missing
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Where the filesystem holding `path` is mounted.
    private static func mountPoint(of path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mounted = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return realPath(mounted) ?? mounted
    }
}
