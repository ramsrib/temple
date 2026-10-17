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
    @StateObject private var sheet: RemoteSessionsSheetModel

    init(sheet: RemoteSessionsSheetModel) { _sheet = StateObject(wrappedValue: sheet) }

    private var host: String { sheet.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(RemoteCopy.sessionsOn(host))
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
        .onAppear { sheet.load() }
        .onDisappear { sheet.dismissed() }
    }

    @ViewBuilder
    private var content: some View {
        if let listing = sheet.listing {
            if !listing.checked, let reason = firstReason(listing.sessions) {
                HStack(alignment: .firstTextBaseline) {
                    Text(RemoteCopy.couldNotCheck(reason))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Try Again") { sheet.load() }
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
                            row(session, checked: listing.checked)
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

    private func row(_ session: RemoteTrackedSession, checked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The tmux session's name only matters to someone who will
                // ssh in: a tooltip, not a line.
                Text(title(session))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .help(RemoteCopy.trackedHandleHelp(session.handle))
                Spacer(minLength: 8)
                // The state in a slot of its own, so it never reads as a
                // third action beside Stop and Keep.
                Text(RemoteCopy.trackedState(session.state))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.controlFill))
                HStack(spacing: 10) {
                    if sheet.stopping.contains(session.handle) {
                        ProgressView().controlSize(.small)
                    } else if sheet.kept.contains(session.handle) {
                        Text("Kept").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        // A new Codex session Temple has not identified: no row
                        // to open it from, so it opens here (it attaches).
                        if session.sessionID == nil, session.agent == .codex, let directory = session.directory {
                            Button("Open") {
                                model.openSessions.remoteTabs.openPendingRun(handle: session.handle, host: sheet.request.host,
                                                                             directory: directory)
                                dismiss()
                            }
                        }
                        Button("Stop") { sheet.stop(session) }
                        Button("Keep") { sheet.keep(session) }
                    }
                }
                .padding(.leading, 16)
            }
            if let reason = session.leftRunning, !sheet.kept.contains(session.handle) {
                Text(RemoteCopy.leftRunningLine(host, reason: reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if case .unknown(let reason) = session.state, checked {
                Text("Temple couldn't check this session: \(RemoteCopy.trimmed(reason)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = sheet.results[session.handle] {
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

    private func title(_ session: RemoteTrackedSession) -> String {
        guard let id = session.sessionID else { return session.agent.newSessionTitle }
        return model.sessions.first(where: { $0.id == id })?.displayTitle ?? session.agent.newSessionTitle
    }
}

/// The folder sheet for a new session on a host (section 7): a path as the
/// host spells it, the host's recent folders beneath, Return to confirm.
/// The check is advisory: what it resolves is intent; the row records a
/// folder only from the pane's own `ok`.
struct RemoteFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheet: RemoteFolderSheetModel
    @FocusState private var focused: Bool

    init(sheet: RemoteFolderSheetModel) { _sheet = StateObject(wrappedValue: sheet) }

    private var host: String { sheet.host }

    private var placeholder: String {
        if let user = model.remoteHosts.record(named: host)?.user { return "/home/\(user)/Projects/… or ~/…" }
        return "~/…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(sheet.request.agent.displayName) session on \(host)")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(RemoteCopy.folderFieldLabel).font(.system(size: 12))
                // The Add host form's field: plain, on the control fill.
                TextField("", text: $sheet.path, prompt: Text(placeholder))
                    .accessibilityLabel(RemoteCopy.folderFieldLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .focused($focused)
                    .onSubmit { sheet.confirm() }
                    .onChange(of: sheet.path) { sheet.edited() }
            }
            let recent = Array(model.recentRemoteFolders(sheet.request.host).prefix(8))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent, id: \.self) { folder in
                        Button(folder) {
                            sheet.path = folder
                            sheet.confirm()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                    }
                }
            }
            status
            HStack(spacing: 8) {
                if case .unreachable = sheet.check {
                    Button("Test connection") {
                        dismiss()
                        model.openSessions.openSettings()
                    }
                    Button("Start anyway") { sheet.startAnyway() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { sheet.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheet.trimmedPath.isEmpty || sheet.check == .checking)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { focused = true }
        // Dismissed: the check is cancelled, and nothing it answers starts.
        .onDisappear { sheet.dismissed() }
    }

    @ViewBuilder
    private var status: some View {
        switch sheet.check {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking \(sheet.trimmedPath) on \(host)…")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .resolved(let resolved):
            Text(resolved).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        case .problem(let line), .unreachable(let line):
            // The one error colour of the remote sheets (the Add host form's).
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
