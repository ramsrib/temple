import SwiftUI
import TempleCore

/// The left rail (UX §Sidebar): wordmark + search, New session, Pinned, project
/// disclosure groups, footer. The full browse index — a row here is browsable
/// (click opens); arrow keys only highlight (select ≠ open).
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Temple")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
            }
            searchField
            Button(action: { model.presentLauncher() }) {
                Label("New session", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)   // clear the floating traffic lights (hidden titlebar)
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
                ForEach(model.displayProjects) { project in
                    ProjectDisclosure(project: project)
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
                Button("Show more") { showAll = true }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        } label: {
            Label(project.name, systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
    }
}
