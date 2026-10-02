import SwiftUI
import AppKit
import TempleCore

/// The History tab: every session on disk, by day, each marked in Temple or
/// not — and the one door through which the others join (Import).
///
/// Built on `ScrollView` + `LazyVStack` with the selection held in
/// `HistoryModel`, not on `List`: `List` has never been used under
/// `MainContentView`, and a detail-pane view that makes SwiftUI rewrap the
/// split view silently breaks the sidebar's titlebar inset (AGENTS.md). For
/// the same reason nothing here uses `.fixedSize`, `.allowsHitTesting` or
/// `layoutPriority`; the selection bar floats in a `ZStack` over the list,
/// the banner is a plain row.
///
/// Keys (arrows, Return, Esc, ⌘A/⌘I/⌘R/⌘C/⌘F) are handled by RootView's
/// KeyCatcher while this tab is active (HistoryKeys), so they work whether
/// the search field or nothing at all has focus — and stand aside when some
/// other field (sidebar search, a chip rename) has it.
struct HistoryTabView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: HistoryModel
    @Environment(\.undoManager) private var undoManager

    @FocusState private var searchFocused: Bool
    /// The page's width; nil until measured (`PageWidthMemory`).
    @State private var width: CGFloat? = PageWidthMemory.last

    /// The page caps at this width and centres beyond it.
    static let pageWidth = PageChrome.pageWidth
    static let gutter = PageChrome.gutter
    /// A row's own inset; the list column is this much wider than the header
    /// column so row text lines up with the title above it.
    static let rowInset: CGFloat = 12
    static let rowHeight: CGFloat = 34
    /// The sticky day header. A row the keyboard moves to is scrolled clear
    /// of it, not merely onto the screen underneath it.
    static let dayHeaderHeight: CGFloat = 30

    private var compact: Bool { (width ?? PageChrome.pageWidth) < 720 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            column(top, inset: Self.gutter)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The split view's own detail grey is not windowBackgroundColor, which
        // the sticky day headers are painted in: in dark the headers showed as
        // a lighter band. Paint the page so the two agree by construction.
        .background(Palette.panelBackground)
        .measuringPageWidth($width)
        .onAppear {
            history.activate()
            FieldFocus.claim { searchFocused = true }
        }
        .onDisappear {
            history.searchFieldFocused = false
            history.deactivate()
        }
        // The key router tells this field from any other by this flag.
        .onChange(of: searchFocused) { _, focused in
            history.searchFieldFocused = focused
        }
        .onChange(of: history.focusSearchRequest) {
            FieldFocus.claim { searchFocused = true }
        }
        .alert(history.pendingImport?.title ?? "",
               isPresented: Binding(get: { history.pendingImport != nil },
                                    set: { if !$0 { history.cancelImport() } }),
               presenting: history.pendingImport) { request in
            Button("Cancel", role: .cancel) { history.cancelImport() }
            Button(request.confirmLabel) {
                history.confirmImport(request, undoManager: undoManager)
            }
            .keyboardShortcut(.defaultAction)
        } message: { request in
            Text(request.message)
        }
        .alert(history.importFailure?.title ?? "",
               isPresented: Binding(get: { history.importFailure != nil },
                                    set: { if !$0 { history.importFailure = nil } }),
               presenting: history.importFailure) { _ in
            Button("OK") { history.importFailure = nil }
                .keyboardShortcut(.defaultAction)
        } message: { failure in
            Text(failure.message)
        }
    }

    /// One centred, capped column — the header's and the list's widths agree,
    /// and so does Settings' (PageChrome's `pageColumn`).
    private func column<V: View>(_ view: V, inset: CGFloat) -> some View {
        view.pageColumn(pageWidth: width, inset: inset)
    }

    // MARK: Header & toolbar

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, PageChrome.top)
                .padding(.bottom, 18)
            toolbar
            if history.isNarrowed {
                Text("Showing \(history.visibleRows.count.formatted()) of \(history.allRows.count.formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if case .reading(let read, let total) = history.readState {
                readingLine(read: read, total: total)
                    .padding(.top, 8)
            }
            ForEach(history.storeFailures, id: \.agent) { failure in
                failureBanner(failure)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 10)
    }

    private var header: some View {
        PageHeader(title: "History", subtitle: Text(subtitle)) { updatedLine }
    }

    /// What is in the box, not what is showing.
    private var subtitle: String {
        if history.allRows.isEmpty, history.lastUpdated == nil { return "Every session on disk" }
        return "\(history.allRows.count.formatted()) sessions on disk · \(history.inTempleCount.formatted()) in Temple"
    }

    /// The page is a snapshot, and says so: when it was taken, and the way to
    /// take another.
    private var updatedLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                if let last = history.lastUpdated {
                    Text("Updated \(PageChrome.relative(last, now: context.date))")
                    Text("·")
                }
                Button("Refresh") { history.refresh() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("⌘R").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                searchField
                HStack(spacing: 8) {
                    scopePicker
                    Spacer(minLength: 8)
                    agentMenu
                    projectMenu
                }
            }
        } else {
            HStack(spacing: 10) {
                searchField
                scopePicker
                agentMenu
                projectMenu
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // Debounced into `history.query` by the model: filtering is
            // cheap, but a rebuild per keystroke resets the selection under
            // fast typing for nothing.
            TextField("Search history", text: $history.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !history.draft.isEmpty {
                Button {
                    history.clearSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var scopePicker: some View {
        FlatSegmentedPicker(label: "Show", selection: $history.scope, options: Array(HistoryScope.allCases),
                            optionTitle: { $0.label }, width: 290)
    }

    /// Counts are over the whole disk, not the filtered view.
    private var agentMenu: some View {
        Menu {
            Picker("", selection: $history.agentFilter) {
                Text("Any agent").tag(Agent?.none)
                ForEach(Agent.allCases, id: \.self) { agent in
                    Text("\(agent.displayName) (\((history.agentCounts[agent] ?? 0).formatted()))")
                        .tag(Agent?.some(agent))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(history.agentFilter?.displayName ?? "Any agent")
        }
        .menuIndicator(.visible)
        .modifier(FlatToolbarMenu(width: 130))
    }

    private var projectMenu: some View {
        Menu {
            Picker("", selection: $history.projectFilter) {
                Text("Any project").tag(String?.none)
                ForEach(history.projects, id: \.path) { project in
                    Text("\(HistoryModel.projectName(project.path)) — \(Self.parentFolder(project.path))")
                        .tag(String?.some(project.path))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(history.projectFilter.map(HistoryModel.projectName) ?? "Any project")
        }
        .menuIndicator(.visible)
        .modifier(FlatToolbarMenu(width: 150))
    }

    /// The folder a project sits in, home abbreviated: "~/Projects/active".
    static func parentFolder(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    private func readingLine(read: Int, total: Int?) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(total.map { "Reading sessions on disk… \(read.formatted()) of \($0.formatted())" }
                 ?? "Reading sessions on disk…")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// Surfaces the store's error as thrown; never diagnoses it (AGENTS.md).
    private func failureBanner(_ failure: HistoryModel.StoreFailure) -> some View {
        let failed = Set(history.storeFailures.map(\.agent))
        let others = Agent.allCases.filter { !failed.contains($0) }
        let shown = others.reduce(0) { $0 + (history.agentCounts[$1] ?? 0) }
        let names = others.map(\.displayName).joined(separator: " and ")
        var text = "Couldn't read the \(failure.agent.displayName) session store: \(failure.message)"
        if !others.isEmpty { text += " Showing \(shown.formatted()) \(names) sessions." }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
    }

    // MARK: List

    /// The bar floats over whichever is showing, list or empty state: an
    /// import can empty the view it was made from ("Not in Temple", all of it
    /// imported), and its Undo must not go with the rows.
    private var content: some View {
        ZStack(alignment: .bottom) {
            if history.visibleRows.isEmpty {
                column(emptyState, inset: Self.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                list
            }
            bottomBar
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(history.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                row(session)
                                    .equatable()
                                    // A target reaching one header above the
                                    // row: scrolling it into view clears the
                                    // sticky header as well (see scrollRequest).
                                    .background(alignment: .bottom) {
                                        Color.clear
                                            .frame(height: Self.rowHeight + Self.dayHeaderHeight)
                                            .id(Self.headroomID(session.id))
                                    }
                                    .id(session.id)
                            }
                        } header: {
                            HistoryHeader(title: group.title)
                                .padding(.horizontal, Self.rowInset - 14)
                                .frame(height: Self.dayHeaderHeight)
                                .background(Palette.panelBackground)
                        }
                    }
                }
                .padding(.bottom, 72)   // the bar never sits over the last row for good
                .pageColumn(pageWidth: width, inset: Self.gutter - Self.rowInset)
            }
            .thinScrollers()
            .onChange(of: history.scrollRequest) {
                guard let id = history.cursorID else { return }
                // The row itself first: it may be far off and not yet laid
                // out (⌘↑, ⌥↓). Then its headroom target, a turn later once
                // the row exists: moving up, the minimal scroll that shows the
                // row leaves it under the sticky day header; showing the
                // header's height above it as well puts it just below.
                proxy.scrollTo(id)
                DispatchQueue.main.async { proxy.scrollTo(Self.headroomID(id)) }
            }
        }
    }

    static func headroomID(_ id: String) -> String { "headroom:" + id }

    /// A row's inputs as plain values, so a row re-renders only when what it
    /// shows changed — not on every arrow press, streamed batch, notice tick
    /// or live-index publish that re-runs this body.
    private func row(_ session: AgentSession) -> HistoryPageRow {
        let inTemple = history.isInTemple(session.id)
        let archived = history.isArchived(session)
        let openTab = model.openSessions.openTab(forSessionID: session.id)
        return HistoryPageRow(
            session: session,
            title: model.displayTitle(session),
            selected: history.selection.contains(session.id),
            inTemple: inTemple,
            archived: archived,
            justImported: history.justImported.contains(session.id),
            activity: openTab?.activity,
            colorMark: TabColorMark.color(for: session.id, in: model),
            membershipTooltip: Self.membershipTooltip(history.joinedState(session.id)),
            actions: HistoryRowActions(history: history, showInSidebar: { [weak model] id in
                model?.showInSidebar(id)
            }))
    }

    /// "In Temple · opened Sep 25" — how and when it joined, where known.
    static func membershipTooltip(_ state: SessionState?) -> String {
        guard let state, let date = state.joinedAt else { return "In Temple" }
        let verb: String
        switch state.joinedVia {
        case .created: verb = "started"
        case .opened: verb = "opened"
        case .imported: verb = "imported"
        case nil: return "In Temple"
        }
        return "In Temple · \(verb) \(dayFormatter.string(from: date))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    // MARK: Selection bar

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            switch history.bottomBar {
            case .notice(let notice)?:
                noticeBar(notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .selection?:
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, Self.gutter - Self.rowInset)
        .frame(maxWidth: Self.pageWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.18), value: history.selection.count >= 2)
        .animation(.easeOut(duration: 0.18), value: history.notice)
    }

    private var selectionBar: some View {
        let selected = history.selectedRows
        let outside = selected.filter { !history.isInTemple($0.id) }.count
        let inTemple = selected.count - outside
        return barChrome {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("\(selected.count.formatted()) selected")
                        .font(.system(size: 12, weight: .semibold))
                    if outside == 0 {
                        Text(" · all in Temple").foregroundStyle(.secondary)
                    } else if inTemple > 0 {
                        Text(" · \(inTemple.formatted()) already in Temple").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                HStack(spacing: 10) {
                    if outside > 0 { keyHint("⌘I", "import") }
                    keyHint("esc", "deselect")
                }
                Spacer(minLength: 8)
                Button("Deselect") { history.clearSelection() }
                    .controlSize(.regular)
                if outside > 0 {
                    Button("Import \(outside.formatted())…") { history.requestImport() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
        }
    }

    private func noticeBar(_ notice: HistoryModel.Notice) -> some View {
        barChrome {
            HStack(spacing: 10) {
                Text(notice.text)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if notice.offersUndo {
                    Button {
                        undoManager?.undo()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Undo").fontWeight(.semibold)
                            Text("⌘Z").foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func barChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(height: 44)
            // On a page painted panelBackground the bar was page-on-page in
            // dark, carried only by a shadow that 50-grey swallows: give it a
            // surface of its own, under the content.
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panelBackground)
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceFill)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 6) {
            if let empty = emptyCopy {
                Text(empty.title)
                    .font(.system(size: 13, weight: .medium))
                if let detail = empty.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let action = empty.action {
                    Button(action.label, action: action.perform)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private struct EmptyCopy {
        let title: String
        var detail: String?
        var action: (label: String, perform: () -> Void)?
    }

    private var emptyCopy: EmptyCopy? {
        // Rows stream in under the reading line; a first read with nothing yet
        // is not "no sessions".
        if history.allRows.isEmpty, history.isReading || history.lastUpdated == nil { return nil }
        let query = history.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let filters = activeFilterNames
            return EmptyCopy(
                title: "No sessions match “\(query)”" + (filters.isEmpty ? "" : " in \(filters.joined(separator: " · "))"),
                action: ("Clear search", { history.clearSearch() }))
        }
        if history.allRows.isEmpty {
            return EmptyCopy(
                title: "No sessions yet",
                detail: "Sessions you run with Claude Code or Codex — here or in any terminal — appear here.")
        }
        let otherFilters = history.agentFilter != nil || history.projectFilter != nil
        if !otherFilters, history.scope == .notInTemple {
            return EmptyCopy(
                title: "Everything on disk is in Temple.",
                detail: "Sessions from other terminals appear here the next time this page refreshes.")
        }
        if !otherFilters, history.scope == .inTemple {
            return EmptyCopy(
                title: "Nothing in Temple yet",
                detail: "Open or import a session and it will be listed here.")
        }
        return EmptyCopy(
            title: "No sessions in \(activeFilterNames.joined(separator: " · "))",
            action: ("Show all", {
                history.scope = .all
                history.agentFilter = nil
                history.projectFilter = nil
            }))
    }

    /// The knobs that are turned, in the words the controls use.
    private var activeFilterNames: [String] {
        var names: [String] = []
        if history.scope != .all { names.append(history.scope.label) }
        if let agent = history.agentFilter { names.append(agent.displayName) }
        if let project = history.projectFilter { names.append(HistoryModel.projectName(project)) }
        return names
    }
}

/// What a row does. Held, never observed, and left out of the row's
/// equality: the row re-renders for what it shows, not for who it calls.
private struct HistoryRowActions {
    let history: HistoryModel
    let showInSidebar: (String) -> Void
}

/// One line per session, 34pt: time · badge · title (· activity) · project
/// and branch · status. In Temple reads at full strength and ends in the gate
/// mark; outside steps back a tone and ends in a quiet Import. The status
/// column is a fixed width, so a row changing state never moves its
/// neighbours.
///
/// Every input is a value and the view is `Equatable` (applied with
/// `.equatable()`), so a body re-run of the page skips the rows whose inputs
/// did not change. Nothing here observes the history or app model.
private struct HistoryPageRow: View, Equatable {
    let session: AgentSession
    let title: String
    let selected: Bool
    let inTemple: Bool
    let archived: Bool
    let justImported: Bool
    /// The open tab's activity; nil when the session has no tab.
    let activity: ActivityState?
    let colorMark: Color?
    let membershipTooltip: String
    let actions: HistoryRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session && lhs.title == rhs.title
            && lhs.selected == rhs.selected && lhs.inTemple == rhs.inTemple
            && lhs.archived == rhs.archived && lhs.justImported == rhs.justImported
            && lhs.activity == rhs.activity && lhs.colorMark == rhs.colorMark
            && lhs.membershipTooltip == rhs.membershipTooltip
    }

    private var history: HistoryModel { actions.history }

    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    /// Mouse tracking fires by rect through a floating panel (⌘K etc.).
    private var hovering: Bool { rawHovering && !overlayActive }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(Self.timeFormatter.string(from: session.updatedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
                AgentBadge(agent: session.agent, size: 13)
                    .opacity(inTemple ? 1 : 0.55)
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(inTemple ? Color.primary : Color.primary.opacity(0.72))
                    if let activity {
                        ActivityDot(state: activity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                meta
            }
            .contentShape(Rectangle())
            .onTapGesture { history.click(session.id, modifier: Self.clickModifier()) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { history.open(session) })
            status(lit: selected || hovering)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, HistoryTabView.rowInset)
        .frame(height: HistoryTabView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Palette.selectionFill : hovering ? Palette.hoverFill : Color.clear))
        .overlay(alignment: .leading) {
            if let colorMark {
                Capsule().fill(colorMark).frame(width: 3).padding(.vertical, 6)
            }
        }
        .onHover { rawHovering = $0 }
        .help(tooltip)
        .contextMenu { contextMenu }
    }

    private var meta: some View {
        HStack(spacing: 0) {
            Text(HistoryModel.projectName(session.projectPath))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let branch = session.gitBranch, !branch.isEmpty {
                Text(" · \(branch)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        // No frame(maxWidth:) here: it is greedy, so the row's HStack handed
        // this column half the leftover width and titles cut off at ~30
        // characters beside empty space. A Text's max is its ideal width.
    }

    @ViewBuilder
    private func status(lit: Bool) -> some View {
        if justImported {
            Text("Imported")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if archived {
            Text("Archived")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if inTemple {
            TempleMark(size: 14, tint: lit ? .primary : .secondary)
                .help(membershipTooltip)
        } else {
            Button("Import") { history.requestImport([session]) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(lit ? Color.primary : Color.secondary.opacity(0.7))
        }
    }

    /// The last message (the overlay's old second line), then the details
    /// that are not reliable enough to sit in a column.
    private var tooltip: String {
        var details: [String] = []
        if let model = session.model { details.append(model) }
        if let count = session.messageCount { details.append("\(count) messages") }
        details.append((session.filePath.path as NSString).abbreviatingWithTildeInPath)
        return [session.lastMessagePreview, details.joined(separator: " · ")]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var contextMenu: some View {
        // Same words as the sidebar's menu where they overlap; no rename, pin,
        // color or archive — those belong to the rail. Keeping this short is
        // what keeps Import the obvious verb.
        Button(activity != nil ? "Focus" : "Open") { history.open(session) }
        if !inTemple {
            Button("Import into Temple…") { history.requestImport([session]) }
        }
        Divider()
        Button("Copy resume command") {
            copyToPasteboard(session.resume.argv.joined(separator: " "))
        }
        Button("Copy session ID") { copyToPasteboard(session.id) }
        Button("Reveal session file in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.filePath])
        }
        Divider()
        if inTemple, !archived {
            Button("Show in sidebar") { actions.showInSidebar(session.id) }
        }
        Button("Show only \(HistoryModel.projectName(session.projectPath))") {
            history.showOnly(project: session.projectPath)
        }
    }

    private static func clickModifier() -> HistoryModel.ClickModifier {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The toolbar's pop-up menus in the same flat shape as its search field.
private struct FlatToolbarMenu: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(width: width, height: 28)
            .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
