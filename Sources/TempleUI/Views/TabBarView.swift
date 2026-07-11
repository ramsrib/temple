import SwiftUI
import UniformTypeIdentifiers
import TempleCore

/// The tab strip that lives inside the native unified toolbar / title-bar band
/// (Item A). Shows ONLY the active project's open terminals, plus the
/// project-agnostic Settings tab, then the `+` menu. Intrinsically sized so the
/// rest of the title-bar band stays empty native chrome (double-click-to-zoom +
/// window-drag work there for free — Item B). Chips are drag-reorderable; the
/// trailing `+` opens a New Claude/Codex menu.
struct TabBarStrip: View {
    @EnvironmentObject var model: AppModel
    @State private var dragging: SessionTab.ID?

    private var sessionChips: [SessionTab] {
        model.openSessions.visibleTabs.filter { $0.kind == .session }
    }

    var body: some View {
        // A content-sized HStack (no Spacer / no greedy ScrollView): only the
        // chips occupy the band; everything to their right is native titlebar.
        HStack(spacing: 6) {
            ForEach(sessionChips) { tab in
                TabChip(tab: tab)
                    .onDrag {
                        dragging = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text],
                            delegate: TabDropDelegate(item: tab, model: model, dragging: $dragging))
            }
            // The project-agnostic Settings chip renders inline like any other
            // chip (gear icon), keeping its singleton semantics.
            if let settings = model.openSessions.settingsTab {
                TabChip(tab: settings)
            }
            // `+` sits immediately after the last chip — not pinned right.
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                if let path = model.openSessions.activeProjectPath {
                    model.openSessions.newSession(agent: .claude, projectPath: path)
                }
            } label: { Label("New Claude Session", systemImage: "plus") }
            Button {
                if let path = model.openSessions.activeProjectPath {
                    model.openSessions.newSession(agent: .codex, projectPath: path)
                }
            } label: { Label("New Codex Session", systemImage: "plus") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New session in this project (⌘T)")
    }
}

/// One tab chip: agent dot + title + activity dot + hover ✕. Active highlighted.
private struct TabChip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: SessionTab
    @State private var hovering = false

    private var isActive: Bool { model.openSessions.activeTabID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            if tab.kind == .settings {
                Image(systemName: "gearshape").font(.system(size: 11))
            } else {
                AgentBadge(agent: tab.agent, size: 12)
                ActivityDot(state: tab.activity, size: 5)
            }
            if tab.kind == .settings {
                // Fixed natural width — "Settings" must never truncate or
                // stretch with its neighbors.
                Text(displayTitle)
                    .font(.system(size: 12))
                    .fixedSize()
            } else {
                Text(displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
            closeButton
                .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.primary.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(hovering && !isActive ? 0.08 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openSessions.activate(tabID: tab.id) }
        .contextMenu { chipContextMenu }
    }

    private var displayTitle: String {
        if tab.kind == .settings { return "Settings" }
        if let sid = tab.sessionID, let name = model.overlay.customName(for: sid) { return name }
        return tab.isProvisional ? "\(tab.title) (starting…)" : tab.title
    }

    private var closeButton: some View {
        Button(action: { model.openSessions.requestClose(tabID: tab.id) }) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 14, height: 14)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close tab (⌘W)")
    }

    @ViewBuilder
    private var chipContextMenu: some View {
        if tab.kind == .session {
            Button("Copy resume command") {
                if let sid = tab.sessionID {
                    copyToPasteboard(tab.agent.resumeArgv(sessionID: sid).joined(separator: " "))
                }
            }
            Button("Copy session ID") { if let sid = tab.sessionID { copyToPasteboard(sid) } }
            Divider()
        }
        Button("Close tab") { model.openSessions.requestClose(tabID: tab.id) }
    }
}

/// Live reorder within the active project's chips (native insertion feel).
private struct TabDropDelegate: DropDelegate {
    let item: SessionTab
    let model: AppModel
    @Binding var dragging: SessionTab.ID?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != item.id else { return }
            let chips = model.openSessions.visibleTabs.filter { $0.kind == .session }
            guard let from = chips.firstIndex(where: { $0.id == dragging }),
                  let to = chips.firstIndex(where: { $0.id == item.id }) else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                model.openSessions.moveTab(fromOffsets: IndexSet(integer: from),
                                           toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragging = nil }
        return true
    }
}
