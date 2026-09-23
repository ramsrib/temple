import SwiftUI
import AppKit
import TempleCore

/// One browsable session row. Click opens/focuses (spawns); arrow-key highlight
/// is a separate state that follows the active tab (UX "Select vs. open").
struct SessionRow: View {
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    @State private var renaming = false
    @State private var draftName = ""
    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    /// Mouse tracking fires by rect through a floating panel (⌘K etc.);
    /// never render a hover that happens under one.
    private var hovering: Bool { rawHovering && !overlayActive }

    private var isHighlighted: Bool { model.highlightedID == session.id }
    private var openTab: SessionTab? { model.openSessions.openTab(forSessionID: session.id) }
    /// Only an *open* tab has activity worth a dot; a closed session shows none.
    private var activity: ActivityState? { openTab?.activity }
    private var isPinned: Bool { model.overlay.isPinned(session.id) }
    private var colorMark: Color? {
        model.overlay.color(for: session.id).flatMap {
            TabColorMark(rawValue: $0)?.color
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                // The mark stays on every row, in colour: it is often the only
                // thing that says which agent a session ran under, and the
                // colour is what gives a dense list its rhythm (Finder's
                // sidebar works the same way). Full strength only where the
                // session is open or under the pointer, so open tabs stand out.
                AgentBadge(agent: session.agent, size: 13)
                    .opacity(openTab != nil || hovering ? 1 : 0.55)
                Text(model.displayTitle(session))
                    // Medium on the highlighted row — the same "you are here"
                    // weight the active tab chip carries.
                    .font(.system(size: 13, weight: isHighlighted ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Two tones, not one: the sessions you have open are the
                    // ones you are working in, and they read at full strength;
                    // the browsable history behind them steps back — but only
                    // a step. Closed rows are most of the rail, and at 72% they
                    // went mid-grey in dark mode; the open rows' surface pill
                    // carries the rest of the distinction.
                    .foregroundStyle(openTab != nil || hovering ? Color.primary : Color.primary.opacity(0.82))
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // Only open tabs carry a dot (running/idle/attention/exited).
                if let activity {
                    ActivityDot(state: activity)
                }
            }
            // The 32pt frame below sets the pitch; the pill runs the row's
            // full height so hover and selection read as one soft shape.
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            // Item C: selection stays distinct; hover adds a subtle fill. The
            // hairline seat matches the active tab chip — one selection
            // language across the strip and the rail.
            // Only the highlighted row gets a fill at rest. Open tabs used to
            // sit on a faint surface too, and in dark mode four open sessions
            // read as four selections; their full-strength title and activity
            // dot already say "open".
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Palette.selectionFill
                          : hovering ? Palette.hoverFill
                          : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.hairline.opacity(isHighlighted ? 1 : 0))))
            // The pill fades in and out rather than snapping: hover across a
            // dense list should feel like light passing over it.
            .animation(.easeOut(duration: 0.12), value: hovering)
            .overlay(alignment: .leading) {
                if let colorMark {
                    Capsule()
                        .fill(colorMark)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { rawHovering = $0 }
        .frame(height: 32)
        .contextMenu { contextMenu }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") { model.overlay.rename(session.id, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func open() {
        model.highlightedID = session.id
        model.openSessions.openSession(session)
    }

    @ViewBuilder
    private var contextMenu: some View {
        // Same shape as the tab chip's menu (rename/pin → copies/reveal →
        // close → color row), so the two right-clicks read as one menu. Only
        // archive is exclusive to this one: a chip is by definition open, and
        // an open session is not something you have put away.
        Button(openTab != nil ? "Focus" : "Open") { open() }
        Divider()
        Button("Rename session") {
            draftName = model.displayTitle(session)
            renaming = true
        }
        Button(isPinned ? "Unpin" : "Pin") { model.overlay.togglePin(session.id) }
        if openTab != nil {
            // Named rather than merely greyed out, so the menu says what to do
            // about it — the row would otherwise vanish from under its own tab.
            Button("Close tab to archive") {}
                .disabled(true)
        } else {
            Button("Archive session") { model.archiveSession(session.id, undoManager: undoManager) }
        }
        Divider()
        Button("Copy resume command") {
            copyToPasteboard(session.resume.argv.joined(separator: " "))
        }
        Button("Copy session ID") { copyToPasteboard(session.id) }
        Button("Reveal session file in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.filePath])
        }
        if let tab = openTab {
            Divider()
            Button("Close tab") { model.openSessions.closeTab(tab.id) }
        }
        Divider()
        Picker("", selection: Binding(
            get: { model.overlay.color(for: session.id).flatMap(TabColorMark.init(rawValue:)) },
            set: { model.overlay.setColor($0?.rawValue, for: session.id) }
        )) {
            Image(systemName: "slash.circle")
                .tag(TabColorMark?.none)
                .help("No color")
            ForEach(TabColorMark.allCases) { mark in
                Image(systemName: "circle.fill")
                    .tint(mark.color)
                    .tag(TabColorMark?.some(mark))
                    .help(mark.label)
            }
        }
        .pickerStyle(.palette)
        .controlSize(.small)
    }
}
