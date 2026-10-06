import SwiftUI
import TempleCore

/// ⌘K global quick-open (U8): ranked title match over the whole index. Enter
/// opens/focuses the session's tab (switching active project).
struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var cursor = PaletteCursor()
    /// Activity reorders the open-session list without AppModel publishing
    /// (B9): the open palette redraws itself when what it shows would change.
    @StateObject private var recency = RecencyRefresh()
    @FocusState private var fieldFocused: Bool

    private var results: [Session] { Self.results(query, model: model) }

    static func results(_ query: String, model: AppModel) -> [Session] {
        Array(model.paletteResults(query).prefix(40))
    }

    /// Return: the highlighted session — found by its id in the results as
    /// they are now, uncapped, so neither a reorder since the last draw nor
    /// activity pushing it past the 40-row cap can swap it for another. A
    /// highlighted session that is no longer listed at all opens nothing:
    /// the redraw moves the highlight, and the next Return follows it.
    /// With no results, or with the trailing "Search history for …" row
    /// highlighted, the query goes to History.
    static func submit(_ cursor: PaletteCursor, query: String, model: AppModel) {
        let all = model.paletteResults(query)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, all.isEmpty || cursor.onHistoryRow {
            model.searchHistory(trimmed)
            return
        }
        let session: Session?
        if let id = cursor.selectedID {
            session = all.first { $0.id == id }
        } else {
            session = all.first
        }
        guard let session else { return }
        model.openPaletteResult(session)
    }

    var body: some View {
        // One ranking pass per render: the palette re-renders on every title
        // tick while it's open, and a typed query ranks the whole index.
        let results = self.results
        let selection = cursor.index(in: results)
        let historyRow = !trimmedQuery.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onChange(of: query) {
                        cursor = PaletteCursor()
                        cursor.anchor(in: self.results)
                        watchRecency()
                    }
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

            if results.isEmpty, historyRow {
                // ⌘K only knows Temple's sessions. Its dead end points at the
                // door: the one row opens History already searching for it.
                SearchHistoryRow(query: trimmedQuery, selected: true) { searchHistory() }
                    .frame(height: Self.rowHeight)
            } else if results.isEmpty {
                Text("No open sessions — type to search all")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // A plain VStack (≤40 cheap rows): LazyVStack left
                        // already-materialized rows with a stale `selected`
                        // highlight when arrowing (two rows lit at once).
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, session in
                                PaletteResultRow(session: session,
                                                 selected: idx == selection) {
                                    cursor.select(session)
                                    openSelected()
                                }
                                .frame(height: Self.rowHeight)
                            }
                        }
                    }
                    // Hug the rows (a ScrollView greedily fills its proposal,
                    // leaving dead space under short result lists); scroll
                    // only past the cap.
                    .frame(height: min(CGFloat(results.count) * Self.rowHeight, 340))
                    .thinScrollers()
                    .onChange(of: cursor) {
                        if !cursor.onHistoryRow, let id = cursor.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                if historyRow {
                    // Archived and outside sessions are never in ⌘K, so a
                    // query always has a way on to History: the last row,
                    // under the list rather than in it, so it never scrolls
                    // away. ↓ past the last result reaches it.
                    SearchHistoryRow(query: trimmedQuery, selected: cursor.onHistoryRow) { searchHistory() }
                        .frame(height: Self.rowHeight)
                }
            }
        }
        .frame(width: 560)
        .panelChrome()
        // The terminal (a raw AppKit view) holds the window's first responder and
        // SwiftUI focus can't take it — so ⌘K used to open a field that never
        // received a keystroke, while everything typed went to the agent.
        .onAppear {
            // The highlight is a session from the first draw on, never "row 0".
            cursor.anchor(in: results)
            watchRecency()
            FieldFocus.claim { fieldFocused = true }
        }
        // A redraw can drop the highlighted session (its tab closed): the
        // highlight moves to a row that is listed, and Return follows it.
        .onChange(of: results.map(\.id)) { cursor.anchor(in: results) }
        // Keys typed before the field had the keyboard are sent again now
        // that it has, in order and before any newer key (PanelKeyHold).
        .onChange(of: fieldFocused) { _, focused in
            if focused { model.panelKeys.fieldFocused() }
        }
        // Closing hands the keyboard back to the agent we took it from.
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.commandPalettePresented = false; return .handled }
    }

    /// Fixed row height so the list height is exact (two text lines + padding).
    private static let rowHeight: CGFloat = 46

    private func move(_ delta: Int) {
        cursor.move(delta, in: results, historyRow: !trimmedQuery.isEmpty)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Watch what this query shows: a typed search reorders by activity too
    /// (ties in rank), not only the open-session list. Restarted per query.
    private func watchRecency() {
        let query = self.query
        recency.watch(model.overlay) { [weak model] in
            AnyHashable(model.map { Self.results(query, model: $0).map(\.id) } ?? [])
        }
    }

    private func openSelected() {
        Self.submit(cursor, query: query, model: model)
    }

    private func searchHistory() {
        model.searchHistory(trimmedQuery)
    }
}

/// The palette's highlight, held as a session id rather than a row index:
/// the list can reorder between a draw and Return (activity after the rank
/// freeze redraws nothing), and an index would then open whichever session
/// slid into that row. The highlight drawn and the session Return opens are
/// both `selected(in:)` of the same id.
///
/// Below the results, a typed query has one more row, "Search history for
/// …" (`onHistoryRow`); it is reached with ↓ from the last result and left
/// with ↑.
struct PaletteCursor: Equatable {
    private(set) var selectedID: String?
    /// The trailing "Search history for …" row is highlighted, not a session.
    private(set) var onHistoryRow = false

    /// The highlighted result row: the selected session where it is listed,
    /// else the first; nil while the history row has the highlight.
    func index(in results: [Session]) -> Int? {
        guard !results.isEmpty, !onHistoryRow else { return nil }
        return selectedID.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    func selected(in results: [Session]) -> Session? { index(in: results).map { results[$0] } }

    /// Pin the highlight to the session it is drawn on (the first row when
    /// nothing listed is selected). The history row keeps it.
    mutating func anchor(in results: [Session]) {
        guard !onHistoryRow else { return }
        selectedID = selected(in: results)?.id
    }

    mutating func select(_ session: Session) {
        selectedID = session.id
        onHistoryRow = false
    }

    /// - Parameter historyRow: the trailing history row is showing.
    mutating func move(_ delta: Int, in results: [Session], historyRow: Bool = false) {
        if onHistoryRow {
            guard delta < 0 else { return }
            onHistoryRow = false
            selectedID = results.last?.id
            return
        }
        guard let current = index(in: results) else {
            if historyRow, delta > 0 { onHistoryRow = true }
            return
        }
        if historyRow, current + delta > results.count - 1 {
            onHistoryRow = true
            return
        }
        selectedID = results[max(0, min(results.count - 1, current + delta))].id
    }
}

/// ⌘K's last row for a typed query: "Search history for “x”". Lit like a
/// selected result when it is what Return does: always when nothing matches
/// (it is the only row), else when the cursor is on it.
private struct SearchHistoryRow: View {
    let query: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("Search history for “\(query)”")
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(selected ? Palette.selectionFill : hovering ? Palette.hoverFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// One palette result. Hover shows its own subtle fill without moving the
/// keyboard selection — the pointer resting on a row must never change what
/// Return opens mid-typing.
private struct PaletteResultRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let selected: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        // A row with no folder opens History instead of a tab: it says so,
        // dimmed, rather than looking like a session Return would resume.
        let openable = model.canOpenFromPalette(session)
        HStack(spacing: 10) {
            if let agent = session.agent { AgentBadge(agent: agent, size: 14) }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayTitle(session))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(session.project?.displayName ?? (openable ? "No project" : "No folder on record · opens in History"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .opacity(openable ? 1 : 0.55)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(TabColorMark.rowFill(
            TabColorMark.color(for: session.id, in: model),
            selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}
