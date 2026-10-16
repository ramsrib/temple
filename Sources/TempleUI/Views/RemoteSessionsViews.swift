import SwiftUI
import TempleCore

/// "Sessions on <host>" (docs/designs/remote-ssh.md section 5): the
/// sessions Temple started there and still tracks, each with its row's
/// title, each asked about on its own pinned server: attached or not, with
/// Stop and Keep, and why it was left running when it was. Nothing is
/// discovered and nothing Temple did not start is listed or stopped; a
/// session Temple can't check stays, saying so.
///
/// Layout as for the rest of the app's sheets (AGENTS.md): no `.fixedSize`,
/// `List` or `Form`.
struct RemoteSessionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: RemoteSessionsRequest

    @State private var listing: (sessions: [RemoteTrackedSession], checked: Bool)?
    @State private var stopping: Set<String> = []
    @State private var kept: Set<String> = []
    @State private var results: [String: String] = [:]
    @State private var loading: Task<Void, Never>?

    private var host: String { request.host.rawValue }
    private var launcher: RemoteSessionHost? { model.remoteHost(request.host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions on \(host)")
                .font(.system(size: 15, weight: .semibold))
            content
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { load() }
        .onDisappear { loading?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if let listing {
            if !listing.checked, let reason = firstReason(listing.sessions) {
                HStack(alignment: .firstTextBaseline) {
                    Text(RemoteCopy.couldNotCheck(reason))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try Again") { load() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            if listing.sessions.isEmpty {
                Text(RemoteCopy.noTrackedSessions)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(listing.sessions) { session in
                            row(session)
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(host)…").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private func firstReason(_ sessions: [RemoteTrackedSession]) -> String? {
        for session in sessions { if case .unknown(let reason) = session.state { return reason } }
        return nil
    }

    private func row(_ session: RemoteTrackedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(session))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text("temple-\(session.handle)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(status(session))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if stopping.contains(session.handle) {
                    ProgressView().controlSize(.small)
                } else if kept.contains(session.handle) {
                    Text("Kept").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Stop") { stop(session) }
                    Button("Keep") { keep(session) }
                }
            }
            if let reason = session.leftRunning, !kept.contains(session.handle) {
                Text(RemoteCopy.leftRunningLine(host, reason: reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if case .unknown(let reason) = session.state, listing?.checked == true {
                Text("Temple couldn't check this session: \(RemoteCopy.trimmed(reason)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = results[session.handle] {
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

    private func status(_ session: RemoteTrackedSession) -> String {
        switch session.state {
        case .present(let attached): attached ? "Attached" : "Detached"
        case .unknown: "Unknown"
        }
    }

    private func title(_ session: RemoteTrackedSession) -> String {
        guard let id = session.sessionID else { return session.agent.newSessionTitle }
        return model.sessions.first(where: { $0.id == id })?.displayTitle ?? session.agent.newSessionTitle
    }

    private func load() {
        loading?.cancel()
        guard let launcher else {
            listing = ([], false)
            return
        }
        listing = nil
        loading = Task { @MainActor in
            let answer = await launcher.trackedSessions()
            guard !Task.isCancelled else { return }
            listing = answer
        }
    }

    private func stop(_ session: RemoteTrackedSession) {
        let host = request.host
        stopping.insert(session.handle)
        results[session.handle] = nil
        // The stop survives the sheet: the app owns it until its outcome is written.
        model.openSessions.stopTracked(handle: session.handle, host: host, agent: session.agent) { result in
            stopping.remove(session.handle)
            switch result {
            case .stopped:
                load()
            case .leftRunning(let reason, let detail):
                results[session.handle] = reason == .anotherClientAttached
                    ? RemoteCopy.leftRunningLine(self.host, reason: reason)
                    : RemoteCopy.couldNotStop(self.host, agent: session.agent, reason: detail ?? "the host didn't confirm the stop")
            case .unrecorded(let detail):
                results[session.handle] = RemoteCopy.unrecorded(self.host, detail: detail)
            }
        }
    }

    private func keep(_ session: RemoteTrackedSession) {
        if let launcher {
            model.openSessions.remoteOperations.run(host: request.host, .write) { await launcher.keep(session.handle) }
        }
        kept.insert(session.handle)
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
    @State private var checking: Task<Void, Never>?
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
        // Dismissed: the check is cancelled, and nothing it answers starts.
        .onDisappear { checking?.cancel() }
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
        checking?.cancel()
        checking = Task { @MainActor in
            let result = await launcher.checkFolder(typed)
            guard !Task.isCancelled, model.remoteFolderSheet?.id == request.id else { return }
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
                check = .unreachable("Temple couldn't check this folder on \(host): \(RemoteCopy.trimmed(line)).")
            }
        }
    }

    private func start(_ folder: String) {
        guard !folder.isEmpty, model.remoteFolderSheet?.id == request.id else { return }
        model.startRemoteSession(host: request.host, agent: request.agent, folder: folder)
    }
}
