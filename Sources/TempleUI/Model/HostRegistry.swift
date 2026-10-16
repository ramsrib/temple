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
    public init(entries: [Entry]) {
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

public extension HostRegistry {
    /// This registry with `entry` added (a host enabled in Settings).
    func adding(_ entry: Entry) -> HostRegistry {
        guard self.entry(for: entry.source.host) == nil else { return self }
        return HostRegistry(entries: entries + [entry])
    }

    /// This registry without `host` (removed or disabled). Never the local host.
    func removing(_ host: HostID) -> HostRegistry {
        guard !host.isLocal else { return self }
        return HostRegistry(entries: entries.filter { $0.source.host != host })
    }
}

/// The registry as it stands now, for the closures that outlive one value
/// of it (launches, folder evidence, History's catalog): hosts are added
/// and removed while the app runs.
final class HostRegistryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostRegistry
    init(_ registry: HostRegistry) { current = registry }
    var value: HostRegistry {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// One host's catalog batch, as `HostRegistry.catalog` delivers it.
public struct HostCatalogEvent: Equatable, Sendable {
    public let host: HostID
    public let batch: CatalogBatch
    public init(host: HostID, batch: CatalogBatch) { self.host = host; self.batch = batch }
}
