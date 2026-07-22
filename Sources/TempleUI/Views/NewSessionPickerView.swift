import SwiftUI
import TempleCore

/// ⌘N — pick a project, get a new default-agent session in it. The keyboard
/// sibling of the sidebar project-header `+`: ⌘T starts a session *here*,
/// ⌘N starts one *somewhere you name*. Same overlay chrome as ⌘K/⌘Y.
struct NewSessionPickerView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var projects: [Project] {
        Array(model.projectPickerResults(query).prefix(40))
    }

    var body: some View {
        // One filter pass per render (the palettes' discipline).
        let projects = self.projects
        // The trailing pseudo-row: "Choose folder…" is always reachable by
        // keyboard, so a project Temple has never indexed is never mouse-only.
        let rowCount = projects.count + 1
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("New \(model.newSessionPickerAgent.displayName) session in project…",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { open(index: selection, in: projects) }
                    .onChange(of: query) { selection = 0 }
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

            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack: same stale-highlight LazyVStack trap as the
                    // palette (see CommandPaletteView).
                    VStack(spacing: 0) {
                        ForEach(Array(projects.enumerated()), id: \.element.path) { idx, project in
                            ProjectPickerRow(project: project, selected: idx == selection) {
                                selection = idx
                                open(index: idx, in: projects)
                            }
                            .frame(height: Self.rowHeight)
                            .id(project.path)
                        }
                        chooseFolderRow(selected: selection == projects.count)
                            .frame(height: Self.rowHeight)
                            .id(Self.chooseFolderID)
                    }
                }
                .frame(height: min(CGFloat(rowCount) * Self.rowHeight, 340))
                .thinScrollers()
                .onChange(of: selection) {
                    proxy.scrollTo(selection < projects.count
                                   ? projects[selection].path : Self.chooseFolderID,
                                   anchor: .center)
                }
            }
        }
        .frame(width: 560)   // matches CommandPaletteView — visual siblings
        .panelChrome()
        .onAppear { FieldFocus.claim { fieldFocused = true } }
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onKeyPress(.downArrow) { move(1, rowCount: rowCount); return .handled }
        .onKeyPress(.upArrow) { move(-1, rowCount: rowCount); return .handled }
        .onKeyPress(.escape) { model.newSessionPickerPresented = false; return .handled }
    }

    private static let rowHeight: CGFloat = 46
    private static let chooseFolderID = "temple.picker.chooseFolder"

    private func chooseFolderRow(selected: Bool) -> some View {
        PickerRowChrome(selected: selected) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Choose folder…")
                    .font(.system(size: 13))
                Spacer()
            }
        } action: { chooseFolder() }
    }

    private func move(_ delta: Int, rowCount: Int) {
        selection = max(0, min(rowCount - 1, selection + delta))
    }

    private func open(index: Int, in projects: [Project]) {
        if projects.indices.contains(index) {
            model.openSessions.newSession(agent: model.newSessionPickerAgent,
                                          projectPath: projects[index].path)
            model.newSessionPickerPresented = false
        } else {
            chooseFolder()
        }
    }

    private func chooseFolder() {
        let agent = model.newSessionPickerAgent
        model.newSessionPickerPresented = false
        chooseProjectFolder { path in
            model.openSessions.newSession(agent: agent, projectPath: path)
        }
    }
}

/// Shared hover/selection treatment for picker rows (PaletteResultRow's).
private struct PickerRowChrome<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Palette.selectionFill
                                 : (hovering ? Palette.hoverFill : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

private struct ProjectPickerRow: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    let selected: Bool
    let open: () -> Void

    var body: some View {
        PickerRowChrome(selected: selected) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectName(project.path))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(project.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(RelativeTime.string(from: project.lastActivity))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } action: { open() }
    }
}
