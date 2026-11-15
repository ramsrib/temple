import Foundation
import TempleCore

/// Tracks live agent pids ↔ sessions so a crash-restart can adopt or clean up
/// stragglers (ADR-010).
///
/// The real app uses `DBProcessRegistry`; the in-memory implementation remains
/// useful for deterministic lifecycle tests.
@MainActor
public protocol ProcessRegistry: AnyObject {
    func register(pid: pid_t, session: SessionKey)
    func unregister(session: SessionKey)
}

@MainActor
public final class DBProcessRegistry: ProcessRegistry {
    private let db: TempleDB

    public init(db: TempleDB) {
        self.db = db
    }

    public func register(pid: pid_t, session: SessionKey) {
        try? db.registerProcess(pid: Int32(pid), sessionID: session.id, host: session.host)
    }

    public func unregister(session: SessionKey) {
        try? db.unregisterProcess(sessionID: session.id, host: session.host)
    }
}

@MainActor
public final class InMemoryProcessRegistry: ProcessRegistry {
    public private(set) var pids: [SessionKey: pid_t] = [:]

    public init() {}

    public func register(pid: pid_t, session: SessionKey) {
        pids[session] = pid
    }

    public func unregister(session: SessionKey) {
        pids.removeValue(forKey: session)
    }
}
