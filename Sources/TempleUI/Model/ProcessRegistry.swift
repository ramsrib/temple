import Foundation
import TempleCore

/// Tracks live agent pids ↔ sessions so a crash-restart can adopt or clean up
/// stragglers (ADR-010).
///
/// The real app uses `DBProcessRegistry`; the in-memory implementation remains
/// useful for deterministic lifecycle tests.
@MainActor
public protocol ProcessRegistry: AnyObject {
    func register(pid: pid_t, sessionID: String)
    func unregister(sessionID: String)
}

@MainActor
public final class DBProcessRegistry: ProcessRegistry {
    private let db: TempleDB

    public init(db: TempleDB) {
        self.db = db
    }

    public func register(pid: pid_t, sessionID: String) {
        try? db.registerProcess(pid: Int32(pid), sessionID: sessionID)
    }

    public func unregister(sessionID: String) {
        try? db.unregisterProcess(sessionID: sessionID)
    }
}

@MainActor
public final class InMemoryProcessRegistry: ProcessRegistry {
    public private(set) var pids: [String: pid_t] = [:]

    public init() {}

    public func register(pid: pid_t, sessionID: String) {
        pids[sessionID] = pid
    }

    public func unregister(sessionID: String) {
        pids.removeValue(forKey: sessionID)
    }
}
