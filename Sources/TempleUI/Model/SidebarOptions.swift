import Foundation

/// How the sidebar lists projects and sessions: the rail's View Options menu
/// (`SidebarViewOptionsMenu`). Window chrome the user arranged, so it lives in
/// `UIStateStore` (TempleDB, isolated by `TEMPLE_STATE_DIR`), one key per
/// option, written only when the user picks one. A missing key is the shipped
/// default, never backfilled.
public struct SidebarOptions: Equatable, Sendable {
    /// How projects are ordered.
    public enum Sort: String, CaseIterable, Sendable {
        /// Most recent activity first, kept live; nothing moves while the
        /// pointer is over the sidebar.
        case recentActivity
        case name
        /// The order dragged by hand (ADR-017): projects nobody has placed
        /// stay above the placed ones. Last in the menu, as in the session
        /// sort.
        case custom

        public var title: String {
            switch self {
            case .recentActivity: "Recent Activity"
            case .custom: "Custom"
            case .name: "Name"
            }
        }
    }

    /// How a project's closed sessions are ordered. Its open sessions come
    /// first whatever this says, in the order of their tabs.
    public enum SessionSort: String, CaseIterable, Sendable {
        case recentActivity
        case name
        /// When the session began, newest first.
        case dateStarted
        /// The order dragged by hand within the project; sessions nobody
        /// has placed stay above the placed ones, newest first.
        case custom

        public var title: String {
            switch self {
            case .recentActivity: "Recent Activity"
            case .name: "Name"
            case .dateStarted: "Date Started"
            case .custom: "Custom"
            }
        }
    }

    public enum Grouping: String, CaseIterable, Sendable {
        case project
        /// Each host a heading, its projects under it.
        case machine
    }

    public var sort: Sort
    public var sessionSort: SessionSort
    public var grouping: Grouping
    /// Only open sessions, and only projects that have one. A search still
    /// finds everything.
    public var openOnly: Bool

    public init(sort: Sort = .recentActivity, sessionSort: SessionSort = .recentActivity,
                grouping: Grouping = .machine, openOnly: Bool = false) {
        self.sort = sort
        self.sessionSort = sessionSort
        self.grouping = grouping
        self.openOnly = openOnly
    }

    /// Sessions a project lists before its Show older: every open one, then
    /// recent ones up to this many rows in all.
    public static let rowsBeforeShowMore = 6
    /// How far back a closed session counts as recent: the ones a project
    /// lists under its open sessions. Fixed: a setting for it read as noise
    /// (owner, 2026-11-16).
    public static let recentWindow: TimeInterval = 7 * 86_400
}

extension UIStateStore {
    enum SidebarKey {
        static let sort = "sidebarSort"
        static let sessionSort = "sidebarSessionSort"
        static let grouping = "sidebarGrouping"
        static let openOnly = "sidebarOpenOnly"
        /// Each project's dragged session order (JSON, `SessionOrderStore`).
        static let sessionOrder = "sidebarSessionOrder"
    }

    /// The stored options. `customByDefault`: with no sort stored, a user who
    /// has ever dragged a project keeps the order they dragged, as before the
    /// menu existed; that is the shipped default reading the user's data, not
    /// a value written for them.
    func sidebarOptions(customByDefault: Bool) -> SidebarOptions {
        SidebarOptions(
            sort: string(SidebarKey.sort).flatMap(SidebarOptions.Sort.init) ?? (customByDefault ? .custom : .recentActivity),
            sessionSort: string(SidebarKey.sessionSort).flatMap(SidebarOptions.SessionSort.init) ?? .recentActivity,
            // Group by Host is the default (owner, round 3); it only shows
            // once a project is on a host, and a choice made is kept.
            grouping: string(SidebarKey.grouping).flatMap(SidebarOptions.Grouping.init) ?? .machine,
            openOnly: string(SidebarKey.openOnly) == "1")
    }
}
