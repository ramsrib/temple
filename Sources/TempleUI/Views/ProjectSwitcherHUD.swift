import SwiftUI
import TempleCore

/// ⌘P — the project switcher, shaped like the macOS app switcher rather than
/// like ⌘K.
///
/// The two are different acts and should not look the same: ⌘K searches hundreds
/// of sessions, so it is a field; you switch between a handful of projects you
/// are already holding in your head, so it is a row of tiles you tab through.
/// Hold ⌘ and tap P to walk, release ⌘ to land — the ⌘⇥ gesture, so one tap
/// bounces to the project you were just in.
struct ProjectSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    private var projects: [String] { model.switchableProjects }

    /// Where you are switching FROM. Most-recently-used order puts it first, and
    /// saying so matters: without it the highlight alone tells you where you would
    /// land but not where you would be leaving.
    private var current: String? { model.openSessions.activeProjectPath }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(projects, id: \.self) { path in
                tile(path, selected: path == model.projectSwitcherSelection)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(radius: 30, y: 10)
        .fixedSize()
    }

    private func tile(_ path: String, selected: Bool) -> some View {
        let tabs = model.openSessions.tabs.filter { $0.kind == .session && $0.projectPath == path }
        let states = tabs.map(\.activity)
        let activity: ActivityState? = states.contains(.needsAttention) ? .needsAttention
            : (states.contains(.running) ? .running : nil)
        let isCurrent = path == current

        return VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: isCurrent ? "folder.fill" : "folder")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 56, height: 44)
                // An agent working (or waiting on you) in a project you are NOT
                // looking at is the whole reason to glance at this list.
                if let activity {
                    ActivityDot(state: activity, size: 7)
                }
            }

            Text(model.projectName(path))
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // One caption line for every tile, so the row's baselines stay level.
            Text(isCurrent ? "current" : "\(tabs.count) session\(tabs.count == 1 ? "" : "s")")
                .font(.system(size: 9.5, weight: isCurrent ? .medium : .regular))
                .tracking(isCurrent ? 0.4 : 0)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: 96)
        .padding(.vertical, 10)
        .background(selected ? Palette.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12))
        // The project you are leaving keeps a quiet outline even when the
        // highlight has moved on somewhere else.
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(isCurrent ? 0.18 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.projectSwitcherSelection = path
            model.commitProjectSwitcher()
        }
    }

}
