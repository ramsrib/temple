import SwiftUI
import TempleCore

/// ⌃⇥ — the tab switcher. It walks open tabs most-recently-visited first (the
/// ⌘⇥ order), not row order: hold ⌃ and tap ⇥ to walk, release ⌃ to land — so
/// one tap bounces to the tab you were just on, wherever it lives.
///
/// Cards in a centred panel, the ⌘P switcher's family: the two "hold a key
/// and tap" switchers look alike, and neither looks like ⌘K. It used to be a
/// ⌘K twin (same width, same top anchor, the same two-line rows), and read
/// as a search box with its field missing. Nothing here is typed into.
struct TabSwitcherHUD: View {
    @EnvironmentObject var model: AppModel

    private var tabs: [SessionTab] { model.switchableTabs }

    /// Where you are switching FROM — labeled, because the highlight alone
    /// tells you where you would land but not where you would be leaving.
    private var current: SessionTab.ID? { model.openSessions.activeTabID }

    /// Four cards a row (4 × 196 + gaps + padding = 840 pt) so the panel
    /// fits Temple's narrowest window (900 pt); more rows scroll.
    static let cardSize = CGSize(width: 196, height: 92)
    static let spacing: CGFloat = 8
    static let maxColumns = 4
    static let maxRows = 3

    var body: some View {
        let tabs = self.tabs
        let columns = max(1, min(Self.maxColumns, tabs.count))
        let rows = Int((Double(tabs.count) / Double(columns)).rounded(.up))
        let gridHeight = CGFloat(min(rows, Self.maxRows)) * (Self.cardSize.height + Self.spacing) - Self.spacing
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardSize.width), spacing: Self.spacing),
                                             count: columns),
                              spacing: Self.spacing) {
                        ForEach(tabs) { tab in
                            card(tab, selected: tab.id == model.tabSwitcherSelection)
                                .id(tab.id)
                        }
                    }
                }
                .frame(height: gridHeight)
                .scrollDisabled(rows <= Self.maxRows)
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
        .padding(16)
        .panelChrome(cornerRadius: 16)
    }

    /// A card reads like a window's title bar over its content: where the
    /// tab is (agent, project, host) on one quiet line, then what it is,
    /// the title, in the body. Only the card the walk is on is filled, as
    /// in the macOS app switcher; the rest sit on the panel itself.
    private func card(_ tab: SessionTab, selected: Bool) -> some View {
        let isCurrent = tab.id == current
        let mark = TabColorMark.color(for: tab.sessionKey, in: model)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Group {
                    if let symbol = tab.kind.utilitySymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        AgentBadge(agent: tab.agent, size: 13)
                    }
                }
                .frame(width: 14)
                if tab.kind == .session {
                    Text(tab.projectKey.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let host = ProjectNameLabel.hostTag(tab.projectKey) {
                        Text(host)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if isCurrent {
                    Text("this tab")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                // An agent working (or waiting on you) in a tab you are NOT
                // looking at is the whole reason to glance at this panel.
                if tab.activity == .running || tab.activity == .needsAttention {
                    ActivityDot(state: tab.activity, size: 7)
                }
            }
            Text(model.tabDisplayTitle(tab))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
        .background(selected ? Palette.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The tab you are leaving keeps a quiet outline when the highlight
        // has moved on, as ⌘P's tile does.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline.opacity(isCurrent && !selected ? 1 : 0), lineWidth: 1)
        )
        // A colour mark is the sidebar's slim bar, never a fill: a washed
        // card read as a second selection.
        .overlay(alignment: .leading) {
            if let mark {
                Capsule()
                    .fill(mark)
                    .frame(width: 3)
                    .padding(.vertical, 14)
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
