import SwiftUI
import TempleCore

/// The left rail: search-first, Pinned, project
/// disclosure groups, footer. The full browse index — a row here is browsable
/// (click opens); arrow keys only highlight (select ≠ open).
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var showAllProjects = false
    @State private var headerHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            sessionList
            Divider().opacity(0.4)
            footer
        }
        .background(.ultraThinMaterial)
        .onChange(of: model.focusSearchToken) { FieldFocus.claim { searchFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        // Search is the first element — no wordmark. It sits just below the
        // native unified-toolbar band (which carries the traffic lights +
        // sidebar toggle and is itself the window drag area — Item A/F/G).
        searchField
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: List

    /// "Projects" + the way to add one. A folder, not a `+`: the per-project `+`
    /// starts a session inside a project you already have, and adding a project
    /// Temple has never seen is a different act that must not wear the same icon.
    private var projectsHeader: some View {
        HStack(spacing: 4) {
            Text("Projects")
            Spacer(minLength: 4)
            Button {
                chooseProjectFolder { path in
                    model.openSessions.newSessionDefaultAgent(projectPath: path)
                }
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(headerHovering ? .secondary : .tertiary)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a project folder…")
        }
        .onHover { headerHovering = $0 }
    }

    private var sessionList: some View {
        List {
            if !model.pinnedSessions.isEmpty {
                Section("Pinned") {
                    ForEach(model.pinnedSessions) { session in
                        SessionRow(session: session)
                    }
                }
            }

            Section(header: projectsHeader) {
                if model.displayProjects.isEmpty && !model.isLoading {
                    Text(model.searchText.isEmpty ? "No sessions yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(showAllProjects ? model.displayProjects : model.cappedDisplayProjects) { project in
                    ProjectDisclosure(project: project)
                }
                if model.searchText.isEmpty && model.hiddenProjectsCount > 0 {
                    Button(showAllProjects
                           ? "Show fewer"
                           : "Show all projects (\(model.hiddenProjectsCount) more)") {
                        showAllProjects.toggle()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // With "Show scroll bars: Always" set in System Settings, AppKit gives the
        // List a legacy scroller: a permanent ~15pt bar with a track, running the
        // full height beside every row. Setting scrollerStyle on the NSScrollView
        // does not stick (AppKit re-applies the system style on layout), so the
        // indicator is removed outright — the sidebar is a short list you can see
        // the extent of, not a document you navigate by scroll position.
        .scrollIndicators(.never)
        .background(SidebarScrollers())
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            Text(NSFullUserName().isEmpty ? "You" : NSFullUserName())
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button(action: { model.openSessions.openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A project as a Codex-style disclosure group (default expanded) with a
/// per-project "Show more".
private struct ProjectDisclosure: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var expanded = true
    @State private var headerHovering = false

    /// How many sessions this project currently shows. Grows a batch at a time —
    /// a project with 50+ sessions would otherwise dump all of them into the
    /// sidebar on one click, with no way back.
    @State private var limit = collapsedLimit

    private static let collapsedLimit = 6
    private static let batch = 10

    private var shownSessions: [AgentSession] {
        Array(project.sessions.prefix(limit))
    }

    private var hiddenCount: Int {
        max(0, project.sessions.count - limit)
    }

    /// Session rows indent one shallow step (ChatGPT-style density): the agent
    /// badge sits under the folder icon, not under the project name. Manual
    /// header + rows because DisclosureGroup's child outline indent is fixed
    /// and much deeper.
    private static let childInset: CGFloat = 8

    var body: some View {
        header
        if expanded {
            ForEach(shownSessions) { session in
                SessionRow(session: session)
                    .padding(.leading, Self.childInset)
                    .listRowInsets(EdgeInsets(top: 1, leading: -10, bottom: 1, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            if hiddenCount > 0 || limit > Self.collapsedLimit {
                HStack(spacing: 10) {
                    if hiddenCount > 0 {
                        // The remaining count is the point: without it, one click
                        // on a 53-session project is a surprise. It is only worth
                        // showing when this batch won't finish the list.
                        let next = min(Self.batch, hiddenCount)
                        let title = next < hiddenCount
                            ? "Show \(next) more (\(hiddenCount))"
                            : "Show \(next) more"
                        expandButton(title) { limit += Self.batch }
                    }
                    if limit > Self.collapsedLimit {
                        expandButton("Show fewer") { limit = Self.collapsedLimit }
                    }
                }
                // Starts on the agent-badge column: a plain Button's label sits
                // further left in a List row than SessionRow's own content, so
                // this inset is measured against the rendered badge (its ink
                // begins 25pt in from the child inset), not derived from
                // SessionRow's paddings.
                .padding(.leading, Self.childInset + 25)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .listRowInsets(EdgeInsets(top: 1, leading: -10, bottom: 1, trailing: 8))
                .listRowBackground(Color.clear)
            }
        }
    }

    private func expandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
            Label(project.name, systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        // Item C: hover highlight on the project header row too.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(headerHovering ? Palette.hoverFill : Color.clear))
        // Whole row toggles the disclosure (name, icon, empty space) —
        // matching the chevron. The `+` overlay keeps its own action.
        .contentShape(Rectangle())
        .onHover { headerHovering = $0 }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
        .overlay(alignment: .trailing) {
            NewSessionMenu(projectPath: project.path)
        }
        // Negative leading inset cancels List's sidebar-section indent so the
        // chevron column lines up with the "Projects" header.
        .listRowInsets(EdgeInsets(top: 1, leading: -10, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }
}

/// The right-aligned `+` on a project row → New Claude / New Codex in THAT
/// project (UX §New session, per-project entry). Quiet until hover; monochrome.
/// Its own click target so it never toggles the disclosure.
private struct NewSessionMenu: View {
    @EnvironmentObject var model: AppModel
    let projectPath: String
    @State private var hovering = false

    var body: some View {
        Menu {
            Button {
                model.openSessions.newSession(agent: .claude, projectPath: projectPath)
            } label: { Label("New Claude Session", systemImage: "plus") }
            Button {
                model.openSessions.newSession(agent: .codex, projectPath: projectPath)
            } label: { Label("New Codex Session", systemImage: "plus") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New session in \(model.projectName(projectPath))")
    }
}
