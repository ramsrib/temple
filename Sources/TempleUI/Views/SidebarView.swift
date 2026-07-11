import SwiftUI
import TempleCore

/// The left rail (UX §Sidebar): wordmark + search, New session, Pinned, project
/// disclosure groups, footer. The full browse index — a row here is browsable
/// (click opens); arrow keys only highlight (select ≠ open).
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var showAllProjects = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            sessionList
            Divider().opacity(0.4)
            footer
        }
        .background(.ultraThinMaterial)
        .onChange(of: model.focusSearchToken) { searchFocused = true }
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

    private var sessionList: some View {
        List {
            if !model.pinnedSessions.isEmpty {
                Section("Pinned") {
                    ForEach(model.pinnedSessions) { session in
                        SessionRow(session: session)
                    }
                }
            }

            Section("Projects") {
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
    @State private var showAll = false
    @State private var headerHovering = false

    private let collapsedLimit = 6

    private var shownSessions: [AgentSession] {
        showAll ? project.sessions : Array(project.sessions.prefix(collapsedLimit))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(shownSessions) { session in
                SessionRow(session: session)
            }
            if project.sessions.count > collapsedLimit && !showAll {
                // Mirror SessionRow's geometry exactly (same listRowInsets +
                // inner padding) so the text starts on the agent-badge column.
                Button("Show more") { showAll = true }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowBackground(Color.clear)
            }
        } label: {
            HStack(spacing: 4) {
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
            .onTapGesture { withAnimation { expanded.toggle() } }
            .overlay(alignment: .trailing) {
                NewSessionMenu(projectPath: project.path)
            }
        }
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
