import Foundation

/// Explicit, on-demand disk history. No watcher, membership, or retained cache.
public struct SessionCatalog: Sendable {
    private let stores: [any SessionStore]
    public init(stores: [any SessionStore] = [ClaudeSessionStore(), CodexSessionStore()]) {
        self.stores = stores
    }
    public func load() -> SessionIndex { SessionIndex.build(stores: stores) }
}
