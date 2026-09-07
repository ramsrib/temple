import SwiftUI
import TempleCore

/// ⌘⇧Y: what has been put away, laid out the way the sidebar lays out what is
/// not — projects as groups, sessions inside them — because that is the shape
/// the user already reads. An archived project is a group with every session it
/// hides listed under it, so "5 sessions" is never a number you have to trust;
/// a session archived on its own sits under its project's name. Every row has
/// one explicit action, Restore, and a session can also be opened, which
/// restores it on the way. Fixed size: a window, not a list that resizes under
/// the pointer. Same chrome as the other panels; the sidebar deliberately
/// carries no archive affordance, and this is the way back.
struct ArchiveView: View {
    @EnvironmentObject var model: AppModel
    /// The panel's height, from the window (RootView clamps it).
    var height: CGFloat = 540

    @State private var query = ""
    @State private var groups: [AppModel.ArchiveGroup] = []
    @State private var entries: [Entry] = []
    @State private var indexByID: [String: Int] = [:]
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    /// One keyboard-selectable line: a whole-project group's header, or a
    /// session row. Headers of groups that merely contain archived sessions
    /// are labels, not rows — there is nothing to restore on them.
    enum Entry: Identifiable {
        case project(Project)
        case session(AgentSession)

        var id: String {
            switch self {
            case .project(let project): return "project:\(project.path)"
            case .session(let session): return "session:\(session.id)"
            }
        }
    }

    private static let width: CGFloat = 640

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
        .frame(width: Self.width, height: height)
        .panelChrome()
        .onAppear {
            reload()
            FieldFocus.claim { fieldFocused = true }
        }
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onChange(of: query) { _, _ in reload() }
        // The rows are @State, so an index update — or a restore from this very
        // panel — needs an explicit refresh. Selection sticks to its row's id.
        .onChange(of: model.index) { _, _ in reloadPreservingSelection() }
        .onReceive(model.overlay.objectWillChange
            .receive(on: DispatchQueue.main)) { _ in reloadPreservingSelection() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.archivePresented = false; return .handled }
    }

    // MARK: Header — title, what is in the box, then search (search-first, like the sidebar)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Archive")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            searchField
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// The whole archive, not the filtered view — the header says what is in
    /// the box, the list says what matches.
    private var summary: String {
        let projects = model.archivedProjects.count
        let sessions = model.archivedSessionResults("").count
        if projects == 0 && sessions == 0 { return "" }
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
            TextField("Search archived projects and sessions", text: $query)
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

    // MARK: List — groups like the sidebar's

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Eager, like the history and palette lists: a lazy stack can
                // leave a materialized row's selection fill stale while the
                // keyboard highlight moves.
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        groupHeader(group)
                        ForEach(group.project.sessions) { session in
                            sessionRow(session)
                        }
                        Spacer().frame(height: 8)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
            .thinScrollers()
            .onChange(of: selection) {
                if entries.indices.contains(selection) {
                    proxy.scrollTo(entries[selection].id, anchor: .center)
                }
            }
        }
    }

    /// A whole-project group is a selectable row with its own Restore; a group
    /// that only holds archived sessions is a plain label over them.
    @ViewBuilder
    private func groupHeader(_ group: AppModel.ArchiveGroup) -> some View {
        if group.wholeProject {
            let entry = Entry.project(group.project)
            let index = indexByID[entry.id] ?? 0
            ArchiveRow(
                selected: index == selection,
                restoreLabel: "Restore project",
                restore: { restore(entry) },
                act: { selection = index; restore(entry) }
            ) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(group.project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(parentPath(group.project.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 12)
                Text("Archived project")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.surfaceFill, in: Capsule())
            }
            .id(entry.id)
            .contextMenu { Button("Restore project") { restore(entry) } }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(group.project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(parentPath(group.project.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let entry = Entry.session(session)
        let index = indexByID[entry.id] ?? 0
        return ArchiveRow(
            selected: index == selection,
            restoreLabel: "Restore",
            restore: { restore(entry) },
            act: { selection = index; act(on: entry) }
        ) {
            AgentBadge(agent: session.agent, size: 13)
                .frame(width: 16)
            Text(model.displayTitle(session))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(RelativeTime.string(from: session.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.leading, 18)
        .id(entry.id)
        .contextMenu {
            Button("Open") { act(on: entry) }
            Button("Restore") { restore(entry) }
        }
    }

    private func parentPath(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
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
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer — the keys, and what Return does to the lit row

    private var footer: some View {
        HStack(spacing: 18) {
            hint("↑↓", "select")
            hint("↩", returnHint)
            hint("esc", "close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var returnHint: String {
        guard entries.indices.contains(selection) else { return "open" }
        switch entries[selection] {
        case .project: return "restore project"
        case .session: return "open session (restores it)"
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

    // MARK: Data

    private func reload() {
        groups = model.archiveGroups(query)
        var rows: [Entry] = []
        for group in groups {
            if group.wholeProject { rows.append(.project(group.project)) }
            rows.append(contentsOf: group.project.sessions.map(Entry.session))
        }
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
            // The selected row is gone — usually because it was just restored
            // from here. Stay where the eye is rather than jumping to the top.
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
    /// for); a project only comes back — its group disappears and the panel
    /// stays up, because restoring a project is usually one of several.
    private func act(on entry: Entry) {
        switch entry {
        case .project:
            restore(entry)
        case .session(let session):
            restore(entry)
            model.openSessions.openSession(session)
            model.archivePresented = false
        }
    }

    /// A session inside an archived project is restored by restoring the
    /// project — it was never archived on its own, so there is no per-session
    /// flag to clear, and leaving the project archived would hide it again.
    private func restore(_ entry: Entry) {
        switch entry {
        case .project(let project):
            model.overlay.setProjectArchived(false, path: project.path)
        case .session(let session):
            if model.overlay.isProjectArchived(session.projectPath) {
                model.overlay.setProjectArchived(false, path: session.projectPath)
            }
            model.overlay.setArchived(false, sessionID: session.id)
        }
    }
}

/// One line of the archive: content on the left, a Restore button on the right
/// that is always laid out and shown on hover or selection — inserting it only
/// on hover shoved the content sideways under the pointer, and left rows
/// misaligned with their neighbours. The content is its own hit target for
/// `act`, the button its own for `restore`, so the two can never both fire.
private struct ArchiveRow<Content: View>: View {
    let selected: Bool
    let restoreLabel: String
    let restore: () -> Void
    let act: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8, content: content)
                .contentShape(Rectangle())
                .onTapGesture(perform: act)
            Button(restoreLabel, action: restore)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(hovering || selected ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(selected ? Palette.selectionFill
                             : (hovering ? Palette.hoverFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
