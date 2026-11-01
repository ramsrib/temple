import SwiftUI
import TempleCore

/// Open a session by id (docs/designs/open-existing-sessions.md section 5),
/// in the remote sheets' chrome: host and id, then Open. The agent and the
/// folder are asked only when Temple can't find them out.
struct OpenByIDSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheet: OpenByIDSheetModel
    @FocusState private var focus: Field?

    private enum Field { case id, folder }

    init(sheet: OpenByIDSheetModel) { _sheet = StateObject(wrappedValue: sheet) }

    var body: some View {
        RemoteSheetChrome {
            RemoteSheetTitle(title: "Open a session by id")
            RemoteFormRow(label: "Host") {
                Picker("", selection: $sheet.host) {
                    ForEach(sheet.hosts, id: \.self) { host in
                        Text(host.isLocal ? "This Mac" : host.displayName).tag(host)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }
            RemoteFormRow(label: "Session id") {
                TextField("", text: $sheet.sessionID, prompt: Text("3f2a1c7e-…"))
                    .accessibilityLabel("Session id")
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focus, equals: .id)
                    .onSubmit { sheet.confirm() }
                    .templeFieldChrome(focused: focus == .id)
                RemoteHint("The id from claude --resume or codex resume, or a session's Copy session ID.")
            }
            if sheet.showsAgent {
                RemoteFormRow(label: "Agent") {
                    Picker("", selection: $sheet.agent) {
                        ForEach(Agent.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(Agent?.some(agent))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260, alignment: .leading)
                    RemoteHint("This id is both a Claude Code and a Codex session on \(hostName). Choose which to open.")
                }
            }
            if sheet.showsFolder {
                RemoteFormRow(label: "Folder") {
                    TextField("", text: $sheet.folder, prompt: Text("~/…"))
                        .accessibilityLabel("Folder")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focus, equals: .folder)
                        .onSubmit { sheet.confirm() }
                        .templeFieldChrome(focused: focus == .folder)
                    RemoteHint("This session didn't record its folder. Enter the folder it ran in on \(hostName).")
                    let recent = Array(sheet.recentFolders.prefix(6))
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(recent, id: \.self) { folder in
                                RemoteListRow(action: { sheet.folder = folder }) {
                                    Text(folder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
            }
            status
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if case .elsewhere = sheet.check {
                    // The one session this id is: its own host's, opened as it is.
                    Button("Open it") { sheet.openElsewhere() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open") { sheet.confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!sheet.canOpen)
                }
            }
            .padding(.top, 8)
        }
        .onAppear { focus = sheet.sessionID.isEmpty ? .id : nil }
        .onChange(of: sheet.showsFolder) { if sheet.showsFolder { focus = .folder } }
        // Dismissed: the check is cancelled, and nothing it answers opens.
        .onDisappear { sheet.dismissed() }
    }

    private var hostName: String { sheet.host.isLocal ? "this Mac" : sheet.host.displayName }

    @ViewBuilder
    private var status: some View {
        switch sheet.check {
        case .idle, .chooseAgent, .needsFolder:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for this session on \(hostName)…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .elsewhere(let other):
            RemoteProblem("Temple here already has this session, on \(other.isLocal ? "this Mac" : other.displayName). Open it to continue it there.", color: .orange)
        case .problem(let line), .unreachable(let line):
            RemoteProblem(line)
        }
    }
}
