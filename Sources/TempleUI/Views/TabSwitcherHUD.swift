import SwiftUI
import TempleCore

/// ⌃⇥ — the tab switcher, shaped like the ⌘P project switcher one level down.
///
/// It walks open tabs most-recently-visited first (the ⌘⇥ order), not row
/// order: hold ⌃ and tap ⇥ to walk, release ⌃ to land — so one tap bounces to
/// the tab you were just on, wherever it lives. Tabs read top-to-bottom (they
/// are titles, not tiles), unlike ⌘P's horizontal row of folders.
struct TabSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    /// The walk can outrun what fits on screen; the list windows itself to
    /// keep the highlight visible instead of scrolling (a HUD you hold has no
    /// business needing a scroll bar).
    private static let maxVisible = 12

    private var tabs: [SessionTab] { model.switchableTabs }

    /// Where you are switching FROM — outlined like ⌘P's current project.
    private var current: SessionTab.ID? { model.openSessions.activeTabID }

    var body: some View {
        let all = tabs
        let selected = all.firstIndex { $0.id == model.tabSwitcherSelection } ?? 0
        // Slide a fixed window along the list so the highlight is always shown.
        let start = max(0, min(selected - (Self.maxVisible - 1), all.count - Self.maxVisible))
        let end = min(start + Self.maxVisible, all.count)

        VStack(alignment: .leading, spacing: 2) {
            if start > 0 {
                moreLabel(start, edge: "above")
            }
            ForEach(all[start..<end]) { tab in
                row(tab, selected: tab.id == model.tabSwitcherSelection)
            }
            if end < all.count {
                moreLabel(all.count - end, edge: "below")
            }
        }
        .padding(10)
        .frame(width: 440)
        .panelChrome(cornerRadius: 16)
        .fixedSize()
    }

    private func row(_ tab: SessionTab, selected: Bool) -> some View {
        let isCurrent = tab.id == current
        return HStack(spacing: 9) {
            if tab.kind == .settings {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 15)
                    .foregroundStyle(selected ? .primary : .secondary)
            } else {
                AgentBadge(agent: tab.agent, size: 15)
            }

            Text(model.tabDisplayTitle(tab))
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // An agent working (or waiting on you) in a tab you are NOT
            // looking at is the whole reason to glance at this list.
            if tab.activity == .running || tab.activity == .needsAttention {
                ActivityDot(state: tab.activity, size: 6)
            }

            Spacer(minLength: 12)

            // The trail spans projects, so say where each tab would take you.
            Text(tab.kind == .settings
                 ? (isCurrent ? "current" : "")
                 : (isCurrent ? "current" : model.projectName(tab.projectPath)))
                .font(.system(size: 10.5, weight: isCurrent ? .medium : .regular))
                .tracking(isCurrent ? 0.4 : 0)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Palette.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        // The tab you are leaving keeps a quiet outline even when the
        // highlight has moved on somewhere else.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(isCurrent ? 0.18 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.tabSwitcherSelection = tab.id
            model.commitTabSwitcher()
        }
    }

    private func moreLabel(_ count: Int, edge: String) -> some View {
        Text("\(count) more \(edge)")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}
