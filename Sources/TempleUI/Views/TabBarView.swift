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

    var body: some View {
        // A content-sized HStack (no Spacer / no greedy ScrollView): only the
        // chips occupy the band; everything to their right is native titlebar.
        // The Settings chip renders inline in the row like any other chip (at
        // its user-controlled offset), so it drag-reorders alongside sessions.
        HStack(spacing: 6) {
            // The strip shows one project at a time; this names the project the
            // chips belong to, and switches between the projects you have work
            // open in (⌘⇧[ / ⌘⇧]).
            if !model.openSessions.openProjects.isEmpty {
                ProjectSwitcher()
                Divider().frame(height: 16).opacity(0.5)
            }
            ForEach(model.openSessions.visibleTabs) { tab in
                TabChip(tab: tab)
                    .onDrag {
                        dragging = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text],
                            delegate: TabDropDelegate(item: tab, model: model, dragging: $dragging))
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

/// The project the tab strip is currently showing, and a picker for the other
/// projects you have sessions open in. Picking one returns you to the session you
/// were last on there.
///
/// A popover rather than an NSMenu: a menu row is one string, which forces the
/// session count to collide with the project name and leaves no room for the
/// containing folder — and without that folder, worktrees of one repo all read as
/// the same project.
private struct ProjectSwitcher: View {
    @EnvironmentObject var model: AppModel
    @State private var presented = false
    @State private var hovering = false
    @State private var openHovering = false

    private var active: String? { model.openSessions.activeProjectPath }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(active.map(model.projectName) ?? "Projects")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering || presented ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Switch project (⌘⇧[ / ⌘⇧])")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.openSessions.openProjects, id: \.self) { path in
                    ProjectSwitcherRow(path: path, isCurrent: path == active) {
                        model.openSessions.activateProject(path)
                        presented = false
                    }
                }
                Divider().padding(.vertical, 4)
                // Adding a PROJECT, not a session — hence the folder, not the bare
                // `+` that starts a session in a project you already have.
                Button {
                    presented = false
                    chooseProjectFolder { path in
                        model.openSessions.newSessionDefaultAgent(projectPath: path)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("Open project…")
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(openHovering ? Palette.hoverFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { openHovering = $0 }

                HStack(spacing: 6) {
                    Text("⌘P")
                    Text("switch project")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                    Text("⌘⇧[ ⌘⇧]")
                        .foregroundStyle(.quaternary)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)
            }
            .padding(6)
            .frame(width: 268)
            // The popover holds the window's first responder while it is up, and
            // AppKit does not hand it back on dismissal — so focusing the new
            // project's terminal has to wait until the popover is actually gone,
            // or you land in a session that ignores your typing (same trap as ⌘K).
            .onDisappear {
                DispatchQueue.main.async { model.openSessions.focusActiveTerminal() }
            }
        }
    }
}

/// One project in the switcher: name over its containing folder, the number of
/// sessions open there, and a dot if any of them is running or wants you.
private struct ProjectSwitcherRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let isCurrent: Bool
    let select: () -> Void

    @State private var hovering = false

    /// Tabs open in this project — the switcher only ever lists projects with some.
    private var tabs: [SessionTab] {
        model.openSessions.tabs.filter { $0.kind == .session && $0.projectPath == path }
    }

    /// The loudest state among them: someone waiting on you outranks someone working.
    private var activity: ActivityState? {
        let states = tabs.map(\.activity)
        if states.contains(.needsAttention) { return .needsAttention }
        if states.contains(.running) { return .running }
        return nil
    }

    /// The folder the project sits in — what tells two worktrees of one repo apart.
    private var parent: String {
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        let folder = (tilde as NSString).deletingLastPathComponent
        return folder.isEmpty ? tilde : folder
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectName(path))
                        .font(.system(size: 13, weight: isCurrent ? .medium : .regular))
                        .lineLimit(1)
                    Text(parent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                if let activity { ActivityDot(state: activity, size: 5) }
                Text("\(tabs.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Palette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
            let row = model.openSessions.visibleTabs
            guard let from = row.firstIndex(where: { $0.id == dragging }),
                  let to = row.firstIndex(where: { $0.id == item.id }) else { return }
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
