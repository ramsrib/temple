import Foundation
import Combine
import TempleCore

/// App-state overlay the CLIs don't track: pins, custom names, color marks,
/// archive state, and the manual project order (ADR-009).
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
    /// Archived sessions and projects: hidden from every browse surface, found
    /// again only in the ⌘⇧Y archive browser.
    @Published public private(set) var archivedSessions: Set<String>
    @Published public private(set) var archivedProjects: Set<String>
    /// Temple's sessions: every one it started, opened, or had pinned, renamed,
    /// colored or archived. Exactly the sessions with a row in the DB — each
    /// write below joins its session first — and, at the default session
    /// scope, the only ones anything lists.
    @Published public private(set) var templeSessions: Set<String>
    /// The sidebar order the user arranged, outermost first. Only projects the
    /// user has actually placed appear here; everything else stays on the
    /// launch-frozen recency order.
    @Published public private(set) var projectOrder: [String]

    private let db: TempleDB

    public init(db: TempleDB) {
        self.db = db
        let states = (try? db.sessionStates()) ?? []
        let projects = (try? db.projectStates()) ?? []
        self.pinned = Set(states.lazy.filter(\.pinned).map(\.id))
        self.archivedSessions = Set(states.lazy.filter(\.archived).map(\.id))
        self.templeSessions = Set(states.lazy.map(\.id))
        self.archivedProjects = Set(projects.lazy.filter(\.archived).map(\.path))
        self.projectOrder = projects
            .compactMap { state in state.position.map { ($0, state.path) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
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

    public func isTempleSession(_ id: String) -> Bool { templeSessions.contains(id) }

    /// The session becomes Temple's, if it is not already. Called on every
    /// open, so a session Temple knows returns before publishing or touching
    /// the DB. How it joined is recorded only by the first join (see `TempleDB`).
    ///
    /// Membership follows the row, not the attempt: a failed write leaves the
    /// id out, and whatever touches the session next joins it then. Returns
    /// whether the session is Temple's now; every setter below stops when it
    /// is not, because its own write would insert a row that says nothing
    /// about how the session joined, behind the set's back.
    ///
    /// A failed write is not retried — the same as every other write in this
    /// store (a pin, a name, a title). Local SQLite writes fail essentially
    /// never, and a retry ledger for them grew a new edge case per review
    /// round; what matters is that failure never shows the wrong sessions.
    @discardableResult
    public func join(_ id: String, via: JoinedVia) -> Bool {
        guard !templeSessions.contains(id) else { return true }
        do {
            try db.join(sessionID: id, via: via)
            templeSessions.insert(id)
            return true
        } catch {
            TempleUILog.db.error("join failed for session \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func togglePin(_ id: String) {
        guard join(id, via: .imported) else { return }
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        try? db.setPinned(pinned.contains(id), sessionID: id)
    }

    public func isArchived(_ id: String) -> Bool { archivedSessions.contains(id) }

    /// Archiving drops the pin: a session cannot be both the one you always
    /// want in front of you and one you have put away. Unarchiving does not
    /// bring it back — the pin was a separate decision, and re-pinning is a
    /// click. The DB write clears the pin in the same statement.
    public func setArchived(_ archived: Bool, sessionID id: String) {
        guard join(id, via: .imported) else { return }
        if archived {
            archivedSessions.insert(id)
            pinned.remove(id)
        } else {
            archivedSessions.remove(id)
        }
        try? db.setArchived(archived, sessionID: id)
    }

    public func isProjectArchived(_ path: String) -> Bool { archivedProjects.contains(path) }

    public func setProjectArchived(_ archived: Bool, path: String) {
        if archived { archivedProjects.insert(path) } else { archivedProjects.remove(path) }
        try? db.setProjectArchived(archived, path: path)
    }

    /// The whole manual order, not a delta: the caller hands over the full
    /// list it wants the sidebar to show, so a reorder can never leave two
    /// projects sharing a slot.
    public func setProjectOrder(_ paths: [String]) {
        projectOrder = paths
        try? db.setProjectOrder(paths)
    }

    public func customName(for id: String) -> String? { customNames[id] }

    public func rename(_ id: String, to name: String) {
        guard join(id, via: .imported) else { return }
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
        guard join(id, via: .imported) else { return }
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
            // A title never makes a session Temple's: it only follows a join.
            // Every way into a tab joins first, so a title for a session that
            // is not a member means that join failed; the title is shown but
            // not written, rather than writing a row that forgets how the
            // session joined.
            guard isTempleSession(id) else { continue }
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
