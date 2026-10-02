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
/// `layoutPriority`; the selection bar is an overlay, the banner a plain row.
///
/// Keys (arrows, Return, Esc, ⌘A/⌘I/⌘R/⌘C/⌘F) are handled by RootView's
/// KeyCatcher while this tab is active, so they work whether the search field
/// or nothing at all has focus.
struct HistoryTabView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: HistoryModel
    @Environment(\.undoManager) private var undoManager

    /// The search field's text; it debounces into `history.query`.
    @State private var draft = ""
    @FocusState private var searchFocused: Bool
    @State private var width: CGFloat = 1000

    /// The page caps at this width and centres beyond it.
    static let pageWidth: CGFloat = 1100
    static let gutter: CGFloat = 28
    /// A row's own inset; the list column is this much wider than the header
    /// column so row text lines up with the title above it.
    static let rowInset: CGFloat = 12

    private var compact: Bool { width < 720 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            column(top, inset: Self.gutter)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            })
        .onAppear {
            draft = history.query
            history.activate()
            FieldFocus.claim { searchFocused = true }
        }
        .onDisappear { history.deactivate() }
        // Debounce: filtering is cheap, but a rebuild per keystroke resets
        // the selection under fast typing for nothing.
        .task(id: draft) {
            guard draft != history.query else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            history.query = draft
        }
        .onChange(of: history.query) { _, query in
            if draft != query { draft = query }
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

    /// One centred, capped column — the header's and the list's widths agree.
    private func column<V: View>(_ view: V, inset: CGFloat) -> some View {
        view
            .padding(.horizontal, inset)
            .frame(maxWidth: Self.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    // MARK: Header & toolbar

    private var top: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 36)
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
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History")
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            updatedLine
        }
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
                    Text("Updated \(Self.relative(last, now: context.date))")
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

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

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
            TextField("Search history", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !draft.isEmpty {
                Button {
                    draft = ""
                    history.query = ""
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
        Picker("", selection: $history.scope) {
            ForEach(HistoryScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 290)
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
        .frame(width: 130)
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
        .frame(width: 150)
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

    @ViewBuilder
    private var content: some View {
        if history.visibleRows.isEmpty {
            column(emptyState, inset: Self.gutter)
            Spacer(minLength: 0)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(history.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                HistoryPageRow(history: history, session: session)
                                    .id(session.id)
                            }
                        } header: {
                            HistoryHeader(title: group.title)
                                .padding(.horizontal, Self.rowInset - 14)
                                .frame(height: 30)
                                .background(Palette.panelBackground)
                        }
                    }
                }
                .padding(.bottom, 72)   // the bar never sits over the last row for good
                .padding(.horizontal, Self.gutter - Self.rowInset)
                .frame(maxWidth: Self.pageWidth)
                .frame(maxWidth: .infinity)
            }
            .thinScrollers()
            .onChange(of: history.scrollRequest) {
                if let id = history.cursorID { proxy.scrollTo(id) }
            }
            .overlay(alignment: .bottom) { bottomBar }
        }
    }

    // MARK: Selection bar

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if let notice = history.notice {
                noticeBar(notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if history.selection.count >= 2 {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
            .background(Palette.panelBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                action: ("Clear search", { history.query = "" }))
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

/// One line per session, 34pt: time · badge · title (· activity) · project
/// and branch · status. In Temple reads at full strength and ends in the gate
/// mark; outside steps back a tone and ends in a quiet Import. The status
/// column is a fixed width, so a row changing state never moves its
/// neighbours.
private struct HistoryPageRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: HistoryModel
    let session: AgentSession

    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    /// Mouse tracking fires by rect through a floating panel (⌘K etc.).
    private var hovering: Bool { rawHovering && !overlayActive }

    var body: some View {
        let inTemple = history.isInTemple(session.id)
        let selected = history.selection.contains(session.id)
        let openTab = model.openSessions.openTab(forSessionID: session.id)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(Self.timeFormatter.string(from: session.updatedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
                AgentBadge(agent: session.agent, size: 13)
                    .opacity(inTemple ? 1 : 0.55)
                HStack(spacing: 6) {
                    Text(model.displayTitle(session))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(inTemple ? Color.primary : Color.primary.opacity(0.82))
                    if let openTab {
                        ActivityDot(state: openTab.activity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                meta
            }
            .contentShape(Rectangle())
            .onTapGesture { history.click(session.id, modifier: Self.clickModifier()) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { history.open(session) })
            status(inTemple: inTemple, lit: selected || hovering)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, HistoryTabView.rowInset)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Palette.selectionFill : hovering ? Palette.hoverFill : Color.clear))
        .overlay(alignment: .leading) {
            if let mark = TabColorMark.color(for: session.id, in: model) {
                Capsule().fill(mark).frame(width: 3).padding(.vertical, 6)
            }
        }
        .onHover { rawHovering = $0 }
        .help(tooltip)
        .contextMenu { contextMenu(inTemple: inTemple, openTab: openTab) }
    }

    private var meta: some View {
        HStack(spacing: 0) {
            Text(HistoryModel.projectName(session.projectPath))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let branch = session.gitBranch, !branch.isEmpty {
                Text(" · \(branch)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 260, alignment: .trailing)
    }

    @ViewBuilder
    private func status(inTemple: Bool, lit: Bool) -> some View {
        if history.justImported.contains(session.id) {
            Text("Imported")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if history.isArchived(session) {
            Text("Archived")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        } else if inTemple {
            TempleMark(size: 12, tint: .secondary)
                .opacity(0.6)
                .help(membershipTooltip)
        } else {
            Button("Import") { history.requestImport([session]) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(lit ? Color.primary : Color.secondary.opacity(0.7))
        }
    }

    /// "In Temple · opened Sep 25" — how and when it joined, where known.
    private var membershipTooltip: String {
        guard let state = history.joinedState(session.id), let date = state.joinedAt else { return "In Temple" }
        let verb: String
        switch state.joinedVia {
        case .created: verb = "started"
        case .opened: verb = "opened"
        case .imported: verb = "imported"
        case nil: return "In Temple"
        }
        return "In Temple · \(verb) \(Self.dayFormatter.string(from: date))"
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
    private func contextMenu(inTemple: Bool, openTab: SessionTab?) -> some View {
        // Same words as the sidebar's menu where they overlap; no rename, pin,
        // color or archive — those belong to the rail. Keeping this short is
        // what keeps Import the obvious verb.
        Button(openTab != nil ? "Focus" : "Open") { history.open(session) }
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
        if inTemple, !history.isArchived(session) {
            Button("Show in sidebar") { model.showInSidebar(session.id) }
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
