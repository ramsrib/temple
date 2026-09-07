import SwiftUI
import TempleCore

/// ⌘⇧Y: what has been put away. A browser, not a palette: the ⌘K/⌘Y panels are
/// a search field with results hanging off it, which reads as "type to find
/// one thing". Putting things back is browsing — you scan, you pick several —
/// so this is a centred window with a title, the counts, a compact search, a
/// tall list and the keys spelled out. Same chrome as the other panels; the
/// sidebar deliberately carries no archive affordance, and this is the way back.
struct ArchiveView: View {
    @EnvironmentObject var model: AppModel
    /// Ceiling for the list, from the window: the panel must never outgrow it.
    var maxListHeight: CGFloat = 520
    @State private var query = ""
    @State private var entries: [ArchiveEntry] = []
    @State private var indexByID: [String: Int] = [:]
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    /// One keyboard-selectable line. Projects and sessions share a single walk
    /// (↑↓ crosses the section rule) so Return always acts on what is lit.
    enum ArchiveEntry: Identifiable {
        case project(Project)
        case session(AgentSession)

        var id: String {
            switch self {
            case .project(let project): return "project:\(project.path)"
            case .session(let session): return "session:\(session.id)"
            }
        }
    }

    private var projects: [ArchiveEntry] {
        entries.filter { if case .project = $0 { return true } else { return false } }
    }

    private var sessions: [ArchiveEntry] {
        entries.filter { if case .session = $0 { return true } else { return false } }
    }

    private var headerCount: Int {
        (projects.isEmpty ? 0 : 1) + (sessions.isEmpty ? 0 : 1)
    }

    private static let panelWidth: CGFloat = 760
    private static let listMinHeight: CGFloat = 260

    /// Content-sized between a floor and the window's ceiling: one row must not
    /// leave a cavern, fifty must not run off the screen.
    private var listHeight: CGFloat {
        let content = CGFloat(entries.count) * Self.rowHeight
            + CGFloat(headerCount) * Self.headerHeight + 8
        return min(max(content, Self.listMinHeight), max(Self.listMinHeight, maxListHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: Self.panelWidth)
        .panelChrome()
        .onAppear {
            reload()
            FieldFocus.claim { fieldFocused = true }
        }
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onChange(of: query) { _, _ in reload() }
        // Same reason as HistoryView: the results are @State, so an index
        // update — or an unarchive from this very panel — needs an explicit
        // refresh. Selection sticks to its row's id across the reload.
        .onChange(of: model.index) { _, _ in reloadPreservingSelection() }
        .onReceive(model.overlay.objectWillChange
            .receive(on: DispatchQueue.main)) { _ in reloadPreservingSelection() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.archivePresented = false; return .handled }
    }

    // MARK: Header — title, what is in here, and the search off to the side

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Archive")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            searchField
                .frame(width: 260)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// The whole archive, not the filtered view — the header says what is in
    /// the box, the list says what matches.
    private var summary: String {
        let projects = model.archivedProjects.count
        let sessions = model.archivedSessionResults("").count
        if projects == 0 && sessions == 0 { return "Nothing put away" }
        var parts: [String] = []
        if projects > 0 { parts.append(projects == 1 ? "1 project" : "\(projects) projects") }
        if sessions > 0 { parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions") }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search archived…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(actOnSelection)
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager, like the history and palette lists: a lazy stack can
                // leave a materialized row's selection fill stale while the
                // keyboard highlight moves.
                VStack(spacing: 0) {
                    section("Projects", projects)
                    section("Sessions", sessions)
                }
                .padding(.vertical, 4)
            }
            .frame(height: listHeight)
            .thinScrollers()
            .onChange(of: selection) {
                if entries.indices.contains(selection) {
                    proxy.scrollTo(entries[selection].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Nothing archived" : "No matches")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Archive a session from its row menu, or a project from its header menu, and it waits here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .frame(height: Self.listMinHeight)
    }

    // MARK: Footer — the keys, and what Return does to the lit row

    private var footer: some View {
        HStack(spacing: 18) {
            hint("↑↓", "select")
            hint("↩", returnHint)
            hint("esc", "close")
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    /// Return means two different things here; the footer names the one that
    /// applies to the row under the highlight.
    private var returnHint: String {
        guard entries.indices.contains(selection) else { return "open" }
        switch entries[selection] {
        case .project: return "restore project"
        case .session: return "restore and open session"
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.hairline))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ArchiveEntry]) -> some View {
        if !rows.isEmpty {
            HistoryHeader(title: title)
                .frame(height: Self.headerHeight)
            ForEach(rows) { entry in
                row(entry)
                    .frame(height: Self.rowHeight)
                    .contextMenu {
                        Button("Unarchive") { unarchive(entry) }
                    }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ArchiveEntry) -> some View {
        let index = indexByID[entry.id] ?? 0
        switch entry {
        case .project(let project):
            ArchiveProjectRow(
                project: project,
                selected: index == selection,
                unarchive: { unarchive(entry) }
            ) {
                selection = index
                unarchive(entry)
            }
        case .session(let session):
            HistoryResultRow(
                session: session,
                selected: index == selection,
                trailingAction: ("Unarchive", { unarchive(entry) })
            ) {
                selection = index
                act(on: entry)
            }
        }
    }

    private static let rowHeight: CGFloat = 52
    private static let headerHeight: CGFloat = 27

    private func reload() {
        let rows = Array((model.archivedProjectResults(query).map(ArchiveEntry.project)
                          + model.archivedSessionResults(query).map(ArchiveEntry.session))
                             .prefix(250))
        entries = rows
        // Uniquing defensively, as HistoryView does: a duplicate id would be a
        // hard crash with uniqueKeysWithValues.
        indexByID = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        selection = 0
    }

    private func reloadPreservingSelection() {
        let selectedID = entries.indices.contains(selection) ? entries[selection].id : nil
        let previous = selection
        reload()
        if let selectedID, let index = indexByID[selectedID] {
            selection = index
        } else if !entries.isEmpty {
            // The selected row is gone — usually because it was just
            // unarchived from here. Stay where the eye is rather than jumping
            // back to the top.
            selection = min(previous, entries.count - 1)
        }
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = max(0, min(entries.count - 1, selection + delta))
    }

    private func actOnSelection() {
        guard entries.indices.contains(selection) else { return }
        act(on: entries[selection])
    }

    /// Return / click. A session comes back AND opens (opening is what you came
    /// for); a project only comes back — its row disappears and the panel stays
    /// up, because unarchiving a project is usually one of several.
    private func act(on entry: ArchiveEntry) {
        switch entry {
        case .project:
            unarchive(entry)
        case .session(let session):
            model.overlay.setArchived(false, sessionID: session.id)
            model.openSessions.openSession(session)
            model.archivePresented = false
        }
    }

    private func unarchive(_ entry: ArchiveEntry) {
        switch entry {
        case .project(let project):
            model.overlay.setProjectArchived(false, path: project.path)
        case .session(let session):
            model.overlay.setArchived(false, sessionID: session.id)
        }
    }
}

/// An archived project in the ⌘⇧Y browser: the folder, where it lives, and how
/// much is inside it. Built to the same metrics as `HistoryResultRow` so the
/// two sections read as one list.
private struct ArchiveProjectRow: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    let selected: Bool
    let unarchive: () -> Void
    let act: () -> Void

    @State private var hovering = false

    private var parentPath: String {
        (project.path as NSString).deletingLastPathComponent
    }

    var body: some View {
        HStack(spacing: 10) {
            // Content and the trailing button are sibling hit targets (see
            // HistoryResultRow): the row's tap must not swallow the button.
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(parentPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 12)
                Text(project.sessions.count == 1 ? "1 session" : "\(project.sessions.count) sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            if hovering {
                Button("Unarchive", action: unarchive)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Palette.selectionFill
                             : (hovering ? Palette.hoverFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
