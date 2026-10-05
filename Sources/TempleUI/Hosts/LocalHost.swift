import TempleCore
import TempleLocalHost

/// The one place TempleUI names `TempleLocalHost`: this Mac's entry in the
/// registry. Everything else in the app reaches local transcripts through
/// `HostRegistry` and the `HostSessionSource` seam, so a remote host is
/// another entry here, not a change anywhere else.
/// (`ModuleBoundaryTests` asserts that this file and templectl are the only
/// importers.)
extension HostRegistry {
    /// This Mac, launched by `localLauncher`. The registry is the one owner
    /// of the local source: nothing else in the app constructs one.
    @MainActor public init(localLauncher: (any HostLauncher)? = nil) {
        self.init(entries: [Entry(source: LocalSessionSource(), launcher: localLauncher ?? LocalHostLauncher())])
    }
}

extension LocalHostLauncher {
    /// This Mac's folder evidence, the one implementation the local session
    /// source also uses (`LocalFolderEvidence`): `.missing` only for a folder
    /// provably gone on a mounted volume; an unplugged drive, a leftover
    /// mount point or a dangling symlink on the way is `.unknown`.
    public nonisolated static func statEvidence(_ path: String) -> DirectoryEvidence {
        LocalFolderEvidence.evidence(path)
    }
}
