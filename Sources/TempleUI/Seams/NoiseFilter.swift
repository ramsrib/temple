import Foundation
import TempleCore

/// Hides ambient / automation sessions from the sidebar (UX §1 noise filter).
///
/// `CoreNoiseFilter` is the real app adapter. `DefaultNoiseFilter` remains as a
/// narrow local implementation for focused seam tests.
public protocol NoiseFilter: Sendable {
    func isNoise(_ session: AgentSession) -> Bool
}

public struct CoreNoiseFilter: NoiseFilter {
    public init() {}

    public func isNoise(_ session: AgentSession) -> Bool {
        SessionFilter.isNoise(session)
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
