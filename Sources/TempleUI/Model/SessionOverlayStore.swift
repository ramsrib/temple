import Foundation
import Combine
import TempleCore

/// App-state overlay the CLIs don't track: pins, custom names, and color marks (ADR-009).
///
/// Values are cached in memory for synchronous SwiftUI reads and written
/// through to TempleDB on mutation.
@MainActor
public final class SessionOverlayStore: ObservableObject {
    @Published public private(set) var pinned: Set<String>
    @Published public private(set) var customNames: [String: String]
    @Published public private(set) var colors: [String: String]
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
        self.colors = Dictionary(
            uniqueKeysWithValues: states.compactMap { state in
                state.color.map { (state.id, $0) }
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

    public func color(for id: String) -> String? { colors[id] }

    public func setColor(_ name: String?, for id: String) {
        if let name {
            colors[id] = name
        } else {
            colors.removeValue(forKey: id)
        }
        try? db.setColor(colors[id], sessionID: id)
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
        guard !trimmed.isEmpty else { return }
        // Compare against what the flush WOULD publish (pending first), not
        // just what is published: a title that returns to the published value
        // mid-window must clear the pending intermediate, or the flush would
        // regress to it ("Ready" → "Thinking" → "Ready" must stay "Ready").
        guard (pendingGeneratedTitles[id] ?? generatedTitles[id]) != trimmed else { return }
        if generatedTitles[id] == trimmed {
            pendingGeneratedTitles.removeValue(forKey: id)
            return
        }
        pendingGeneratedTitles[id] = trimmed
        guard titleFlushTask == nil else { return }
        titleFlushTask = Task { [weak self] in
            if let delay = self?.titleFlushDelay, delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // A cancelled task must not fire a second, early flush after
            // `flushPendingTitles()` already ran it.
            guard !Task.isCancelled else { return }
            self?.flushGeneratedTitles()
        }
    }

    /// Quit paths call this so the last title an agent gave itself survives
    /// the coalescing window — losing it is losing the one thing this store
    /// exists to keep.
    public func flushPendingTitles() {
        titleFlushTask?.cancel()
        flushGeneratedTitles()
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

    /// session id → the displayed title, for search (same precedence as
    /// `displayTitle(for:)`): a session must be findable under the name the
    /// list shows, not only under the file title nobody sees anymore.
    public var displayTitleOverrides: [String: String] {
        generatedTitles.merging(customNames) { _, custom in custom }
    }

    private static func openDefaultDatabase() -> TempleDB {
        if let db = try? TempleDB(path: TempleDB.defaultPath()) { return db }
        // A DB-open failure should not make the UI unusable; mutations remain
        // available for this process even though they cannot survive restart.
        return try! TempleDB.inMemory()
    }
}
