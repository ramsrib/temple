import SwiftUI
import TempleCore

/// ⌘P — the project switcher. Hold ⌘ and tap P to walk, release ⌘ to land —
/// the ⌘⇥ gesture, so one tap bounces to the project you were just in.
///
/// The ⌃⇥ tab switcher's list, with projects in it (design audit, 2026-11).
/// It was a row of folder tiles after the macOS app switcher, a third shape
/// beside ⌘K's rows and ⌃⇥'s; a project is a name, and a name fits a line.
/// Still no field: you switch between a handful of projects you are already
/// holding in your head.
struct ProjectSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    private var projects: [ProjectKey] { model.switchableProjectKeys }

    /// Where you are switching FROM. Most-recently-used order puts it first, and
    /// saying so matters: without it the highlight alone tells you where you would
    /// land but not where you would be leaving.
    private var current: ProjectKey? { model.openSessions.activeProjectKey }

    var body: some View {
        let projects = self.projects
        let rowHeight = TabSwitcherHUD.rowHeight
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(projects, id: \.self) { project in
                            row(project, selected: project == model.projectSwitcherKeySelection)
                                .id(project)
                        }
                    }
                }
                .frame(height: CGFloat(min(projects.count, TabSwitcherHUD.maxRows)) * rowHeight)
                .scrollDisabled(projects.count <= TabSwitcherHUD.maxRows)
                .thinScrollers()
                .onChange(of: model.projectSwitcherKeySelection) {
                    if let selection = model.projectSwitcherKeySelection {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
            Text("Release ⌘ to switch")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: TabSwitcherHUD.width)
        .panelChrome(cornerRadius: 16)
    }

    /// One line: the project and its machine, then how many sessions it has
    /// open, then its state. An agent working (or waiting on you) in a
    /// project you are NOT looking at is the whole reason to glance here.
    private func row(_ project: ProjectKey, selected: Bool) -> some View {
        let tabs = model.openSessions.tabs.filter { $0.kind == .session && $0.projectKey == project }
        let states = tabs.map(\.activity)
        let activity: ActivityState? = states.contains(.needsAttention) ? .needsAttention
            : (states.contains(.running) ? .running : nil)
        let isCurrent = project == current

        return HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            ProjectNameLabel(key: project,
                             font: .system(size: 13, weight: selected ? .medium : .regular),
                             hostFont: .system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(isCurrent ? "this project" : "\(tabs.count) session\(tabs.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Group {
                if let activity, !isCurrent { ActivityDot(state: activity, size: 7) }
            }
            .frame(minWidth: 12, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: TabSwitcherHUD.rowHeight)
        .panelRow(selected: selected, hovering: false)
        .contentShape(Rectangle())
        .onTapGesture {
            model.projectSwitcherKeySelection = project
            model.commitProjectSwitcher()
        }
    }
}
