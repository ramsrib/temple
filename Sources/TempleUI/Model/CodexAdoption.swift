import Foundation
import TempleCore

/// Reconciles provisional Codex tabs from the same live index stream used by
/// the sidebar, avoiding a second filesystem watcher in the real app.
@MainActor
public final class WatcherCodexReconciler: CodexAdopting {
    private struct PendingAdoption {
        let projectPath: String
        let startedAt: Date
        let adopt: (String) -> Void
    }

    private let indexSource: WatcherIndexSource
    private let window: TimeInterval
    private var pending: [UUID: PendingAdoption] = [:]
    private var observationID: UUID?

    public init(indexSource: WatcherIndexSource, window: TimeInterval = 5) {
        self.indexSource = indexSource
        self.window = window
    }

    public convenience init(window: TimeInterval = 5) {
        self.init(indexSource: WatcherIndexSource(), window: window)
    }

    public func reconcile(
        projectPath: String,
        startedAt: Date,
        adopt: @escaping (String) -> Void
    ) {
        let id = UUID()
        pending[id] = PendingAdoption(
            projectPath: projectPath,
            startedAt: startedAt,
            adopt: adopt
        )
        beginObservingIfNeeded()

        Task { [weak self] in
            let timeout = max(0, self?.window ?? 0) + 1
            try? await Task.sleep(for: .seconds(timeout))
            self?.removePending(id)
        }
    }

    private func beginObservingIfNeeded() {
        guard observationID == nil else { return }
        observationID = indexSource.observe { [weak self] index in
            self?.consider(index)
        }
    }

    private func consider(_ index: SessionIndex) {
        let candidates = index.allSessions.compactMap { session -> CodexRolloutCandidate? in
            guard session.agent == .codex, let createdAt = session.createdAt else { return nil }
            return CodexRolloutCandidate(
                sessionID: session.id,
                cwd: session.projectPath,
                createdAt: createdAt,
                filePath: session.filePath
            )
        }

        let requests = pending
        for (id, request) in requests {
            let candidateCount = candidates.filter {
                $0.cwd == request.projectPath
                    && abs($0.createdAt.timeIntervalSince(request.startedAt)) <= window
            }.count
            if candidateCount == 0 {
                TempleUILog.reconcile.info("no Codex adoption match for cwd=\(request.projectPath, privacy: .public) within window=\(self.window)s")
                continue
            }
            if candidateCount > 1 {
                TempleUILog.reconcile.error("refused to adopt: \(candidateCount) candidates for cwd=\(request.projectPath, privacy: .public) within window=\(self.window)s")
                continue
            }
            guard let match = TempleCore.CodexReconciler.reconcile(
                launchedCwd: request.projectPath,
                launchedAt: request.startedAt,
                window: window,
                candidates: candidates
            ) else { continue }
            pending.removeValue(forKey: id)
            request.adopt(match.sessionID)
            TempleUILog.reconcile.info("adopted Codex session id=\(match.sessionID, privacy: .public) cwd=\(request.projectPath, privacy: .public)")
        }
        stopObservingIfIdle()
    }

    private func removePending(_ id: UUID) {
        if let request = pending.removeValue(forKey: id) {
            TempleUILog.reconcile.info("Codex adoption timed out with no match for cwd=\(request.projectPath, privacy: .public) within window=\(self.window)s")
        }
        stopObservingIfIdle()
    }

    private func stopObservingIfIdle() {
        guard pending.isEmpty, let observationID else { return }
        indexSource.removeObserver(observationID)
        self.observationID = nil
    }
}
