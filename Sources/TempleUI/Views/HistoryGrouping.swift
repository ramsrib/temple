import SwiftUI
import TempleCore

/// One day on the History page, newest first within it: a slice of the
/// projection's visible rows, so grouping copies nothing.
public struct HistoryRowDayGroup: Identifiable, Equatable, Sendable {
    public let day: Date
    public let title: String
    public var sessions: ArraySlice<HistoryRow>

    public var id: Date { day }
}

enum HistoryRowGrouping {
    /// Day titles for one projection: the formatters are built once a
    /// projection, never per row.
    struct Titles {
        private let calendar: Calendar
        let today: Date
        private let yesterday: Date?
        private let currentYear: Int
        private let weekday: DateFormatter
        private let older: DateFormatter

        init(calendar: Calendar, now: Date) {
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            currentYear = calendar.component(.year, from: now)
            func formatter(_ format: String) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                return formatter
            }
            weekday = formatter("EEEE, MMM d")
            older = formatter("MMM d, yyyy")
        }

        func title(for day: Date) -> String {
            // A legacy member with no date at all (`Session.sortDate`) sorts
            // last; it gets a group that says so, not "Jan 1, 0001".
            if day == .distantPast { return "Unknown date" }
            if day == today { return "Today" }
            if day == yesterday { return "Yesterday" }
            if calendar.component(.year, from: day) == currentYear { return weekday.string(from: day) }
            return older.string(from: day)
        }
    }

    /// Groups an already-newest-first list in one pass, preserving its order
    /// within every day. Each row carries its day (`HistoryRow.day`); a
    /// title is computed once a group.
    static func groups(_ sessions: [HistoryRow], calendar: Calendar = .current,
                       now: Date = Date()) -> [HistoryRowDayGroup] {
        groups(sessions, titles: Titles(calendar: calendar, now: now)) { row in
            row.updatedAt == .distantPast ? .distantPast : calendar.startOfDay(for: row.updatedAt)
        }.groups
    }

    /// The groups, and the index in `sessions` where each one starts.
    static func groups(_ sessions: [HistoryRow], titles: Titles,
                       day: (HistoryRow) -> Date = { $0.day }) -> (groups: [HistoryRowDayGroup], starts: [Int]) {
        var result: [HistoryRowDayGroup] = []
        var starts: [Int] = []
        var start = 0
        while start < sessions.count {
            let first = day(sessions[start])
            var end = start + 1
            while end < sessions.count, day(sessions[end]) == first { end += 1 }
            result.append(HistoryRowDayGroup(day: first, title: titles.title(for: first), sessions: sessions[start..<end]))
            starts.append(start)
            start = end
        }
        return (result, starts)
    }
}

/// The History tab's day rule.
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
