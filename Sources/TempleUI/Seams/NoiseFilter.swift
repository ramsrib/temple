import Foundation
import TempleCore

/// Hides ambient / automation sessions from the sidebar (UX §1 noise filter).
///
/// **Seam for Track C2.** The trivial local default hides sessions whose `cwd`
/// is `/` or no longer exists on disk. When C2's `SessionFilter` lands in
/// TempleCore, swap `DefaultNoiseFilter` for a `CoreNoiseFilter` adapter — a
/// one-line change at the `AppModel` construction site.
public protocol NoiseFilter: Sendable {
    func isNoise(_ session: AgentSession) -> Bool
}

public struct DefaultNoiseFilter: NoiseFilter {
    public init() {}

    public func isNoise(_ session: AgentSession) -> Bool {
        let path = session.projectPath
        if path == "/" || path.isEmpty { return true }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return !(exists && isDir.boolValue)
    }
}
