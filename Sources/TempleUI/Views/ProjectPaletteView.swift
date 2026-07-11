import SwiftUI
import TempleCore

/// ⌘P — the keyboard way between projects. Empty query lists the projects you
/// have work open in; typing reaches every project Temple knows, so switching to
/// one you have not touched today costs the same as one you have.
///
/// The title-bar switcher does the same job for the mouse; the pair exists
/// because ⌘⇧[ / ⌘⇧] only helps when the project you want happens to be next.
struct ProjectPaletteView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [Project] {
        Array(model.projectPaletteResults(query).prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("Switch to a project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onChange(of: query) { selection = 0 }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text(query.isEmpty ? "No projects open — type to search all" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, project in
                                row(project, selected: idx == selection)
                                    .frame(height: Self.rowHeight)
                                    .id(project.id)
                                    .onTapGesture { selection = idx; openSelected() }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(results.count) * Self.rowHeight, 340))
                    .onChange(of: selection) {
                        if results.indices.contains(selection) {
                            proxy.scrollTo(results[selection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 30, y: 10)
        // The terminal holds the window's first responder and SwiftUI focus
        // cannot take it — resign it first (see FieldFocus), and hand the
        // keyboard back to the agent when we close.
        .onAppear { FieldFocus.claim { fieldFocused = true } }
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.projectPalettePresented = false; return .handled }
    }

    private static let rowHeight: CGFloat = 46

    private func row(_ project: Project, selected: Bool) -> some View {
        let tabs = model.openSessions.tabs.filter { $0.kind == .session && $0.projectPath == project.path }
        let states = tabs.map(\.activity)
        let activity: ActivityState? = states.contains(.needsAttention) ? .needsAttention
            : (states.contains(.running) ? .running : nil)

        return HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                // The containing folder: worktrees of one repo share a name.
                Text(parentFolder(project.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let activity { ActivityDot(state: activity, size: 5) }
            if !tabs.isEmpty {
                Text("\(tabs.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Palette.selectionFill : Color.clear)
        .contentShape(Rectangle())
    }

    private func parentFolder(_ path: String) -> String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        let folder = (tilde as NSString).deletingLastPathComponent
        return folder.isEmpty ? tilde : folder
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        model.switchToProject(results[selection])
        model.projectPalettePresented = false
    }
}
