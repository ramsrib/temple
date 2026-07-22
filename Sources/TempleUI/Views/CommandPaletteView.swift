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

    private func openCount(in results: [AgentSession]) -> Int {
        let open = Set(model.openSessions.openSessionIDsInTabOrder)
        return results.prefix { open.contains($0.id) }.count
    }

    var body: some View {
        // One ranking pass per render: the palette re-renders on every title
        // tick while it's open, and paletteResults sorts the whole index.
        let results = self.results
        let openCount = openCount(in: results)
        let showsRecentHeader = query.trimmingCharacters(in: .whitespaces).isEmpty
            && openCount > 0
            && openCount < results.count
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
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "No sessions yet" : "No matches")
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
                                if showsRecentHeader && idx == openCount {
                                    HStack(spacing: 12) {
                                        Text("RECENT")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .tracking(1.3)
                                            .foregroundStyle(.secondary)
                                        Rectangle().fill(Palette.hairline).frame(height: 1)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: Self.sectionHeaderHeight)
                                }
                                PaletteResultRow(session: session,
                                                 selected: idx == selection) {
                                    selection = idx
                                    openSelected()
                                }
                                .frame(height: Self.rowHeight)
                            }
                        }
                    }
                    // Hug the rows (a ScrollView greedily fills its proposal,
                    // leaving dead space under short result lists); scroll
                    // only past the cap.
                    .frame(height: min(
                        CGFloat(results.count) * Self.rowHeight
                            + (showsRecentHeader ? Self.sectionHeaderHeight : 0),
                        340
                    ))
                    .thinScrollers()
                    .onChange(of: selection) {
                        if results.indices.contains(selection) {
                            proxy.scrollTo(results[selection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .panelChrome()
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
    private static let sectionHeaderHeight: CGFloat = 25

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

/// One palette result. Hover shows its own subtle fill without moving the
/// keyboard selection — the pointer resting on a row must never change what
/// Return opens mid-typing.
private struct PaletteResultRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let selected: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
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
            Text(RelativeTime.string(from: session.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Palette.selectionFill
                             : (hovering ? Palette.hoverFill : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}
