import Foundation
import TempleCore

// Tests' shorthand for this Mac's sessions. The app names every session by
// its id on a host (ADR-041) and has no default host; most tests are about a
// session on this Mac, and spell that out here once. A test about a session
// on another host passes the host, and a test whose row is on another host
// gets nil from these, as it should.

public extension TempleDB {
    func sessionState(_ sessionID: String) throws -> SessionState? {
        try sessionState(sessionID, host: .local)
    }

    func setPinned(_ pinned: Bool, sessionID: String) throws {
        try setPinned(pinned, sessionID: sessionID, host: .local)
    }

    func setArchived(_ archived: Bool, sessionID: String, at: Date = Date()) throws {
        try setArchived(archived, sessionID: sessionID, host: .local, at: at)
    }

    func setCustomName(_ name: String?, sessionID: String) throws {
        try setCustomName(name, sessionID: sessionID, host: .local)
    }

    func setColor(_ color: String?, sessionID: String) throws {
        try setColor(color, sessionID: sessionID, host: .local)
    }

    func registerProcess(pid: Int32, sessionID: String, startedAt: Date = Date()) throws {
        try registerProcess(pid: pid, sessionID: sessionID, host: .local, startedAt: startedAt)
    }

    func unregisterProcess(sessionID: String) throws {
        try unregisterProcess(sessionID: sessionID, host: .local)
    }
}

public extension SessionKey {
    /// A session on this Mac.
    static func local(_ id: String) -> SessionKey { SessionKey(id: id, host: .local) }
}

public extension Dictionary where Key == String {
    /// A dictionary of this Mac's sessions, keyed as the app keys them.
    var onThisMac: [SessionKey: Value] {
        Dictionary<SessionKey, Value>(uniqueKeysWithValues: map { (SessionKey.local($0.key), $0.value) })
    }
}

public extension EngineSnapshot {
    /// This Mac's engine snapshot as the app's merged one.
    var onThisMac: SessionsSnapshot { EngineSnapshot.merged(local: self) }

    /// A this-Mac engine snapshot, keyed by session as the app keys it.
    static func merged(local snapshot: EngineSnapshot) -> SessionsSnapshot {
        SessionsSnapshot(generation: snapshot.generation,
                         resolutions: snapshot.resolutions.onThisMac,
                         facts: snapshot.facts.onThisMac,
                         memberships: snapshot.memberships.onThisMac)
    }
}

/// In tests, a string literal is a session on this Mac (`"s"` for
/// `SessionKey(id: "s", host: .local)`). Another host's session is always
/// spelled out.
extension SessionKey: @retroactive ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(id: value, host: .local) }
}

public extension Dictionary where Key == SessionKey {
    /// The one entry with this id, whatever its host; nil when there is
    /// none or more than one. For tests whose sessions are all on one host.
    subscript(only id: String) -> Value? {
        let matches = filter { $0.key.id == id }
        return matches.count == 1 ? matches.first?.value : nil
    }
}

public extension TempleDB {
    /// The one row with this id, whatever its host (nil: none, or several).
    func onlySessionState(_ sessionID: String) throws -> SessionState? {
        let rows = try sessionStates(id: sessionID)
        return rows.count == 1 ? rows.first : nil
    }
}
