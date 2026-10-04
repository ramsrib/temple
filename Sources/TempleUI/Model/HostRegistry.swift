import Foundation
import TempleCore
import TempleTerminalAPI

/// Transcript and launch seams share one host entry. Production ships local only.
public struct HostRegistry: Sendable {
    public struct Entry: Sendable {
        public let source: any HostSessionSource
        public let launcher: any HostLauncher
        public init(source: any HostSessionSource, launcher: any HostLauncher) {
            self.source = source; self.launcher = launcher
        }
    }
    public let entries: [Entry]
    @MainActor public init(entries: [Entry]? = nil) {
        let entries = entries ?? [Entry(source: LocalSessionSource(), launcher: LocalHostLauncher())]
        precondition(Set(entries.map { $0.source.host }).count == entries.count)
        self.entries = entries
    }
    public func entry(for host: HostID) -> Entry? { entries.first { $0.source.host == host } }
    func catalog() -> AsyncStream<CatalogBatch> {
        AsyncStream { continuation in
            let task = Task {
                for entry in entries where entry.source.capabilities.contains(.catalog) {
                    do {
                        for try await batch in entry.source.catalog(CatalogQuery()) {
                            guard !Task.isCancelled else { continuation.finish(); return }
                            continuation.yield(batch)
                        }
                    } catch {
                        // A failed host cannot establish absence. History retains members.
                        continuation.yield(.storeFailed(agent: nil, message: error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
