import SwiftUI
import AppKit
import TempleCore

/// One browsable session row. Click opens/focuses (spawns); arrow-key highlight
/// is a separate state that follows the active tab (UX "Select vs. open").
struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    @State private var renaming = false
    @State private var draftName = ""
    @State private var hovering = false

    private var isHighlighted: Bool { model.highlightedID == session.id }
    private var openTab: SessionTab? { model.openSessions.openTab(forSessionID: session.id) }
    /// Only an *open* tab has activity worth a dot; a closed session shows none.
    private var activity: ActivityState? { openTab?.activity }
    private var isPinned: Bool { model.overlay.isPinned(session.id) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                AgentBadge(agent: session.agent)
                Text(model.displayTitle(session))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(openTab != nil ? Color.primary : Color.primary.opacity(0.85))
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // Item D: the relative time is hidden until the row is hovered.
                // Kept in the layout (opacity swap) so nothing jumps; it sits to
                // the left of the state dot.
                Text(RelativeTime.string(from: session.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                // Only open tabs carry a dot (running/idle/attention/exited).
                if let activity {
                    ActivityDot(state: activity)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            // Item C: selection stays distinct; hover adds a subtle fill.
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? Palette.selectionFill
                                        : (hovering ? Palette.hoverFill : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
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
        Button(openTab != nil ? "Focus" : "Open") { open() }
        Divider()
        Button("Copy resume command") {
            copyToPasteboard(session.resume.argv.joined(separator: " "))
        }
        Button("Copy session ID") { copyToPasteboard(session.id) }
        Button("Reveal session file in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([session.filePath])
        }
        Divider()
        Button("Rename…") {
            draftName = model.displayTitle(session)
            renaming = true
        }
        Button(isPinned ? "Unpin" : "Pin") { model.overlay.togglePin(session.id) }
        if let tab = openTab {
            Divider()
            Button("Close tab") { model.openSessions.closeTab(tab.id) }
        }
    }
}
