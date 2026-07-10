import Foundation
import Combine
import TempleCore

/// App-state overlay the CLIs don't track: pins + custom names (ADR-009).
///
/// Values are cached in memory for synchronous SwiftUI reads and written
/// through to TempleDB on mutation.
@MainActor
public final class SessionOverlayStore: ObservableObject {
    @Published public private(set) var pinned: Set<String>
    @Published public private(set) var customNames: [String: String]

    private let db: TempleDB

    public init(db: TempleDB) {
        self.db = db
        let states = (try? db.sessionStates()) ?? []
        self.pinned = Set(states.lazy.filter(\.pinned).map(\.id))
        self.customNames = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.customName.map { (state.id, $0) }
            }
        )
    }

    public convenience init() {
        self.init(db: Self.openDefaultDatabase())
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        try? db.setPinned(pinned.contains(id), sessionID: id)
    }

    public func customName(for id: String) -> String? { customNames[id] }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: id)
        } else {
            customNames[id] = trimmed
        }
        try? db.setCustomName(customNames[id], sessionID: id)
    }

    /// Display title = custom name if set, else the on-disk title.
    public func displayTitle(for session: AgentSession) -> String {
        customName(for: session.id) ?? session.title
    }

    private static func openDefaultDatabase() -> TempleDB {
        if let db = try? TempleDB(path: TempleDB.defaultPath()) { return db }
        // A DB-open failure should not make the UI unusable; mutations remain
        // available for this process even though they cannot survive restart.
        return try! TempleDB.inMemory()
    }
}
