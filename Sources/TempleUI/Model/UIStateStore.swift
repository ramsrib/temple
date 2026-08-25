import Foundation
import SwiftUI
import TempleCore

/// Window chrome the user arranged and expects to find the way they left it.
///
/// A third store, deliberately separate from the other two: `SettingsStore` holds
/// deliberate preferences (UserDefaults), `SessionOverlayStore` holds per-session
/// state (pins, names, colors), and this holds the shape of the window itself.
/// It lives in TempleDB so `TEMPLE_STATE_DIR` isolates it — a `make demo` run
/// must not decide what the installed app looks like on its next launch.
///
/// The settings layering rule applies here too: a missing key means "defer to the
/// shipped default", never "backfill me". Nothing is ever seeded with a computed
/// value, so there is nothing to migrate and nothing to tell apart later.
@MainActor
public final class UIStateStore {
    public enum Key {
        public static let sidebarVisibility = "sidebarVisibility"
    }

    private let db: TempleDB
    /// Read once at launch — SwiftUI reads these synchronously during `init`,
    /// and the set is a handful of short strings.
    private var cache: [String: String]

    public init(db: TempleDB) {
        self.db = db
        do {
            self.cache = try db.uiState()
        } catch {
            // An unreadable table is NOT an empty one. Both start the app on the
            // shipped defaults, but only one of them is a fault worth finding in
            // the log when a user reports their layout resetting every launch.
            self.cache = [:]
            TempleUILog.db.fault(
                "failed to read ui_state, falling back to shipped defaults: \(String(describing: error), privacy: .public)")
        }
    }

    public func string(_ key: String) -> String? { cache[key] }

    /// One key per write. `nil` clears the key, which is how a value returns to
    /// the shipped default rather than being pinned to a stand-in for "unset".
    ///
    /// The cache is updated either way: it mirrors what is on screen, and
    /// reverting it on a failed write would leave the store disagreeing with the
    /// window the user is looking at. What a failure must not do is pass
    /// silently — a disk that refuses this write is the exact condition that
    /// reproduces the bug this store was added to fix.
    public func write(_ value: String?, _ key: String) {
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        do {
            try db.setUIState(value, for: key)
        } catch {
            TempleUILog.db.error(
                "failed to persist ui_state \(key, privacy: .public) — it will not survive relaunch: \(String(describing: error), privacy: .public)")
        }
    }
}

extension UIStateStore {
    /// `nil` when nothing is stored or the stored value is unrecognised — either
    /// way the caller falls back to the shipped default.
    var sidebarVisibility: NavigationSplitViewVisibility? {
        string(Key.sidebarVisibility).flatMap(NavigationSplitViewVisibility.init(persisted:))
    }

    func setSidebarVisibility(_ visibility: NavigationSplitViewVisibility) {
        write(visibility.persisted, Key.sidebarVisibility)
    }
}

extension NavigationSplitViewVisibility {
    /// Whether the sidebar column is hidden.
    ///
    /// **Test this, never `== .all`.** The type is a struct of kind +
    /// `isAutomatic`, not an enum, and `.automatic` and `.doubleColumn` both
    /// carry `kind: .doubleColumn` — so neither equals `.all`. A toggle written
    /// as `== .all ? .detailOnly : .all` therefore assigns `.all` to an
    /// already-visible sidebar the moment SwiftUI writes either of those through
    /// the binding: one press of ⌘B that visibly does nothing.
    var isSidebarHidden: Bool { self == .detailOnly }

    /// Persisted form — the hidden/shown distinction, which is the only thing
    /// the user expressed.
    ///
    /// It cannot be finer than that: `==` on this type compares `kind` alone and
    /// ignores `isAutomatic`, so `.automatic` and `.doubleColumn` are equal to
    /// each other and there is no way to tell "SwiftUI has not been told" from
    /// "both columns, deliberately". Measured, not assumed. Both render a shown
    /// sidebar in a two-column split, so both persist as shown — which preserves
    /// what the user is looking at instead of deleting it.
    var persisted: String {
        isSidebarHidden ? "detailOnly" : "all"   // .all, .doubleColumn, .automatic
    }

    init?(persisted: String) {
        switch persisted {
        case "all": self = .all
        case "detailOnly": self = .detailOnly
        default: return nil
        }
    }
}
