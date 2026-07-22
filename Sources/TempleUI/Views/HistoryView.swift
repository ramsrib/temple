import SwiftUI
import TempleCore

struct HistoryDayGroup: Identifiable {
    let day: Date
    let title: String
    var sessions: [AgentSession]

    var id: Date { day }
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
    static func groups(_ sessions: [AgentSession], calendar: Calendar = .current,
                       now: Date = Date()) -> [HistoryDayGroup] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let currentYear = calendar.component(.year, from: now)
        var result: [HistoryDayGroup] = []

        for session in sessions {
            let day = calendar.startOfDay(for: session.updatedAt)
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

/// ⌘Y: a chronological, searchable view across the complete non-noise index.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var groups: [HistoryDayGroup] = []
    @State private var flatResults: [AgentSession] = []
    @State private var indexByID: [AgentSession.ID: Int] = [:]
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var grouped: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var headerCount: Int { grouped ? groups.count : 0 }

    private var listHeight: CGFloat {
        min(CGFloat(flatResults.count) * Self.rowHeight
            + CGFloat(headerCount) * Self.headerHeight, 460)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search session history…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

            Divider()

            if flatResults.isEmpty {
                Text(grouped ? "No sessions yet" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Keep this eager. As in CommandPaletteView, LazyVStack
                        // can leave an already-materialized row's selection fill
                        // stale while the keyboard highlight moves.
                        VStack(spacing: 0) {
                            ForEach(groups) { group in
                                if grouped {
                                    HistoryHeader(title: group.title)
                                        .frame(height: Self.headerHeight)
                                }
                                ForEach(group.sessions) { session in
                                    let index = indexByID[session.id] ?? 0
                                    HistoryResultRow(
                                        session: session,
                                        selected: index == selection
                                    ) {
                                        selection = index
                                        open(session)
                                    }
                                    .frame(height: Self.rowHeight)
                                }
                            }
                        }
                    }
                    .frame(height: listHeight)
                    .thinScrollers()
                    .onChange(of: selection) {
                        if flatResults.indices.contains(selection) {
                            proxy.scrollTo(flatResults[selection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 640)
        .panelChrome()
        .onAppear {
            reload()
            FieldFocus.claim { fieldFocused = true }
        }
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onChange(of: query) { _, _ in reload() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.historyPresented = false; return .handled }
    }

    private static let rowHeight: CGFloat = 52
    private static let headerHeight: CGFloat = 27

    private func reload() {
        let results = Array(model.historyResults(query).prefix(250))
        flatResults = results
        indexByID = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($0.element.id, $0.offset) })
        if grouped {
            groups = HistoryGrouping.groups(results)
        } else {
            groups = results.isEmpty
                ? []
                : [HistoryDayGroup(day: .distantPast, title: "", sessions: results)]
        }
        selection = 0
    }

    private func move(_ delta: Int) {
        guard !flatResults.isEmpty else { return }
        selection = max(0, min(flatResults.count - 1, selection + delta))
    }

    private func openSelected() {
        guard flatResults.indices.contains(selection) else { return }
        open(flatResults[selection])
    }

    private func open(_ session: AgentSession) {
        model.openSessions.openSession(session)
        model.historyPresented = false
    }
}

private struct HistoryHeader: View {
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

private struct HistoryResultRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let selected: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(agent: session.agent, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayTitle(session))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(session.lastMessagePreview ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.projectName(session.projectPath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(RelativeTime.string(from: session.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Palette.selectionFill
                             : (hovering ? Palette.hoverFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}
