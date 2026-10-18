import SwiftUI
import TempleCore

/// "Running sessions on <host>" (docs/designs/remote-ssh.md section 5):
/// the sessions Temple started there and still tracks, each with its row's
/// title and its state (Running, Running in a tab, Status unknown); Open
/// (or Show tab, for one open in a tab here) and Stop on every row, and
/// Dismiss on a row with a left-running note. Nothing is discovered and
/// nothing Temple did not start is listed or stopped; a session Temple
/// can't check stays, saying so. Stopping a working agent asks first.
///
/// Layout as for the rest of the app's sheets (AGENTS.md): no `.fixedSize`,
/// `List` or `Form`.
struct RemoteSessionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheet: RemoteSessionsSheetModel
    /// A Stop of a working agent, waiting for its answer (S12).
    @State private var confirmingStop: RemoteTrackedSession?

    init(sheet: RemoteSessionsSheetModel) { _sheet = StateObject(wrappedValue: sheet) }

    private var host: String { sheet.host }

    var body: some View {
        RemoteSheetChrome {
            RemoteSheetTitle(title: RemoteCopy.sessionsOn(host))
            content
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .onAppear { sheet.load() }
        .onDisappear { sheet.dismissed() }
        .alert(confirmingStop.map { stopQuestion($0).title } ?? "",
               isPresented: Binding(get: { confirmingStop != nil }, set: { if !$0 { confirmingStop = nil } })) {
            // Cancel is the default; Stop ends the agent.
            Button("Stop", role: .destructive) {
                if let session = confirmingStop { sheet.stop(session) }
                confirmingStop = nil
            }
            Button("Cancel", role: .cancel) { confirmingStop = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            if let session = confirmingStop { Text(stopQuestion(session).message) }
        }
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
                    Button(RemoteCopy.tryAgain) { sheet.load() }
                        .buttonStyle(.neutralLink)
                        .font(.system(size: 11))
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

    private func stopQuestion(_ session: RemoteTrackedSession) -> (title: String, message: String) {
        model.openSessions.remoteTabs.stopQuestion(host: sheet.request.host, agent: session.agent,
                                                   title: model.trackedTitle(session), handle: session.handle,
                                                   resumable: model.canResumeLater(session.sessionID))
    }

    /// Open here: a live tab of the run in this Temple ("Running in a tab").
    private func isInTab(_ session: RemoteTrackedSession) -> Bool {
        model.openSessions.remoteTabs.hasLiveTab(handle: session.handle, host: sheet.request.host)
    }

    private func row(_ session: RemoteTrackedSession, checked: Bool) -> some View {
        let inTab = isInTab(session)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The tmux session's name only matters to someone who will
                // ssh in: a tooltip, not a line.
                Text(model.trackedTitle(session))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .help(RemoteCopy.trackedHandleHelp(session.handle))
                Spacer(minLength: 8)
                // The state in a slot of its own, so it never reads as an
                // action beside the links.
                Text(RemoteCopy.trackedState(session.state, openHere: inTab))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.controlFill))
                HStack(spacing: 10) {
                    if sheet.stopping.contains(session.handle) {
                        ProgressView().controlSize(.small)
                    } else {
                        if inTab {
                            Button(RemoteCopy.showTab) {
                                sheet.showTab(session)
                                dismiss()
                            }
                        } else {
                            Button(RemoteCopy.openTracked) {
                                if sheet.open(session, rows: model.sessions) { dismiss() }
                            }
                            .help(RemoteCopy.openTrackedHelp)
                        }
                        Button("Stop") { stop(session) }
                            .help(RemoteCopy.stopTrackedHelp(host))
                        if Self.offersDismiss(session, dismissed: sheet.dismissedNotes) {
                            Button(RemoteCopy.dismissNote) { sheet.dismissNote(session) }
                                .help(RemoteCopy.dismissNoteHelp)
                        }
                    }
                }
                .padding(.leading, 16)
            }
            if let reason = session.leftRunning, Self.offersDismiss(session, dismissed: sheet.dismissedNotes) {
                Text(RemoteCopy.leftRunningLine(host, reason: reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .unknown(let reason) = session.state, checked {
                Text("Temple couldn't check this session: \(RemoteCopy.trimmed(reason)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let result = sheet.results[session.handle] {
                // Every "still running" line is orange.
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let command = sheet.commands[session.handle] {
                // The command on its own line, to copy.
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .buttonStyle(.neutralLink)
        .font(.system(size: 11))
        .padding(.vertical, 8)
    }

    /// Dismiss is only on a row with a left-running note (S7), until it is
    /// dismissed: elsewhere it would have nothing to clear.
    static func offersDismiss(_ session: RemoteTrackedSession, dismissed: Set<String>) -> Bool {
        session.leftRunning != nil && !dismissed.contains(session.handle)
    }

    /// A working agent asks first (S12); one waiting for input, or with no
    /// tab here, stops at once.
    private func stop(_ session: RemoteTrackedSession) {
        if model.openSessions.remoteTabs.workingTab(host: sheet.request.host, handle: session.handle) != nil {
            confirmingStop = session
        } else {
            sheet.stop(session)
        }
    }
}

/// The folder sheet for a new session on a host (section 7): a path as the
/// host spells it, the host's recent folders beneath, Return to confirm.
/// The check is advisory: what it resolves is intent; the row records a
/// folder only from the pane's own `ok`. A host whose last test proved no
/// session can start there (the tmux rule) says so, and Start is disabled.
struct RemoteFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheet: RemoteFolderSheetModel
    @FocusState private var focused: Bool
    /// Test connection, over this sheet: Close comes back here with the
    /// typed path, and a passing test checks the folder again.
    @State private var test: ConnectionTest?

    init(sheet: RemoteFolderSheetModel) { _sheet = StateObject(wrappedValue: sheet) }

    private var host: String { sheet.host }

    private var placeholder: String {
        if let user = model.remoteHosts.record(named: host)?.user { return "/home/\(user)/Projects/… or ~/…" }
        return "~/…"
    }

    /// The tmux rule's line, when no session can start on this host.
    private var tmuxProblem: String? { sheet.tmuxProblem }

    var body: some View {
        RemoteSheetChrome {
            // The host after the title, in mono, as Test connection's.
            RemoteSheetTitle(title: RemoteCopy.folderSheetTitle(sheet.request.agent), host: host)
            RemoteFormRow(label: RemoteCopy.folderFieldLabel) {
                // A path: monospaced, as Settings' Command field is.
                TextField("", text: $sheet.path, prompt: Text(placeholder))
                    .accessibilityLabel(RemoteCopy.folderFieldLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { sheet.confirm() }
                    .onChange(of: sheet.path) { sheet.edited() }
                    .templeFieldChrome(focused: focused)
                status
            }
            let recent = Array(model.recentRemoteFolders(sheet.request.host).prefix(8))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    RemoteListCaption(RemoteCopy.recentFoldersCaption)
                        .padding(.leading, 6)
                        .padding(.bottom, 2)
                    ForEach(recent, id: \.self) { folder in
                        RemoteListRow(action: {
                            sheet.path = folder
                            sheet.confirm()
                        }) {
                            Text(folder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                // Under the field, its text in line with the field's.
                .padding(.leading, RemoteSheetMetrics.labelWidth + 12 + 3)
            }
            HStack(spacing: 8) {
                if case .unreachable = sheet.check {
                    Button("Test connection") { test = sheet.testConnection() }
                    Button(RemoteCopy.startWithoutChecking) { sheet.startAnyway() }
                        .help(RemoteCopy.startWithoutCheckingHelp)
                        .disabled(tmuxProblem != nil)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { sheet.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheet.trimmedPath.isEmpty || sheet.check == .checking || tmuxProblem != nil)
            }
            .padding(.top, 8)
        }
        .onAppear { focused = true }
        // Dismissed: the check is cancelled, and nothing it answers starts.
        .onDisappear { sheet.dismissed() }
        .sheet(item: $test) { test in
            ConnectionTestSheet(test: test, surfaceFactory: model.surfaceFactory,
                                appearance: model.currentAppearance(),
                                onTestAgain: { self.test = sheet.testConnection() },
                                onClose: { closeTest(test) })
                .onDisappear { model.remoteHosts.endTest(test) }
                .remoteSheet(model)
        }
    }

    /// Back to this sheet, its text kept; a test that passed checks the
    /// folder again.
    private func closeTest(_ test: ConnectionTest) {
        self.test = nil
        sheet.testClosed(passed: RemoteFolderSheetModel.passed(test))
    }

    @ViewBuilder
    private var status: some View {
        if let tmuxProblem {
            RemoteProblem(tmuxProblem, color: .orange)
        }
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
            RemoteProblem(line)
        }
    }
}
