import Foundation
import TempleCore

/// Hides ambient / automation sessions from the sidebar (UX §1 noise filter).
///
/// `CoreNoiseFilter` is the real app adapter. `DefaultNoiseFilter` remains as a
/// narrow local implementation for focused seam tests.
public protocol NoiseFilter: Sendable {
    func isNoise(_ session: AgentSession) -> Bool
    /// Batch variant: the caller supplies (and can memoize) the directory-
    /// existence check. An index holds many sessions per project, and the
    /// filter runs over ALL of them on every index publish — which, while an
    /// agent is appending to its session file, is a couple of times a second.
    /// One stat per unique project path instead of one per session.
    func isNoise(_ session: AgentSession, pathExists: (String) -> Bool) -> Bool
}

public extension NoiseFilter {
    func isNoise(_ session: AgentSession, pathExists: (String) -> Bool) -> Bool {
        isNoise(session)
    }
}

public struct CoreNoiseFilter: NoiseFilter {
    public init() {}

    public func isNoise(_ session: AgentSession) -> Bool {
        SessionFilter.isNoise(session)
    }

    public func isNoise(_ session: AgentSession, pathExists: (String) -> Bool) -> Bool {
        SessionFilter.isNoise(session, pathExists: pathExists)
    }
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
