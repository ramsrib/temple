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
    /// Every host's catalog at once, each event tagged with its host. Hosts
    /// are read concurrently, so a slow or dead one holds up no other; a host
    /// whose read throws reports `.storeFailed(agent: nil, …)` for itself and
    /// the rest carry on. Ending the consumer cancels every read.
    public func catalog(_ query: CatalogQuery = CatalogQuery()) -> AsyncStream<HostCatalogEvent> {
        let sources = entries.map(\.source).filter { $0.capabilities.contains(.catalog) }
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for source in sources {
                        group.addTask {
                            let host = source.host
                            do {
                                for try await batch in source.catalog(query) {
                                    guard !Task.isCancelled else { return }
                                    continuation.yield(HostCatalogEvent(host: host, batch: batch))
                                }
                            } catch {
                                // A failed host cannot establish absence. History retains members.
                                guard !Task.isCancelled else { return }
                                continuation.yield(HostCatalogEvent(host: host,
                                    batch: .storeFailed(agent: nil, message: error.localizedDescription)))
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One host's catalog batch, as `HostRegistry.catalog` delivers it.
public struct HostCatalogEvent: Equatable, Sendable {
    public let host: HostID
    public let batch: CatalogBatch
    public init(host: HostID, batch: CatalogBatch) { self.host = host; self.batch = batch }
}
