import SwiftUI
import TempleCore

/// ⌃⇥ — the tab switcher. It walks open tabs most-recently-visited first (the
/// ⌘⇥ order), not row order: hold ⌃ and tap ⇥ to walk, release ⌃ to land — so
/// one tap bounces to the tab you were just on, wherever it lives.
///
/// Chrome-wise it is a ⌘K sibling (same width, same top anchor, same capped
/// row list) so flicking between the palettes and the switcher never feels
/// like a mode change — but it stays a momentary HUD you hold, so there is no
/// search field: you pick from tabs you are already holding in your head.
struct TabSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    private var tabs: [SessionTab] { model.switchableTabs }

    /// Where you are switching FROM — labeled, because the highlight alone
    /// tells you where you would land but not where you would be leaving.
    private var current: SessionTab.ID? { model.openSessions.activeTabID }

    var body: some View {
        let tabs = self.tabs
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        row(tab, selected: tab.id == model.tabSwitcherSelection)
                            .frame(height: Self.rowHeight)
                    }
                }
            }
            // Hug the rows (⌘K's rule): scroll only past the cap.
            .frame(height: min(CGFloat(tabs.count) * Self.rowHeight, 340))
            .thinScrollers()
            .onChange(of: model.tabSwitcherSelection) {
                if let selection = model.tabSwitcherSelection {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        .frame(width: 560)
        .panelChrome()
    }

    /// Same metrics as a ⌘K result row (two text lines + padding).
    private static let rowHeight: CGFloat = 46

    private func row(_ tab: SessionTab, selected: Bool) -> some View {
        let isCurrent = tab.id == current
        return HStack(spacing: 10) {
            if tab.kind == .settings {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
            } else {
                AgentBadge(agent: tab.agent, size: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.tabDisplayTitle(tab))
                    .font(.system(size: 13))
                    .lineLimit(1)
                // The trail spans projects, so say where each tab would take you.
                if tab.kind == .session {
                    Text(model.projectName(tab.projectPath))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            // An agent working (or waiting on you) in a tab you are NOT
            // looking at is the whole reason to glance at this list.
            if tab.activity == .running || tab.activity == .needsAttention {
                ActivityDot(state: tab.activity, size: 6)
            }
            if isCurrent {
                Text("current")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Palette.selectionFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.tabSwitcherSelection = tab.id
            model.commitTabSwitcher()
        }
    }
}
