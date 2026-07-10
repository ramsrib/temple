import Foundation

/// Tracks live agent pids ↔ sessions so a crash-restart can adopt or clean up
/// stragglers (ADR-010).
///
/// **Seam for Track C5.** In-memory default now; C5's GRDB `process_registry`
/// table implements the same two methods later (one-line swap at construction).
@MainActor
public protocol ProcessRegistry: AnyObject {
    func register(pid: pid_t, sessionID: String)
    func unregister(sessionID: String)
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
