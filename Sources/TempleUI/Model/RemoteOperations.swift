import Foundation
import TempleCore

/// The one owner of every asynchronous operation on a host (opens, record
/// polls, exit checks, stops, and the durable writes that follow them), so
/// that a close, a host's removal or edit, and the quit each account for
/// all of them (docs/designs/remote-ssh.md section 5):
///
/// - a close that hands its stop here gives up the tab, never the stop;
/// - a host that is removed or edited has every operation cancelled (its
///   queries' ssh clients killed), and a cancelled stop records why;
/// - the quit cancels what only looks (opens, polls, checks), lets stops run
///   inside its window and expires those still outstanding at its deadline,
///   each recording why; the engine barrier then waits for every write here
///   within its own bound, never past it.
@MainActor
public final class RemoteOperations {
    public enum Kind: Equatable { case open, collect, exitCheck, stop, write }

    final class Operation {
        let id = UUID()
        let host: HostID
        let kind: Kind
        /// For a stop: what to record when it is cancelled before its
        /// answer (the reason depends on who cancelled it).
        let onCancel: (@MainActor (RemoteLeftRunningReason) async -> Void)?
        var task: Task<Void, Never>?
        /// Cancelled, its reason recorded; it stays owned until its task
        /// ends, so an answer that had already arrived is still written.
        var expired = false
        init(host: HostID, kind: Kind, onCancel: (@MainActor (RemoteLeftRunningReason) async -> Void)?) {
            self.host = host; self.kind = kind; self.onCancel = onCancel
        }
    }

    private var operations: [UUID: Operation] = [:]

    public init() {}

    /// Runs `body` as an owned operation; it leaves the set when it ends.
    @discardableResult
    public func run(host: HostID, _ kind: Kind,
                    onCancel: (@MainActor (RemoteLeftRunningReason) async -> Void)? = nil,
                    _ body: @escaping @MainActor () async -> Void) -> UUID {
        let operation = Operation(host: host, kind: kind, onCancel: onCancel)
        operations[operation.id] = operation
        operation.task = Task { @MainActor [weak self] in
            await body()
            self?.operations[operation.id] = nil
        }
        return operation.id
    }

    public var count: Int { operations.count }
    func count(_ kind: Kind) -> Int { operations.values.filter { $0.kind == kind && !$0.expired }.count }
    public var stopsOutstanding: Int { count(.stop) }

    /// A host was removed or edited: everything of its is cancelled; a stop
    /// cancelled before its answer is recorded left running.
    public func cancel(host: HostID) {
        for operation in operations.values where operation.host == host && operation.kind != .write && !operation.expired {
            expire(operation, reason: .stopNotAcknowledged)
        }
    }

    /// The quit began: what only looks is cancelled (and stays owned until
    /// it has unwound, so an open it planned is abandoned durably); stops
    /// and writes run on.
    public func cancelForQuit() {
        for operation in operations.values where operation.kind != .stop && operation.kind != .write && !operation.expired {
            operation.task?.cancel()
            operation.expired = true
        }
    }

    /// The quit's window closed: every stop still outstanding is cancelled
    /// (its query's ssh is killed) and recorded left running, `quit deadline`.
    public func expireStops() {
        for operation in operations.values where operation.kind == .stop && !operation.expired {
            expire(operation, reason: .quitDeadline)
        }
    }

    private func expire(_ operation: Operation, reason: RemoteLeftRunningReason) {
        operation.task?.cancel()
        operation.expired = true
        if let onCancel = operation.onCancel {
            run(host: operation.host, .write) { await onCancel(reason) }
        }
    }

    /// Waits until every operation has ended, or `deadline`; true when all did.
    public func waitForAll(until deadline: Date) async -> Bool {
        while !operations.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return operations.isEmpty
    }
}
