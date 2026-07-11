import SwiftUI
import TempleCore

/// ⌘K global quick-open (U8): ranked title match over the whole index. Enter
/// opens/focuses the session's tab (switching active project).
struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var results: [AgentSession] {
        Array(model.paletteResults(query).prefix(40))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onChange(of: query) { selection = 0 }
                if !query.isEmpty {
                    Button {
                        query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text(query.isEmpty ? "No open sessions — type to search all" : "No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // A plain VStack (≤40 cheap rows): LazyVStack left
                        // already-materialized rows with a stale `selected`
                        // highlight when arrowing (two rows lit at once).
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, session in
                                resultRow(session, selected: idx == selection)
                                    .frame(height: Self.rowHeight)
                                    .onTapGesture { selection = idx; openSelected() }
                            }
                        }
                    }
                    // Hug the rows (a ScrollView greedily fills its proposal,
                    // leaving dead space under short result lists); scroll
                    // only past the cap.
                    .frame(height: min(CGFloat(results.count) * Self.rowHeight, 340))
                    .onChange(of: selection) {
                        if results.indices.contains(selection) {
                            proxy.scrollTo(results[selection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 30, y: 10)
        // The terminal (a raw AppKit view) holds the window's first responder and
        // SwiftUI focus can't take it — so ⌘K used to open a field that never
        // received a keystroke, while everything typed went to the agent.
        .onAppear { FieldFocus.claim { fieldFocused = true } }
        // Closing hands the keyboard back to the agent we took it from.
        .onDisappear { model.openSessions.focusActiveTerminal() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { model.commandPalettePresented = false; return .handled }
    }

    /// Fixed row height so the list height is exact (two text lines + padding).
    private static let rowHeight: CGFloat = 46

    private func resultRow(_ session: AgentSession, selected: Bool) -> some View {
        HStack(spacing: 10) {
            AgentBadge(agent: session.agent, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayTitle(session))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(model.projectName(session.projectPath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Palette.selectionFill : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        model.openSessions.openSession(results[selection])
        model.commandPalettePresented = false
    }
}
