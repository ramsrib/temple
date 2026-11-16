import Foundation

/// How the sidebar lists projects and sessions: the rail's View Options menu
/// (`SidebarViewOptionsMenu`). Window chrome the user arranged, so it lives in
/// `UIStateStore` (TempleDB, isolated by `TEMPLE_STATE_DIR`), one key per
/// option, written only when the user picks one. A missing key is the shipped
/// default, never backfilled.
public struct SidebarOptions: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        /// Most recent activity first, kept live; nothing moves while the
        /// pointer is over the sidebar.
        case recentActivity
        /// The order dragged by hand (ADR-017): projects nobody has placed
        /// stay above the placed ones.
        case custom
        case name

        public var title: String {
            switch self {
            case .recentActivity: "Recent Activity"
            case .custom: "Manual Order"
            case .name: "Name"
            }
        }
    }

    public enum Grouping: String, CaseIterable, Sendable {
        case project
        /// Each machine a heading, its projects under it.
        case machine

        public var title: String {
            switch self {
            case .project: "Project"
            case .machine: "Machine"
            }
        }
    }

    public enum Show: String, CaseIterable, Sendable {
        /// Open sessions, then recently active closed ones.
        case openAndRecent
        case openOnly

        public var title: String {
            switch self {
            case .openAndRecent: "Open and Recent"
            case .openOnly: "Open Only"
            }
        }
    }

    /// How far back a closed session counts as recent: the ones a project
    /// lists under its open sessions without a Show more.
    public enum RecentWindow: String, CaseIterable, Sendable {
        case day, week, month

        public var interval: TimeInterval {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }

        public var title: String {
            switch self {
            case .day: "Last Day"
            case .week: "Last Week"
            case .month: "Last Month"
            }
        }
    }

    public var sort: Sort
    public var grouping: Grouping
    public var show: Show
    public var recentWindow: RecentWindow

    public init(sort: Sort = .recentActivity, grouping: Grouping = .project,
                show: Show = .openAndRecent, recentWindow: RecentWindow = .week) {
        self.sort = sort
        self.grouping = grouping
        self.show = show
        self.recentWindow = recentWindow
    }

    /// Sessions a project lists before its Show more: every open one, then
    /// recent ones up to this many rows in all.
    public static let rowsBeforeShowMore = 6
}

extension UIStateStore {
    enum SidebarKey {
        static let sort = "sidebarSort"
        static let grouping = "sidebarGrouping"
        static let show = "sidebarShow"
        static let recentWindow = "sidebarRecentWindow"
    }

    /// The stored options. `customByDefault`: with no sort stored, a user who
    /// has ever dragged a project keeps the order they dragged, as before the
    /// menu existed; that is the shipped default reading the user's data, not
    /// a value written for them.
    func sidebarOptions(customByDefault: Bool) -> SidebarOptions {
        SidebarOptions(
            sort: string(SidebarKey.sort).flatMap(SidebarOptions.Sort.init) ?? (customByDefault ? .custom : .recentActivity),
            grouping: string(SidebarKey.grouping).flatMap(SidebarOptions.Grouping.init) ?? .project,
            show: string(SidebarKey.show).flatMap(SidebarOptions.Show.init) ?? .openAndRecent,
            recentWindow: string(SidebarKey.recentWindow).flatMap(SidebarOptions.RecentWindow.init) ?? .week)
    }
}
