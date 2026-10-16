import SwiftUI

/// The right pane: the active tab's terminal (or Settings, or History), or the launcher when
/// nothing is open (UX §Main content). The per-project tab strip lives in the
/// native title-bar band as a titlebar ACCESSORY, not a toolbar item — an item
/// wider than the band overflows all-or-nothing into the `»` menu. The installer
/// is this pane's background so the strip's leading edge tracks the sidebar
/// divider live (see TitlebarTabStrip.swift).
struct MainContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        content
            // Exactly the detail area, never the content's size. Without the
            // zero minimums a flexible frame grows to a child taller than the
            // pane and is centred on it, so its top edge, and the divider
            // drawn there, rode up into the band: Home with the launcher's
            // Recent list at 900 x 652 put the line through the chip labels.
            // The band itself never moved (TitleBandHeightTests).
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(TitlebarTabStripInstaller())
            // Separates the tab band from the content below it. As this pane's
            // overlay it spans exactly the detail area — the sidebar keeps its
            // own seamless join with the title bar.
            .overlay(alignment: .top) {
                if !model.openSessions.visibleTabs.isEmpty {
                    Divider()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let active = model.openSessions.activeTab {
            switch active.kind {
            case .settings:
                SettingsView(settings: model.settings)
            case .history:
                HistoryTabView(history: model.history)
            case .session:
                terminal(for: active)
            }
        } else {
            LauncherView()
        }
    }

    private func terminal(for tab: SessionTab) -> some View {
        // Subscribe even before a surface exists: preparation can fail first.
        SessionTerminalView(tab: tab)
            .id(tab.id)
    }

}

/// A session's terminal, with a header that appears if the agent failed to launch.
private struct SessionTerminalView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: SessionTab
    @Environment(\.undoManager) private var undoManager

    /// Resume anyway, or Start a new session for a pending Codex session:
    /// asked in a sheet that names the command to stop the original.
    @State private var confirmation: RemoteConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            if let remote = tab.remote {
                // A tab on a host shows its own headers only: its ssh ending
                // is not its agent ending (checking, stopping: nothing yet).
                if remote.phase == .connected, remote.stillConnecting {
                    notice(symbol: "hourglass", text: RemoteCopy.stillConnecting(tab.host.rawValue)) {
                        Button("Cancel") { model.openSessions.remoteTabs.cancelConnect(tab) }
                    }
                } else if let header = RemoteHeader.make(remote.phase) { remoteHeader(header) }
                // A new Codex session Temple has not identified yet asks,
                // while it runs, whether one of its candidates is it.
                if remote.phase == .connected, tab.sessionID == nil,
                   !remote.suggestions.isEmpty || remote.identityNote != nil {
                    question(remote).background(Palette.surfaceFill)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
            } else if case .exited(let status) = tab.activity {
                launchFailure(status: status)
            }
            if let surface = tab.surface {
                TerminalSurfaceHost(surface: surface)
                    // ⌘F. Floats over the terminal's top-right corner, so the
                    // surface keeps its size and the agent's prompt line, at
                    // the bottom, stays clear of it.
                    .overlay(alignment: .topTrailing) {
                        TerminalFindOverlay(find: tab.find,
                                            note: tab.host.isLocal ? nil : RemoteCopy.findNote(tab.host.rawValue))
                    }
            } else {
                Color.clear.onAppear {
                    guard tab.launchPreparationError == nil, tab.remote == nil else { return }
                    model.openSessions.activate(tabID: tab.id)
                }
            }
        }
        .sheet(item: $confirmation) { confirmation in
            RemoteConfirmationSheet(confirmation: confirmation, host: tab.host.rawValue,
                                    stopCommand: model.openSessions.remoteTabs.stopCommand(tab)) {
                switch confirmation {
                case .resumeAnyway: model.openSessions.remoteTabs.resumeAnyway(tab)
                case .startNewPending: model.openSessions.remoteTabs.startNewPending(tab)
                }
            }
        }
    }

    /// The candidates for a pending Codex session, each a question (never
    /// a fact), and why Temple couldn't tell when it couldn't.
    private func question(_ remote: RemoteTabState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(remote.suggestions) { suggestion in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(RemoteCopy.suggestionQuestion(suggestion))
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if remote.confirming == suggestion.id {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 12) {
                            Button(RemoteCopy.suggestionYes) { model.openSessions.remoteTabs.confirm(suggestion, in: tab) }
                                .disabled(remote.confirming != nil)
                            Button(RemoteCopy.suggestionNo) { model.openSessions.remoteTabs.decline(suggestion, in: tab) }
                                .disabled(remote.confirming != nil)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                }
            }
            if let note = remote.identityNote {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if remote.identityRefused {
                        Button("Try again") { model.openSessions.remoteTabs.retryIdentity(tab) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                .padding(.leading, 20)
            }
            if !remote.identityRefused {
                Text(MainContentView.noDaemonHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a remote tab's header says, by phase; nil for none.
    private enum RemoteHeader {
        case disconnected
        case unknown(String)
        case stopFailed(String)
        case failure
        case exitedEarly
        case decision(checked: Bool)
        case endedPending
        case endedIdentified

        static func make(_ phase: RemoteTabState.Phase) -> RemoteHeader? {
            switch phase {
            case .opening, .connected, .checking, .stopping: nil
            case .disconnected: .disconnected
            case .unknown(let reason): .unknown(reason)
            case .stopFailed(let message): .stopFailed(message)
            case .failedToStart: .failure
            case .exitedEarly: .exitedEarly
            case .needsDecision(let checked): .decision(checked: checked)
            case .endedPending: .endedPending
            case .endedIdentified: .endedIdentified
            }
        }
    }

    @ViewBuilder
    private func remoteHeader(_ header: RemoteHeader) -> some View {
        let host = tab.host.rawValue
        switch header {
        case .failure:
            if case .exited(let status) = tab.activity { launchFailure(status: status) }
        case .exitedEarly:
            exitedEarly(host)
        case .decision(let checked):
            notice(symbol: "questionmark.circle",
                   text: checked ? RemoteCopy.unconfirmedConversation : RemoteCopy.uncheckedConversation) {
                HStack(spacing: 12) {
                    if !checked {
                        Button("Resume") { model.openSessions.remoteTabs.resumeUnconfirmed(tab) }
                    }
                    Button("Start a new session") { model.openSessions.remoteTabs.startNewSession(tab) }
                    Button("Discard") { model.openSessions.remoteTabs.discard(tab) }
                        .help(RemoteCopy.discardHelp(archives: tab.sessionID.map(model.discardArchives) ?? false))
                }
            }
        case .endedPending:
            VStack(spacing: 0) {
                notice(symbol: "questionmark.circle", text: RemoteCopy.codexEndedPending(host)) {
                    HStack(spacing: 12) {
                        Button("Start a new session") { model.openSessions.remoteTabs.startNewPending(tab) }
                        Button("Discard") { model.openSessions.remoteTabs.discardPending(tab) }
                            .help(RemoteCopy.discardPendingHelp(host))
                    }
                }
                // Asked even with no candidate yet: the hint says how Temple
                // could tell by itself next time.
                if let remote = tab.remote {
                    question(remote).background(Palette.surfaceFill)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                }
            }
        case .endedIdentified:
            notice(symbol: "checkmark.circle", text: RemoteCopy.endedIdentified(host)) {
                Button("Resume") { model.openSessions.remoteTabs.reconnect(tab) }
            }
        case .disconnected:
            notice(symbol: "bolt.horizontal.circle", text: RemoteCopy.disconnected(host)) {
                Button("Reconnect") { model.openSessions.remoteTabs.reconnect(tab) }
            }
        case .unknown(let reason):
            VStack(spacing: 0) {
                notice(symbol: "questionmark.circle", text: RemoteCopy.unknown(host, agent: tab.agent, reason: reason)) {
                    HStack(spacing: 12) {
                        Button("Reconnect") { model.openSessions.remoteTabs.reconnect(tab) }
                        if tab.sessionID != nil {
                            Button("Resume anyway") { confirmation = .resumeAnyway }
                        } else if tab.agent == .codex {
                            Button("Start a new session") { confirmation = .startNewPending }
                        }
                    }
                }
                if let lines = tab.remote?.diagnostics, !lines.isEmpty { diagnosticLines(lines) }
            }
        case .stopFailed(let message):
            notice(symbol: "exclamationmark.triangle", text: message) {
                Button("Sessions on \(host)") { model.showRemoteSessions(tab.host) }
            }
        }
    }

    /// An agent on a host that ended seconds after it started: what it
    /// printed (the pane's own output, fetched with its record), then the
    /// agent's argv. The tab stays, as a local one does.
    private func exitedEarly(_ host: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                Text(RemoteCopy.exitedImmediately(host, agent: tab.agent))
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array((tab.remote?.diagnostics ?? []).enumerated()), id: \.offset) { _, line in
                diagnosticLine(line)
            }
            if let argv = tab.displayArgv, !argv.isEmpty {
                Text(argv.joined(separator: " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    private func diagnosticLine(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
    }

    /// What the pane printed before its agent ended, under a header.
    private func diagnosticLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in diagnosticLine(line) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFill)
    }

    private func notice<Actions: View>(symbol: String, text: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    /// The header's first line. On a host it names the host; a host that is
    /// no longer set up says only that.
    private func failureTitle(preparationError: String?, blameCommand: Bool, exited: String) -> String {
        if !tab.host.isLocal, preparationError == RemoteCopy.notSetUp(tab.host.rawValue) {
            return RemoteCopy.notSetUp(tab.host.rawValue)
        }
        if preparationError != nil {
            return tab.host.isLocal ? "\(tab.agent.displayName) failed to start."
                : RemoteCopy.failedToStart(tab.host.rawValue, agent: tab.agent)
        }
        return blameCommand ? "\(exited) — it failed to start." : "\(exited)."
    }

    /// An agent that died seconds after spawning (`OpenSessionsModel` keeps the tab
    /// precisely so its output survives). This says what Temple actually ran — the one
    /// thing the terminal can't tell you, and the only half of the story Temple is
    /// responsible for.
    ///
    /// It is careful about *whose fault* it implies. If detection has verified the
    /// binary and the CLI accepted the arguments, then the command is provably fine and
    /// the agent died for its own reasons ("no conversation found with session ID …") —
    /// so we point at the terminal, not at Settings. Blaming the command every time
    /// would send people to a screen that can't help, and train them to ignore the
    /// warning on the day the command really is at fault.
    private func launchFailure(status: Int32) -> some View {
        // A launcher's own account of why the agent never ran stands in for
        // a preparation error: the command was not at fault.
        let preparationError = tab.launchPreparationError ?? tab.launchFailure?.message
        let argv = preparationError == nil ? tab.displayArgv ?? [] : []
        // Frozen when the tab died — NOT re-derived from today's settings, which
        // would let an unrelated edit flip an old failure's verdict.
        let blameCommand = tab.commandWasSuspect
        // The status is only worth showing when it carries information. The surface
        // reports 0 for a process that plainly crashed (libghostty spawns through
        // `login`, whose own exit status is what comes back), and "(status 0)" next to
        // a failure reads as a contradiction that makes a user distrust the message.
        let exited = status == 0
            ? "\(tab.agent.displayName) exited immediately"
            : "\(tab.agent.displayName) exited immediately (status \(status))"

        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(blameCommand ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failureTitle(preparationError: preparationError, blameCommand: blameCommand, exited: exited))
                    .font(.system(size: 12, weight: .medium))
                if let preparationError, preparationError != RemoteCopy.notSetUp(tab.host.rawValue) {
                    Text(preparationError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !argv.isEmpty {
                    Text(argv.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                // Nothing here points at the terminal: it is directly below, in view,
                // with the agent's own error in it. Say what to DO, or say nothing.
                if blameCommand && preparationError == nil {
                    Text("Check the command and arguments in Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let message = tab.missingWorkingDirectoryMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = tab.resumeTargetMissingMessage {
                    // States only what the engine proves (no transcript carries
                    // this id). When the row was already known transcript-less
                    // before the launch, that is the whole story; otherwise a
                    // deletion or prune leads, ahead of the /resume and /clear
                    // rotation, and nothing promises the conversation survives.
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 8)
            if blameCommand && preparationError == nil {
                Button("Settings") { model.openSessions.openSettings(focusing: tab.agent) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            } else if tab.offersArchiveForMissingTranscript {
                Button("Archive") { model.closeAndArchive(tab, undoManager: undoManager) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            } else if tab.launchPreparationError == OpenSessionsModel.unknownDirectoryMessage, let sid = tab.sessionID {
                HStack(spacing: 12) {
                    if model.offersArchiveForUnknownDirectory(tab) {
                        Button("Archive") { model.closeAndArchive(tab, undoManager: undoManager) }
                    }
                    Button("Show in History") { model.showInHistory(sessionID: sid) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

/// The two ways out of a session Temple can't reach that start another
/// agent while the original may still run.
enum RemoteConfirmation: String, Identifiable {
    case resumeAnyway, startNewPending
    var id: String { rawValue }
}

/// Resume anyway, or Start a new session: a short question, why, and the
/// command that stops the original on the host, apart and selectable.
private struct RemoteConfirmationSheet: View {
    let confirmation: RemoteConfirmation
    let host: String
    let stopCommand: String?
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        confirmation == .resumeAnyway ? RemoteCopy.resumeAnywayTitle : RemoteCopy.startNewPendingTitle
    }

    private var message: String {
        confirmation == .resumeAnyway ? RemoteCopy.resumeAnyway(host) : RemoteCopy.startNewPending(host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let stopCommand {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RemoteCopy.stopHint(host))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(stopCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation == .resumeAnyway ? "Resume anyway" : "Start a new session") {
                    dismiss()
                    action()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension MainContentView {
    /// The `--no-daemon` hint, the flag set as code (monospaced, same size),
    /// the rest as it reads.
    static var noDaemonHint: AttributedString {
        var text = AttributedString(RemoteCopy.noDaemonHint)
        if let range = text.range(of: "--no-daemon") {
            text[range].font = .system(size: 11, design: .monospaced)
        }
        return text
    }
}
