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
    /// The last title each agent gave itself. Claude and Codex retitle their
    /// terminal as the work moves on, but write that title nowhere on disk — so
    /// Temple remembers it, and a session keeps the name it earned even after it
    /// is closed and the app restarts.
    @Published public private(set) var generatedTitles: [String: String]

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
        self.generatedTitles = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.generatedTitle.map { (state.id, $0) }
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

    public func generatedTitle(for id: String) -> String? { generatedTitles[id] }

    /// How long live retitles coalesce before one publish + DB write. Every
    /// WORKING agent retitles about once a second, and `generatedTitles` is
    /// @Published on a store the whole app observes — flushing per tick meant
    /// a full re-render plus a synchronous DB write per title, per agent.
    var titleFlushDelay: TimeInterval = 1.0
    /// Latest unflushed title per session (last one in a window wins).
    private var pendingGeneratedTitles: [String: String] = [:]
    private var titleFlushTask: Task<Void, Never>?

    /// Record the agent's current self-assigned title. Cheap to call on every
    /// retitle: unchanged titles are dropped here, and changed ones batch into
    /// one flush per `titleFlushDelay` window.
    public func recordGeneratedTitle(_ title: String, for id: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, generatedTitles[id] != trimmed else { return }
        pendingGeneratedTitles[id] = trimmed
        guard titleFlushTask == nil else { return }
        titleFlushTask = Task { [weak self] in
            if let delay = self?.titleFlushDelay, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            self?.flushGeneratedTitles()
        }
    }

    private func flushGeneratedTitles() {
        titleFlushTask = nil
        for (id, title) in pendingGeneratedTitles where generatedTitles[id] != title {
            generatedTitles[id] = title
            try? db.setGeneratedTitle(title, sessionID: id)
        }
        pendingGeneratedTitles.removeAll()
    }

    /// Display title: a rename wins, then whatever the agent last called itself,
    /// then the title parsed from the session file (which is pinned to the first
    /// prompt and never catches up with a long session).
    public func displayTitle(for session: AgentSession) -> String {
        customName(for: session.id) ?? generatedTitle(for: session.id) ?? session.title
    }

    private static func openDefaultDatabase() -> TempleDB {
        if let db = try? TempleDB(path: TempleDB.defaultPath()) { return db }
        // A DB-open failure should not make the UI unusable; mutations remain
        // available for this process even though they cannot survive restart.
        return try! TempleDB.inMemory()
    }
}
