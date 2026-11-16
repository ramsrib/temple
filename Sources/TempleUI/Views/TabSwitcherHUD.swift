import SwiftUI
import TempleCore

/// ⌃⇥ — the tab switcher. It walks open tabs most-recently-visited first (the
/// ⌘⇥ order), not row order: hold ⌃ and tap ⇥ to walk, release ⌃ to land — so
/// one tap bounces to the tab you were just on, wherever it lives.
///
/// A centred list in the ⌘P switcher's frame (round 3). A tab is identified
/// by a sentence, its title, and a sentence fits a row, not a tile: round 2's
/// 196×92 cards held one line of text in a 2:1 box, so 40% of every card was
/// empty and the selection painted that empty slab. Nor is it the old ⌘K
/// twin (top-anchored, ⌘K's width, two-line rows), which read as a search box
/// with its field missing: this is narrower, centred in the window, one line
/// a row, with no field, and says how it is used at the bottom. It is the
/// form VS Code's and JetBrains' ⌃⇥ switchers take.
struct TabSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    private var tabs: [SessionTab] { model.switchableTabs }

    /// Where you are switching FROM — labeled, because the highlight alone
    /// tells you where you would land but not where you would be leaving.
    private var current: SessionTab.ID? { model.openSessions.activeTabID }

    static let width: CGFloat = 480
    static let rowHeight: CGFloat = 36
    /// Rows shown before the list scrolls.
    static let maxRows = 9

    var body: some View {
        let tabs = self.tabs
        let listHeight = CGFloat(min(tabs.count, Self.maxRows)) * Self.rowHeight
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            row(tab, selected: tab.id == model.tabSwitcherSelection)
                                .id(tab.id)
                        }
                    }
                }
                .frame(height: listHeight)
                .scrollDisabled(tabs.count <= Self.maxRows)
                .thinScrollers()
                .onChange(of: model.tabSwitcherSelection) {
                    if let selection = model.tabSwitcherSelection {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
            Text("Release ⌃ to switch")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: Self.width)
        .panelChrome(cornerRadius: 16)
    }

    /// One line: what the tab is (badge, title) first, where it lives
    /// (project, host) after it, quieter, then its state. Only the row the
    /// walk is on is filled, as in the macOS app switcher.
    private func row(_ tab: SessionTab, selected: Bool) -> some View {
        let isCurrent = tab.id == current
        let mark = TabColorMark.color(for: tab.sessionKey, in: model)
        return HStack(spacing: 8) {
            Group {
                if let symbol = tab.kind.utilitySymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    AgentBadge(agent: tab.agent, size: 14)
                }
            }
            .frame(width: 16)
            Text(model.tabDisplayTitle(tab))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tab.kind == .session {
                HStack(spacing: 4) {
                    Text(tab.projectKey.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let host = ProjectNameLabel.hostTag(tab.projectKey) {
                        Text(host)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .trailing)
            }
            // The state column: the tab you are leaving says so; an agent
            // working (or waiting on you) in a tab you are NOT looking at is
            // the whole reason to glance at this panel.
            Group {
                if isCurrent {
                    Text("this tab")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if tab.activity == .running || tab.activity == .needsAttention {
                    ActivityDot(state: tab.activity, size: 7)
                }
            }
            .frame(minWidth: 12, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(selected ? Palette.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A colour mark is the sidebar's slim bar, never a fill: a washed
        // row read as a second selection.
        .overlay(alignment: .leading) {
            if let mark {
                Capsule()
                    .fill(mark)
                    .frame(width: 3)
                    .padding(.vertical, 9)
                    .padding(.leading, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.tabSwitcherSelection = tab.id
            model.commitTabSwitcher()
        }
    }
}
