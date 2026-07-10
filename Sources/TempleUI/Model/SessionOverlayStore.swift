import Foundation
import Combine
import TempleCore

/// App-state overlay the CLIs don't track: pins + custom names (ADR-009).
///
/// **Seam for Track C5.** Persisted in `UserDefaults` today; when C5's
/// `session_state` table lands, back these by the DB (same API). Overlaid onto
/// the on-disk index at display time (U5).
@MainActor
public final class SessionOverlayStore: ObservableObject {
    @Published public private(set) var pinned: Set<String>
    @Published public private(set) var customNames: [String: String]

    private let defaults: UserDefaults
    private let pinnedKey = "temple.pinnedSessionIDs"
    private let namesKey = "temple.customSessionNames"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        self.customNames = (defaults.dictionary(forKey: namesKey) as? [String: String]) ?? [:]
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        defaults.set(Array(pinned), forKey: pinnedKey)
    }

    public func customName(for id: String) -> String? { customNames[id] }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: id)
        } else {
            customNames[id] = trimmed
        }
        defaults.set(customNames, forKey: namesKey)
    }

    /// Display title = custom name if set, else the on-disk title.
    public func displayTitle(for session: AgentSession) -> String {
        customName(for: session.id) ?? session.title
    }
}
