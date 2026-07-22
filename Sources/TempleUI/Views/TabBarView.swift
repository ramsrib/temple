import SwiftUI
import UniformTypeIdentifiers
import TempleCore

/// The strip's pinned left cluster: the project switcher and its divider.
/// Hosted OUTSIDE the scrolled region (TitlebarTabStrip.swift), so the project
/// control never scrolls away with the chips.
struct TabStripPinnedCluster: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // The strip shows one project at a time; this names the project the
        // chips belong to, and switches between the projects you have work
        // open in (⌘⇧[ / ⌘⇧]).
        if !model.openSessions.visibleTabs.isEmpty,
           !model.openSessions.openProjects.isEmpty {
            HStack(spacing: 3) {
                ProjectSwitcher()
                Divider().frame(height: 16).opacity(0.5)
            }
        }
    }
}

/// Cue in its own slot at one end of the chips clip: more tabs are hidden
/// past this side. Subtle at rest, highlighted on hover, and clicking steps
/// the strip one tab toward that side (the AppKit container shows/hides the
/// slot from the scroll state and owns the stepping).
struct StripOverflowCue: View {
    let edge: Edge
    let step: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: step) {
            Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 16)
                .background(.regularMaterial, in: Circle())
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: Circle())
                .overlay(Circle().strokeBorder(
                    Color.primary.opacity(hovering ? 0.25 : 0.06), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(edge == .leading ? "Previous tab into view" : "Next tab into view")
    }
}

/// Runs its closure when the drag session lets go of its item provider —
/// the only signal SwiftUI leaves for a drag that ended without a drop.
private final class DragSessionEnd {
    private let end: @MainActor () -> Void
    init(_ end: @escaping @MainActor () -> Void) { self.end = end }
    deinit {
        let end = self.end
        Task { @MainActor in end() }
    }
}

private nonisolated(unsafe) var dragSessionEndKey: UInt8 = 0

/// Chip frames in the chips row's coordinate space, for scroll-into-view.
private struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [SessionTab.ID: CGRect] { [:] }
    static func reduce(value: inout [SessionTab.ID: CGRect],
                       nextValue: () -> [SessionTab.ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The strip's pinned right cluster: the `+` new-session menu. Hosted OUTSIDE
/// the scrolled region (TitlebarTabStrip.swift), so `+` sits at the window's
/// right corner and stays reachable no matter how far the chips scroll.
struct TabStripTrailingCluster: View {
    @EnvironmentObject var model: AppModel

    @State private var hovering = false

    var body: some View {
        if !model.openSessions.visibleTabs.isEmpty {
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
            // On the Menu, not inside its label: the borderless button
            // snapshots the label view, so state changes there never repaint.
            .background(Color.primary.opacity(hovering ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .help("New session in this project (⌘T)")
        }
    }
}

/// The scrolled part of the tab strip (Item A): the active project's open
/// terminals, plus the project-agnostic Settings tab.
/// Content-sized — the hosting TabStripContainerView clips it and owns the
/// scroll offset. Chips are drag-reorderable. Activating a tab reports its
/// frame back to the container so off-screen chips are scrolled into view.
struct TabStripChipsRow: View {
    @EnvironmentObject var model: AppModel
    /// Asks the AppKit container to scroll this rect (row coords) into view.
    let reveal: (CGRect) -> Void
    /// Hands the container every chip frame (row coords, left-to-right) so
    /// the overflow cues can step exactly one tab per click.
    let framesChanged: ([CGRect]) -> Void

    @State private var dragging: SessionTab.ID?
    @State private var frames: [SessionTab.ID: CGRect] = [:]
    @State private var pendingReveal: SessionTab.ID?

    var body: some View {
        // A content-sized HStack (no Spacer / no greedy ScrollView). The
        // Settings chip renders inline in the row like any other chip (at
        // its user-controlled offset), so it drag-reorders alongside sessions.
        // One snapshot feeds BOTH the ForEach and the tick lookups below:
        // re-reading visibleTabs inside the loop indexes a possibly newer
        // array with this iteration's index — out of bounds the moment a
        // close or reorder lands mid-reconciliation.
        let visible = model.openSessions.visibleTabs
        let activeID = model.openSessions.activeTabID
        HStack(spacing: 2) {
            ForEach(Array(visible.enumerated()),
                    id: \.element.id) { index, tab in
                // A hairline tick marks the boundary between adjacent tabs —
                // full-height chips carry no outline of their own. Beside the
                // active tab it goes invisible, not absent: its fill marks that
                // boundary already, and removing the tick would change the row's
                // width — which must never depend on which tab is active.
                if index > 0 {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 16)
                        .opacity(tab.id != activeID && visible[index - 1].id != activeID
                                 ? 1 : 0)
                }
                TabChip(tab: tab)
                    // The dimmed slot is the drop indicator: it travels with
                    // the live reorder, showing exactly where release lands.
                    .opacity(dragging == tab.id ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.15), value: dragging)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ChipFramesKey.self,
                                               value: [tab.id: geo.frame(in: .named("temple.chipsRow"))])
                    })
                    .onDrag {
                        dragging = tab.id
                        let provider = NSItemProvider(object: tab.id.uuidString as NSString)
                        // A cancelled drag (released outside the strip) gets
                        // no SwiftUI callback; the session releasing its item
                        // provider is the only end-of-drag signal, so the
                        // un-dim rides on the provider's lifetime.
                        objc_setAssociatedObject(
                            provider, &dragSessionEndKey,
                            DragSessionEnd { dragging = nil },
                            .OBJC_ASSOCIATION_RETAIN)
                        return provider
                    } preview: {
                        // Without an explicit preview the system snapshots the
                        // chip as rendered — and an inactive chip's fill is
                        // clear, so only the bare title text appears to drag.
                        TabChipDragPreview(
                            tab: tab,
                            title: TabChip.displayTitle(for: tab, model: model),
                            mark: tab.sessionID.flatMap { sid in
                                model.overlay.color(for: sid).flatMap {
                                    TabColorMark(rawValue: $0)?.color
                                }
                            })
                    }
            }
        }
        .coordinateSpace(name: "temple.chipsRow")
        .onDrop(of: [.text], delegate: TabRowReorderDelegate(
            model: model,
            dragging: $dragging,
            chipMidpoints: {
                frames.map { (id: $0.key, midX: $0.value.midX) }
                    .sorted { $0.midX < $1.midX }
            },
            reveal: reveal
        ))
        .onPreferenceChange(ChipFramesKey.self) { new in
            frames = new
            framesChanged(new.values.sorted { $0.minX < $1.minX })
            flushReveal()
        }
        .onChange(of: model.openSessions.activeTabID) { _, id in
            pendingReveal = id
            flushReveal()
        }
        .onAppear {
            pendingReveal = model.openSessions.activeTabID
            flushReveal()
        }
    }

    /// Reveal waits until the activated chip has a reported frame — a brand-new
    /// tab's chip only gets one after the next layout pass.
    private func flushReveal() {
        guard let id = pendingReveal, let rect = frames[id], rect.width > 0 else { return }
        pendingReveal = nil
        reveal(rect)
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
            // Full height, like the chips: the hover fill claims the band.
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(hovering || presented ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Horizontal only: full .fixedSize() would also collapse the height
        // back to the text's ideal, defeating the full-band hover/click area.
        .fixedSize(horizontal: true, vertical: false)
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
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    /// Every session chip is exactly this wide (browser-style). The title is
    /// live — Claude rewrites it continuously while working — so any width
    /// that derives from the text turns title updates into row-wide layout
    /// shifts. Sized so ~20 characters of title survive after the badge, dot
    /// slot, and close button take their share.
    static let sessionWidth: CGFloat = 200

    private var isActive: Bool { model.openSessions.activeTabID == tab.id }
    private var colorMark: TabColorMark? {
        tab.sessionID
            .flatMap { model.overlay.color(for: $0) }
            .flatMap(TabColorMark.init(rawValue:))
    }

    var body: some View {
        HStack(spacing: 6) {
            if tab.kind == .settings {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary)
                                              : AnyShapeStyle(.secondary))
            } else {
                // Quieter when the tab is at rest: a row of tabs repeats this
                // mark once per chip, and at full strength the repetition is
                // louder than the titles it sits beside.
                AgentBadge(agent: tab.agent, size: 12)
                    .opacity(isActive || hovering ? 1 : 0.75)
                // Being open is what a chip already means — the dot paints only
                // when it has something to say (running / attention). Its slot is
                // permanent: inserting it on state change resized the chip, and
                // any width change moves every chip to the right of it.
                ActivityDot(state: tab.activity, size: 5)
                    .opacity(tab.activity == .idle ? 0 : 1)
            }
            if tab.kind == .settings {
                // Fixed natural width — "Settings" must never truncate or
                // stretch with its neighbors. And CONSTANT weight: this chip
                // is its text's size, so the active medium weight the session
                // chips get would widen the row ~2pt on activation — the very
                // state-dependent width 5134ecb removed. Ink, fill, and seat
                // carry its active state instead.
                Text(displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? AnyShapeStyle(.primary)
                                              : AnyShapeStyle(.secondary))
                    .fixedSize()
            } else {
                // Active reads first: weight + full-strength ink against the
                // secondary ink of resting tabs. The fill alone was the only
                // difference, and a flat gray slab is a weak signal.
                if editing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .focused($editFocused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: editFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !editing {
                closeButton
                    .opacity(hovering || isActive ? 1 : 0)
            }
        }
        .padding(.horizontal, 9)
        // Constant width for session chips: inside a fixed box a title change
        // repaints text but can never move the strip. Settings keeps its
        // natural size — its title is a constant.
        .frame(width: tab.kind == .settings ? nil : Self.sessionWidth)
        // Full-height: the container stretches the chips row to the band (the
        // band's height is fixed by the sidebar header), so the chip claims
        // all of it instead of floating in dead air.
        .frame(maxHeight: .infinity)
        .background { chipBackground }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Activate on the FIRST click, not after a double-click timeout: two
        // stacked onTapGestures make SwiftUI hold the single tap back while
        // it waits to rule out a double, and tab switching visibly lags the
        // keyboard shortcuts. Simultaneous recognition fires the single tap
        // immediately; a second click then also lands rename — activating
        // the tab you are about to rename is correct anyway.
        .onTapGesture { model.openSessions.activate(tabID: tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() })
        .contextMenu { chipContextMenu }
    }

    private var displayTitle: String { Self.displayTitle(for: tab, model: model) }

    static func displayTitle(for tab: SessionTab, model: AppModel) -> String {
        if tab.kind == .settings { return "Settings" }
        if let sid = tab.sessionID, let name = model.overlay.customName(for: sid) { return name }
        return tab.isProvisional ? "\(tab.title) (starting…)" : tab.title
    }

    private func beginRename() {
        guard tab.kind == .session, !editing, tab.sessionID != nil else { return }
        draft = displayTitle
        editing = true
        FieldFocus.claim { editFocused = true }
    }

    private func commitRename() {
        guard editing, let sid = tab.sessionID else { return }
        model.overlay.rename(sid, to: draft)
        editing = false
        model.openSessions.focusActiveTerminal()
    }

    private func cancelRename() {
        guard editing else { return }
        editing = false
        model.openSessions.focusActiveTerminal()
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
            Button("Rename…") { beginRename() }
                .disabled(tab.sessionID == nil)
            Menu("Color") {
                ForEach(TabColorMark.allCases) { mark in
                    Button {
                        if let sid = tab.sessionID {
                            model.overlay.setColor(mark.rawValue, for: sid)
                        }
                    } label: {
                        Label {
                            Text(mark.label)
                        } icon: {
                            Image(nsImage: mark.menuSwatch(selected: colorMark == mark))
                        }
                    }
                }
                Divider()
                Button("None") {
                    if let sid = tab.sessionID { model.overlay.setColor(nil, for: sid) }
                }
            }
            .disabled(tab.sessionID == nil)
            Divider()
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

    @ViewBuilder
    private var chipBackground: some View {
        if let mark = colorMark?.color {
            // Same grammar as uncolored chips: the border belongs to the
            // ACTIVE state only. A resting mark is a quiet wash of color —
            // give it a border and every marked tab reads as selected.
            RoundedRectangle(cornerRadius: 6)
                .fill(mark.opacity(isActive ? 0.26 : (hovering ? 0.12 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(mark.opacity(isActive ? 0.55 : 0), lineWidth: 1))
        } else {
            // No outline: boundaries come from the ticks between chips, and
            // the active/hover fills mark the tab itself (browser-tab style).
            // Lighter than it was: weight and ink now say "active", so the
            // fill only has to seat the tab, not shout it.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(
                    isActive ? 0.09 : (hovering ? 0.05 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Palette.hairline.opacity(isActive ? 1 : 0),
                                  lineWidth: 1))
        }
    }
}

/// What travels with the cursor during a chip drag: the whole chip — badge,
/// activity dot, title — on an opaque rounded fill, so the drag reads as
/// moving the tab, not its text. Rendered standalone (no environment), so the
/// resolved title is passed in.
private struct TabChipDragPreview: View {
    let tab: SessionTab
    let title: String
    let mark: Color?

    var body: some View {
        HStack(spacing: 6) {
            if tab.kind == .settings {
                Image(systemName: "gearshape").font(.system(size: 11))
            } else {
                AgentBadge(agent: tab.agent, size: 12)
                if tab.activity != .idle {
                    ActivityDot(state: tab.activity, size: 5)
                }
            }
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        // Match the chip's fixed footprint so the drag reads as lifting the
        // tab itself, not a reflowed copy of it.
        .frame(width: tab.kind == .settings ? nil : TabChip.sessionWidth)
        .padding(.vertical, 8)
        .background { previewBackground }
        .overlay { previewBorder }
    }

    @ViewBuilder
    private var previewBackground: some View {
        // The active-chip look, made self-sufficient: the strip's band
        // isn't underneath the preview, so it gets its own opaque base.
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 7)
                .fill(mark?.opacity(0.22) ?? Color.primary.opacity(0.12))
        }
    }

    @ViewBuilder
    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(mark?.opacity(0.55) ?? Color.primary.opacity(0.15), lineWidth: 1)
    }
}

enum TabReorderMath {
    /// Where a drag at `x` should insert, or nil when the row is already right.
    /// Midpoint rule: you take a chip's slot only once you're past its middle —
    /// which is also what makes the result stable under repeated ticks.
    static func insertionOffset(x: CGFloat, midXs: [CGFloat], from: Int) -> Int? {
        let insertion = midXs.firstIndex(where: { x < $0 }) ?? midXs.count
        return (insertion == from || insertion == from + 1) ? nil : insertion
    }
}

/// Level-triggered live reorder across the active project's entire chips row.
private struct TabRowReorderDelegate: DropDelegate {
    let model: AppModel
    @Binding var dragging: SessionTab.ID?
    let chipMidpoints: () -> [(id: SessionTab.ID, midX: CGFloat)]
    /// Scrolls a row-coordinate rect into the strip's visible clip. The strip
    /// shows a window onto the row, and without this a drag stalls at the
    /// visible edge — a tab could never travel past the chips on screen.
    let reveal: (CGRect) -> Void

    private func reorder(to x: CGFloat) {
        MainActor.assumeIsolated {
            guard let dragging else { return }
            // Keep the neighborhood of the cursor visible: pushing against
            // either edge of the clip creeps the strip in that direction, so
            // long moves (position 0 → 6 across an overflowing row) work in
            // one gesture. reveal() no-ops while the rect is already visible.
            reveal(CGRect(x: x - 60, y: 0, width: 120, height: 1))
            let row = model.openSessions.visibleTabs
            let midpoints = chipMidpoints()
            // Geometry preferences can trail a close or reorder by one layout
            // tick. Only act on a snapshot that describes this exact row.
            guard midpoints.count == row.count,
                  zip(midpoints, row).allSatisfy({ $0.0.id == $0.1.id }),
                  let from = row.firstIndex(where: { $0.id == dragging }),
                  let to = TabReorderMath.insertionOffset(
                    x: x, midXs: midpoints.map(\.midX), from: from)
            else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                model.openSessions.moveTab(fromOffsets: IndexSet(integer: from),
                                           toOffset: to)
            }
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragging != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        reorder(to: info.location.x)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        reorder(to: info.location.x)
        MainActor.assumeIsolated { dragging = nil }
        return true
    }
}
