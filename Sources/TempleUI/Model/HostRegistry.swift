import Foundation
import TempleCore
import TempleTerminalAPI

/// Transcript and launch seams share one host entry. Production ships local only.
public struct HostRegistry: Sendable {
    public struct Entry: Sendable {
        public let source: any HostSessionSource
        public let commandWrapper: any HostCommandWrapper
        public init(source: any HostSessionSource, commandWrapper: any HostCommandWrapper) {
            self.source = source; self.commandWrapper = commandWrapper
        }
    }
    public let entries: [Entry]
    public init(entries: [Entry] = [Entry(source: LocalSessionSource(), commandWrapper: LocalCommandWrapper())]) {
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
                        continuation.yield(.storeFailed(.claude, message: error.localizedDescription))
                        continuation.yield(.storeFailed(.codex, message: error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
