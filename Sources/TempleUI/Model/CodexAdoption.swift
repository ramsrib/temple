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
        reconcile(host: .local, projectPath: projectPath, startedAt: startedAt, adopt: adopt)
    }
    public func reconcile(host: HostID, projectPath: String, startedAt: Date, adopt: @escaping (String) -> Void) {
        guard let engine = indexSource.engine(for: host) else { return }
        // Start before registering so stop/start cannot cancel the new window.
        indexSource.startEngineIfNeeded()
        Task {
            let result = try? await engine.adopt(AdoptionRequest(directory: projectPath, startedAt: startedAt, window: window))
            guard !Task.isCancelled, case .adopted(let id, let locator) = result else { return }
            self.adoptedPaths[id] = locator.localURL
            adopt(id)
            self.adoptedPaths.removeValue(forKey: id)
        }
    }
}
