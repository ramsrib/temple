import SwiftUI
import AppKit
import TempleCore

/// The History tab: every session Temple or the disk knows about, by day,
/// one status per row (ADR-031) — and the one door through which outside
/// sessions join (Import) and archived ones come back (Restore).
///
/// Built on `ScrollView` + `LazyVStack` with the selection held in
/// `HistoryModel`, not on `List`: `List` has never been used under
/// `MainContentView`, and a detail-pane view that makes SwiftUI rewrap the
/// split view silently breaks the sidebar's titlebar inset (AGENTS.md). For
/// the same reason nothing here uses `.fixedSize`, `.allowsHitTesting` or
/// `layoutPriority`; the selection bar floats in a `ZStack` over the list,
/// the banner is a plain row.
///
/// The page observes `HistoryModel` only, not the app model: every row is
/// prepared by the projection, so drawing one looks nothing up.
///
/// Keys (arrows, Return, Esc, ⌘A/⌘I/⌘R/⌘C/⌘F/⌘⌫) are handled by RootView's
/// KeyCatcher while this tab is active (HistoryKeys), so they work whether
/// the search field or nothing at all has focus — and stand aside when some
/// other field (sidebar search, a chip rename) has it.
struct HistoryTabView: View {
    @ObservedObject var history: HistoryModel
    @Environment(\.undoManager) private var undoManager

    @FocusState private var searchFocused: Bool
    /// The detail pane's width — what it offers, never what the page's own
    /// content would like — nil until measured (`PageWidthMemory`).
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

    /// How the toolbar lays out, by the pane's width: one row when it fits
    /// (1000 pt and up); else search on its own row with the scope and the
    /// filters under it; under 692 pt the two filter menus become one. The
    /// compact scope control is 344 pt, the narrowest at which "Not in
    /// Temple" is not cut, and 692 is where it, both menus, their spacing
    /// and the gutters still fit.
    enum Tier: Equatable { case narrow, compact, wide }

    static func tier(paneWidth: CGFloat) -> Tier {
        paneWidth < 692 ? .narrow : paneWidth < 1000 ? .compact : .wide
    }

    /// The project and branch column of a row, by the pane's width: hidden
    /// under 600 pt, a fixed width otherwise, so it truncates before the
    /// title does and never pushes the status column out.
    static func metaWidth(paneWidth: CGFloat) -> CGFloat? {
        paneWidth < 600 ? nil : paneWidth < 1000 ? 120 : 180
    }

    private var paneWidth: CGFloat { width ?? PageChrome.pageWidth }
    private var tier: Tier { Self.tier(paneWidth: paneWidth) }

    var body: some View {
        // The pane is measured from outside the page, by what it offers: a
        // reader in the page's own background reported the page's inflated
        // width once its content overflowed, the toolbar never compacted, and
        // the oversized page pushed the split view (and the sidebar) left.
        // Clipped, so nothing on the page can ever widen the pane.
        GeometryReader { pane in
            VStack(alignment: .leading, spacing: 0) {
                column(top, inset: Self.gutter)
                content
            }
            .frame(width: pane.size.width, height: pane.size.height, alignment: .top)
            .clipped()
            .onAppear { recordWidth(pane.size.width) }
            .onChange(of: pane.size.width) { _, new in recordWidth(new) }
        }
        // The split view's own detail grey is not windowBackgroundColor, which
        // the sticky day headers are painted in: in dark the headers showed as
        // a lighter band. Paint the page so the two agree by construction.
        .background(Palette.panelBackground)
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
            // By now the field's editor is the first responder: its delegate
            // is History's search control, which Restore's ⌘Z needs to tell
            // from every other field (HistoryModel.searchControl).
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            if focused, let control = (window?.firstResponder as? NSTextView)?.delegate as? NSControl {
                history.searchControl = control
            }
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
                Task { await history.confirmImport(request, undoManager: undoManager) }
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

    private func recordWidth(_ measured: CGFloat) {
        PageWidthMemory.last = measured
        if width != measured { width = measured }
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
            if history.isNarrowed || history.filteredProjectIsArchived {
                narrowedLine
                    .padding(.top, 8)
            }
            if case .reading(let read, let total) = history.readState {
                readingLine(read: read, total: total)
                    .padding(.top, 8)
            }
            ForEach(history.storeFailures, id: \.self) { failure in
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
        return history.countsLine
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
        switch tier {
        case .wide:
            HStack(spacing: 10) {
                searchField(minWidth: 220)
                scopePicker(width: 390)
                agentMenu(width: 130)
                projectMenu(width: 150)
            }
        case .compact, .narrow:
            VStack(alignment: .leading, spacing: 8) {
                searchField(minWidth: 160)
                HStack(spacing: 8) {
                    scopePicker(width: 344)
                    Spacer(minLength: 8)
                    if tier == .narrow {
                        filterMenu
                    } else {
                        agentMenu(width: 120)
                        projectMenu(width: 140)
                    }
                }
            }
        }
    }

    private func searchField(minWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // Debounced into `history.query` by the model: a projection per
            // keystroke resets the selection under fast typing for nothing.
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
        .frame(minWidth: minWidth, maxWidth: .infinity)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Picking any segment clears the "Archived just now" chip.
    private func scopePicker(width: CGFloat) -> some View {
        FlatSegmentedPicker(label: "Show",
                            selection: Binding(get: { history.scope }, set: { history.pickScope($0) }),
                            options: Array(HistoryScope.allCases),
                            optionTitle: { $0.label }, width: width)
    }

    /// Counts are over every row, not the filtered view.
    private var agentPicker: some View {
        Picker("", selection: $history.agentFilter) {
            Text("Any agent").tag(Agent?.none)
            ForEach(Agent.allCases, id: \.self) { agent in
                Text("\(agent.displayName) (\((history.agentCounts[agent] ?? 0).formatted()))")
                    .tag(Agent?.some(agent))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var projectPicker: some View {
        Picker("", selection: $history.projectKeyFilter) {
            Text("Any project").tag(ProjectKey?.none)
            ForEach(history.projects, id: \.key) { project in
                Text("\(project.displayName) — \(project.parentFolder)")
                    .tag(ProjectKey?.some(project.key))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private func agentMenu(width: CGFloat) -> some View {
        Menu { agentPicker } label: {
            Text(history.agentFilter?.displayName ?? "Any agent")
        }
        .menuIndicator(.visible)
        .modifier(FlatToolbarMenu(width: width))
    }

    private func projectMenu(width: CGFloat) -> some View {
        Menu { projectPicker } label: {
            Text(history.projectKeyFilter.map(\.displayName) ?? "Any project")
        }
        .menuIndicator(.visible)
        .modifier(FlatToolbarMenu(width: width))
    }

    /// Under 692 pt: the agent and project menus as one, labelled with what
    /// is filtered ("Claude Code · raven") or "Filter".
    private var filterMenu: some View {
        Menu {
            Section("Agent") { agentPicker }
            Section("Project") { projectPicker }
        } label: {
            Text(Self.filterLabel(agent: history.agentFilter, project: history.projectKeyFilter))
                .lineLimit(1)
        }
        .menuIndicator(.visible)
        .modifier(FlatToolbarMenu(width: 110))
    }

    static func filterLabel(agent: Agent?, project: ProjectKey?) -> String {
        let names = [agent?.displayName, project?.displayName].compactMap { $0 }
        return names.isEmpty ? "Filter" : names.joined(separator: " · ")
    }

    /// "Showing 173 of 3,812", then the chip and the archived project's
    /// Restore, each where one applies.
    private var narrowedLine: some View {
        HStack(spacing: 6) {
            if history.isNarrowed {
                Text("Showing \(history.visibleRows.count.formatted()) of \(history.allRows.count.formatted())")
            }
            if let chip = history.justArchivedChip {
                separator
                HStack(spacing: 4) {
                    Text("Archived just now · \(chip.count.formatted())")
                    Button {
                        history.clearChip()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Palette.controlFill, in: Capsule())
                .help("The sessions Temple archived during this run. Clear it to see everything archived.")
            }
            if let project = history.projectKeyFilter, history.filteredProjectIsArchived {
                separator
                Text("\(project.displayName) is archived")
                separator
                Button("Restore project") { history.restoreProject(project, undoManager: undoManager) }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .help("Puts \(project.displayName) back in the sidebar with every session you have not archived yourself.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
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
        let failed = Set(history.storeFailures.filter { $0.host == failure.host }.map(\.agent))
        let others = Agent.allCases.filter { !failed.contains($0) }
        let byAgent = history.snapshot.counts.hostAgents[failure.host] ?? [:]
        let shown = others.reduce(0) { $0 + (byAgent[$1] ?? 0) }
        let names = others.map(\.displayName).joined(separator: " and ")
        let place = failure.host.isLocal ? "" : " on \(failure.host.displayName)"
        var text = "Couldn't read the \(failure.agent.displayName) session store\(place): \(failure.message)"
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
        let actions = HistoryRowActions(history: history)
        let metaWidth = Self.metaWidth(paneWidth: paneWidth)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(history.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                HistoryPageRow(inputs: history.rowInputs(session), metaWidth: metaWidth, actions: actions)
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

    /// The row's scroll target one header above it; distinct from the row's own id.
    struct Headroom: Hashable { let key: HistoryKey }
    static func headroomID(_ key: HistoryKey) -> Headroom { Headroom(key: key) }

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

    /// Counted once per selection change (`selectionSummary`), never by
    /// walking the rows here.
    private var selectionBar: some View {
        let summary = history.selectionSummary
        // A conflicting row's session is in Temple too, elsewhere.
        let inTemple = summary.count - summary.importable
        return barChrome {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Text("\(summary.count.formatted()) selected")
                        .font(.system(size: 12, weight: .semibold))
                    if summary.allArchived {
                        Text(" · all archived").foregroundStyle(.secondary)
                    } else if summary.archived > 0 {
                        Text(" · \(summary.archived.formatted()) archived").foregroundStyle(.secondary)
                    } else if summary.importable == 0 {
                        Text(" · all in Temple").foregroundStyle(.secondary)
                    } else if inTemple > 0 {
                        Text(" · \(inTemple.formatted()) already in Temple").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                HStack(spacing: 10) {
                    if summary.allArchived { keyHint("↩", "restore \(summary.count.formatted())") }
                    if summary.archivable { keyHint("⌘⌫", "archive") }
                    if summary.importable > 0 { keyHint("⌘I", "import") }
                    keyHint("esc", "deselect")
                }
                Spacer(minLength: 8)
                Button("Deselect") { history.clearSelection() }
                    .controlSize(.regular)
                if summary.archived > 0 {
                    Button("Restore \(summary.archived.formatted())") { history.restoreSelected(undoManager: undoManager) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                if summary.archivable {
                    Button("Archive \(summary.count.formatted())") { history.archiveSelected(undoManager: undoManager) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                if summary.importable > 0 {
                    Button("Import \(summary.importable.formatted())…") { history.requestImport() }
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
        let otherFilters = history.agentFilter != nil || history.projectKeyFilter != nil
        if history.scope == .archived {
            if history.justArchivedChip != nil {
                return EmptyCopy(title: "None of the sessions archived just now are still archived",
                                 action: ("Show all archived", { history.clearChip() }))
            }
            if !otherFilters {
                return EmptyCopy(
                    title: "Nothing archived",
                    detail: "Archive a session from its sidebar menu, or select rows here and choose Archive. Temple also archives sessions whose transcript or folder is gone.")
            }
            return EmptyCopy(
                title: "No archived sessions in \(activeFilterNames.filter { $0 != HistoryScope.archived.label }.joined(separator: " · "))",
                action: ("Show all archived", {
                    history.agentFilter = nil
                    history.projectKeyFilter = nil
                }))
        }
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
                history.projectKeyFilter = nil
            }))
    }

    /// The knobs that are turned, in the words the controls use.
    private var activeFilterNames: [String] {
        var names: [String] = []
        if history.scope != .all { names.append(history.scope.label) }
        if let agent = history.agentFilter { names.append(agent.displayName) }
        if let project = history.projectKeyFilter { names.append(project.displayName) }
        return names
    }
}

/// What a row does. Held, never observed, and left out of the row's
/// equality: the row re-renders for what it shows, not for who it calls.
private struct HistoryRowActions {
    let history: HistoryModel
}

/// One line per session, 34pt: time · badge · title [· condition tag]
/// [· activity] · project and branch · status. In Temple reads at full
/// strength and ends in the gate mark; archived and outside rows step back a
/// tone and end in a quiet Restore or Import. The status column is a fixed
/// width, so a row changing state never moves its neighbours.
///
/// Every input is a prepared value (`HistoryModel.RowInputs`) and the view
/// is `Equatable` (applied with `.equatable()`), so a body re-run of the page
/// skips the rows whose inputs did not change. Nothing here observes the
/// history or app model, formats a date, or looks anything up.
private struct HistoryPageRow: View, Equatable {
    @Environment(\.undoManager) private var undoManager
    let inputs: HistoryModel.RowInputs
    /// The project and branch column's width; nil hides it (a narrow pane).
    let metaWidth: CGFloat?
    let actions: HistoryRowActions

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.inputs == rhs.inputs && lhs.metaWidth == rhs.metaWidth }

    private var session: HistoryRow { inputs.row }
    private var history: HistoryModel { actions.history }
    private var inTemple: Bool { session.standing == .inTemple }

    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    /// Mouse tracking fires by rect through a floating panel (⌘K etc.).
    private var hovering: Bool { rawHovering && !overlayActive }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(session.timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
                if let agent = session.agent {
                    AgentBadge(agent: agent, size: 13).opacity(inTemple ? 1 : 0.55)
                }
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // A member whose transcript is gone steps back like an
                        // outside row: the state reads before the tag does.
                        .foregroundStyle(inTemple && !session.transcriptMissing
                                         ? Color.primary : Color.primary.opacity(0.72))
                    if let tag = session.conditionTag {
                        Text(tag.label)
                            .font(.system(size: 11))
                            // Secondary, a step down: tertiary was too faint in dark.
                            .foregroundStyle(Color.secondary.opacity(0.8))
                            .lineLimit(1)
                            .help(session.tagTooltip ?? "")
                    }
                    if let activity = inputs.activity {
                        ActivityDot(state: activity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let metaWidth {
                    meta.frame(width: metaWidth, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { history.click(session.id, modifier: Self.clickModifier()) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { history.primaryAction(session, undoManager: undoManager) })
            status(lit: inputs.selected || hovering)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, HistoryTabView.rowInset)
        .frame(height: HistoryTabView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(inputs.selected ? Palette.selectionFill : hovering ? Palette.hoverFill : Color.clear))
        .overlay(alignment: .leading) {
            if let mark = session.colorMark {
                Capsule().fill(mark.color).frame(width: 3).padding(.vertical, 6)
            }
        }
        .onHover { rawHovering = $0 }
        .help(session.rowTooltip)
        .contextMenu { contextMenu }
    }

    private var meta: some View {
        HStack(spacing: 0) {
            Text(session.projectName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let branch = session.gitBranch, !branch.isEmpty {
                Text(" · \(branch)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        // A fixed width (`metaWidth`), not frame(maxWidth:) and not a layout
        // priority: maxWidth is greedy (the row's HStack handed this column
        // half the leftover width and titles cut off beside empty space), and
        // layout priorities are on AGENTS.md's list of detail-pane modifiers
        // that have broken the sidebar's titlebar inset.
    }

    /// The row's relationship, or its primary verb; never a condition (that
    /// is the tag after the title).
    @ViewBuilder
    private func status(lit: Bool) -> some View {
        switch session.standing {
        case _ where inputs.justImported:
            Text("Imported")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .archived:
            Button("Restore") { history.restore([session], undoManager: undoManager) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(lit ? Color.primary : Color.secondary.opacity(0.7))
                .help(session.statusTooltip ?? "")
        case .inTemple:
            TempleMark(size: 14, tint: lit ? .primary : .secondary)
                .help(session.membershipTooltip)
        case .conflict(let conflict):
            // Its id is Temple's on another host or as another agent: shown
            // as the catalog has it, and not importable from here. The mark,
            // faint, says "in Temple, just not from here" — a dimmed "Import"
            // read as a disabled button worth trying again.
            TempleMark(size: 14, tint: Color(nsColor: .quaternaryLabelColor))
                .help(conflict.message)
        case .outside:
            Button("Import") { history.requestImport([session]) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(lit ? Color.primary : Color.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if session.isArchived {
            Button("Open") { history.open(session) }
                .disabled(!session.canResume)
            Button("Restore") { history.restore([session], undoManager: undoManager) }
            if session.projectArchived, let project = session.project {
                Button("Restore project \(project.displayName)") {
                    history.restoreProject(project, undoManager: undoManager)
                }
            }
        } else {
            // Members without a directory have no rail row, so History also
            // owns an archive route. Open tabs must be closed first, as in the rail.
            Button(inputs.activity != nil ? "Focus" : "Open") { history.open(session) }
                .disabled(!session.canResume)
            if session.canArchive {
                Button("Archive session") { history.archive(session, undoManager: undoManager) }
            }
            if let conflict = session.conflict {
                Button("Import into Temple…") {}.disabled(true)
                Text(conflict.message)
            } else if !session.isMember {
                Button("Import into Temple…") { history.requestImport([session]) }
            }
        }
        Divider()
        // A row that cannot resume (no folder or agent) has no command.
        if session.hasResumeCommand {
            Button("Copy resume command") {
                copyToPasteboard(session.resumeArgv.joined(separator: " "))
            }
        }
        Button("Copy session ID") { copyToPasteboard(session.sessionID) }
        if let url = session.localURL {
            Button("Reveal session file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        // The sidebar groups rows by folder: a row without one is not there.
        if inTemple, session.project != nil {
            Button("Show in sidebar") { history.showInSidebar(session.sessionID) }
        }
        if let project = session.project {
            Button("Show only \(project.displayName)") { history.showOnly(project: project) }
        }
    }

    private static func clickModifier() -> HistoryModel.ClickModifier {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }
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
