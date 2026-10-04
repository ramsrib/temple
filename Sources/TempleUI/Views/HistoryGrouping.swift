import SwiftUI
import TempleCore

/// One day on the History page, newest first within it.
public struct HistoryDayGroup: Identifiable, Equatable {
    public let day: Date
    public let title: String
    public var sessions: [TranscriptSummary]

    public var id: Date { day }
}

enum HistoryGrouping {
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let olderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// Groups an already-newest-first list in one pass, preserving its order
    /// within every day.
    static func groups(_ sessions: [TranscriptSummary], calendar: Calendar = .current,
                       now: Date = Date()) -> [HistoryDayGroup] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let currentYear = calendar.component(.year, from: now)
        var result: [HistoryDayGroup] = []

        for session in sessions {
            let day = calendar.startOfDay(for: session.modifiedAt)
            if result.last?.day == day {
                result[result.count - 1].sessions.append(session)
                continue
            }

            let title: String
            if day == today {
                title = "Today"
            } else if day == yesterday {
                title = "Yesterday"
            } else if calendar.component(.year, from: day) == currentYear {
                Self.weekdayFormatter.calendar = calendar
                Self.weekdayFormatter.timeZone = calendar.timeZone
                title = Self.weekdayFormatter.string(from: day)
            } else {
                Self.olderFormatter.calendar = calendar
                Self.olderFormatter.timeZone = calendar.timeZone
                title = Self.olderFormatter.string(from: day)
            }
            result.append(HistoryDayGroup(day: day, title: title, sessions: [session]))
        }
        return result
    }
}

public struct HistoryRowDayGroup: Identifiable, Equatable {
    public let day: Date
    public let title: String
    public var sessions: [HistoryRow]

    public var id: Date { day }
}

enum HistoryRowGrouping {
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let olderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// Groups an already-newest-first list in one pass, preserving its order
    /// within every day.
    static func groups(_ sessions: [HistoryRow], calendar: Calendar = .current,
                       now: Date = Date()) -> [HistoryRowDayGroup] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let currentYear = calendar.component(.year, from: now)
        var result: [HistoryRowDayGroup] = []

        for session in sessions {
            // A legacy member with no date at all (`Session.sortDate`) sorts
            // last; it gets a group that says so, not "Jan 1, 0001".
            let undated = session.updatedAt == .distantPast
            let day = undated ? Date.distantPast : calendar.startOfDay(for: session.updatedAt)
            if result.last?.day == day {
                result[result.count - 1].sessions.append(session)
                continue
            }

            let title: String
            if undated {
                title = "Unknown date"
            } else if day == today {
                title = "Today"
            } else if day == yesterday {
                title = "Yesterday"
            } else if calendar.component(.year, from: day) == currentYear {
                Self.weekdayFormatter.calendar = calendar
                Self.weekdayFormatter.timeZone = calendar.timeZone
                title = Self.weekdayFormatter.string(from: day)
            } else {
                Self.olderFormatter.calendar = calendar
                Self.olderFormatter.timeZone = calendar.timeZone
                title = Self.olderFormatter.string(from: day)
            }
            result.append(HistoryRowDayGroup(day: day, title: title, sessions: [session]))
        }
        return result
    }
}

/// Section rule shared by the History tab and the ⌘⇧Y archive browser.
struct HistoryHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .medium))
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.horizontal, 14)
    }
}
