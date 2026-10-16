import SwiftUI
import TempleCore

/// "Sessions on <host>" (docs/designs/remote-ssh.md section 5): the sessions
/// on Temple's private server there, each with its row's title where Temple
/// has a run for it ("Not in Temple" otherwise), attached or not, Stop and
/// Keep. A session left running shows why. Nothing here, or anywhere, stops
/// a session without the user pressing Stop; Temple's server is the only
/// one asked, never the user's own tmux.
///
/// Layout as for the rest of the app's sheets (AGENTS.md): no `.fixedSize`,
/// `List` or `Form`.
struct RemoteSessionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemoteSessionsRequest

    @State private var listing: RemoteSessionListing?
    @State private var stopping: Set<String> = []
    @State private var kept: Set<String> = []
    @State private var results: [String: String] = [:]

    private var host: String { request.host.rawValue }
    private var launcher: RemoteSessionHost? { model.remoteHost(request.host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions on \(host)")
                .font(.system(size: 15, weight: .semibold))
            content
            Text("Temple lists only the sessions on its own tmux server on \(host).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch listing {
        case nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(host)…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        case .failed(let line)?:
            HStack(alignment: .firstTextBaseline) {
                Text("Couldn't reach \(host): \(RemoteCopy.trimmed(line)).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        case .noServer?, .sessions([])?:
            Text("No sessions on \(host).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .sessions(let sessions)?:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions) { session in
                        row(session)
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func row(_ session: RemoteListedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(session))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(session.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(session.attached ? "Attached" : "Detached")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if stopping.contains(session.name) {
                    ProgressView().controlSize(.small)
                } else if kept.contains(session.name) {
                    Text("Kept").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Stop") { stop(session) }
                    Button("Keep") { keep(session) }
                }
            }
            if let reason = session.leftRunning, !kept.contains(session.name) {
                Text(RemoteCopy.leftRunningLine(host, reason: reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let result = results[session.name] {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .padding(.vertical, 8)
    }

    private func title(_ session: RemoteListedSession) -> String {
        guard session.handle != nil else { return "Not in Temple" }
        guard let id = session.sessionID, let row = model.sessions.first(where: { $0.id == id }) else {
            return session.sessionID.map { "Session \($0.prefix(8))" } ?? "Not in Temple"
        }
        return row.displayTitle
    }

    private func load() async {
        listing = nil
        listing = await launcher?.listSessions() ?? .failed(RemoteCopy.notSetUp(host))
    }

    private func stop(_ session: RemoteListedSession) {
        guard let launcher else { return }
        stopping.insert(session.name)
        results[session.name] = nil
        Task { @MainActor in
            let result = await launcher.stopListed(session.name)
            stopping.remove(session.name)
            switch result {
            case .stopped:
                await load()
            case .leftRunning(let reason, let detail):
                results[session.name] = reason == .anotherClientAttached
                    ? RemoteCopy.leftRunningLine(host, reason: reason)
                    : RemoteCopy.couldNotStop(host, agent: agent(session), reason: detail ?? "the host didn't confirm the stop")
            }
        }
    }

    private func keep(_ session: RemoteListedSession) {
        if let handle = session.handle { launcher?.keep(handle) }
        kept.insert(session.name)
    }

    private func agent(_ session: RemoteListedSession) -> Agent {
        session.sessionID.flatMap { id in model.sessions.first { $0.id == id }?.agent } ?? .claude
    }
}

/// The folder sheet for a new session on a host (section 7): a path as the
/// host spells it, the host's recent folders beneath, Return to confirm.
/// The check is advisory: what it resolves is intent; the row records a
/// folder only from the pane's own `ok`.
struct RemoteFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemoteFolderRequest

    enum Check: Equatable {
        case idle, checking
        case resolved(String)
        case problem(String)
        /// The host did not answer: Start anyway or Test connection.
        case unreachable(String)
    }

    @State private var path = ""
    @State private var check: Check = .idle
    @FocusState private var focused: Bool

    private var host: String { request.host.rawValue }

    private var placeholder: String {
        if let user = model.remoteHosts.record(named: host)?.user { return "/home/\(user)/Projects/… or ~/…" }
        return "~/…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(request.agent.displayName) session on \(host)")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder on \(host)").font(.system(size: 12))
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused($focused)
                    .onSubmit(confirm)
                    .onChange(of: path) { if check != .checking { check = .idle } }
            }
            let recent = Array(model.recentRemoteFolders(request.host).prefix(8))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent, id: \.self) { folder in
                        Button(folder) {
                            path = folder
                            confirm()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                    }
                }
            }
            status
            HStack(spacing: 8) {
                if case .unreachable = check {
                    Button("Test connection") {
                        dismiss()
                        model.openSessions.openSettings()
                    }
                    Button("Start anyway") { start(trimmedPath) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPath.isEmpty || check == .checking)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var status: some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking \(trimmedPath) on \(host)…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .resolved(let resolved):
            Text(resolved).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        case .problem(let line), .unreachable(let line):
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func confirm() {
        let typed = trimmedPath
        guard !typed.isEmpty, check != .checking, let launcher = model.remoteHost(request.host) else { return }
        check = .checking
        Task { @MainActor in
            let result = await launcher.checkFolder(typed)
            guard typed == trimmedPath else { check = .idle; return }
            switch result {
            case .exists(let resolved):
                check = .resolved(resolved)
                start(resolved)
            case .missing:
                check = .problem(RemoteCopy.noFolder(typed, host: host))
            case .cannotEnter(let line):
                check = .problem("Temple can't enter \(typed) on \(host): \(RemoteCopy.trimmed(line)).")
            case .transport(let line):
                check = .unreachable("Couldn't reach \(host): \(RemoteCopy.trimmed(line)).")
            }
        }
    }

    private func start(_ folder: String) {
        guard !folder.isEmpty else { return }
        model.startRemoteSession(host: request.host, agent: request.agent, folder: folder)
    }
}
