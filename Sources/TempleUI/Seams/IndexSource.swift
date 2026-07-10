import Foundation
import TempleCore

/// Supplies the live session index to the UI (U5).
///
/// **Seam for Track C1.** The default is a poll timer that rebuilds
/// `SessionIndex.buildDefault()` every few seconds. When C1's `SessionWatcher`
/// ships its `AsyncStream<SessionIndex>`, drop `PollingIndexSource` for a
/// `WatcherIndexSource` adapter — the three interim lines below are marked for
/// deletion.
@MainActor
public protocol IndexSource: AnyObject {
    /// Emit the current index immediately, then on every change.
    func start(onUpdate: @escaping (SessionIndex) -> Void)
    func stop()
}

/// Interim implementation — DELETE when C1's watcher lands (U5).
///
/// A full re-parse of every session file is expensive (seconds on a large
/// store), so this polls gently and never overlaps builds. C1's incremental
/// watcher makes both concerns moot.
@MainActor
public final class PollingIndexSource: IndexSource {
    private let interval: TimeInterval
    private let build: @Sendable () -> SessionIndex
    private var timer: Timer?
    private var isRefreshing = false

    public init(interval: TimeInterval = 30,
                build: @escaping @Sendable () -> SessionIndex = { SessionIndex.buildDefault() }) {
        self.interval = interval
        self.build = build
    }

    public func start(onUpdate: @escaping (SessionIndex) -> Void) {
        refresh(onUpdate)  // immediate first load
        // --- interim poll: replace with C1's AsyncStream subscription ---
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(onUpdate) }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh(_ onUpdate: @escaping (SessionIndex) -> Void) {
        guard !isRefreshing else { return }   // never stack builds
        isRefreshing = true
        let build = self.build
        Task.detached(priority: .utility) {
            let index = build()
            await MainActor.run {
                self.isRefreshing = false
                onUpdate(index)
            }
        }
    }
}
