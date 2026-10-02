import Foundation
import TempleCore

/// Uses the engine's metadata-only candidate channel, separate from membership.
@MainActor
public final class WatcherCodexReconciler: CodexAdopting {
    private let indexSource: WatcherIndexSource
    private let window: TimeInterval
    private var adoptedPaths: [String: URL] = [:]
    public func transcriptPath(for sessionID: String) -> URL? { adoptedPaths.removeValue(forKey: sessionID) }
    public init(indexSource: WatcherIndexSource, window: TimeInterval = 5) {
        self.indexSource = indexSource; self.window = window
    }
    public convenience init(window: TimeInterval = 5) {
        self.init(indexSource: WatcherIndexSource(), window: window)
    }
    public func reconcile(projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        indexSource.watcher.registerAdoption(projectPath: projectPath, startedAt: startedAt, window: window) { [weak self] candidate in
            Task { @MainActor [weak self] in
                guard let candidate, let self else { return }
                self.adoptedPaths[candidate.sessionID] = candidate.filePath
                adopt(candidate.sessionID)
                self.adoptedPaths.removeValue(forKey: candidate.sessionID)
            }
        }
        // Starts the same stream if a new tab precedes AppModel.start().
        indexSource.startEngineIfNeeded()
    }
}
