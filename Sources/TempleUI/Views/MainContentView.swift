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

    @State private var confirmingResumeAnyway = false

    var body: some View {
        VStack(spacing: 0) {
            if let remote = tab.remote {
                // A tab on a host shows its own headers only: its ssh ending
                // is not its agent ending (checking, stopping: nothing yet).
                if let header = RemoteHeader.make(remote.phase) { remoteHeader(header) }
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
        .alert("Resume anyway?", isPresented: $confirmingResumeAnyway) {
            Button("Cancel", role: .cancel) {}
            Button("Resume anyway") { model.openSessions.resumeAnyway(tab) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.openSessions.resumeAnywayMessage(tab) ?? "")
        }
    }

    /// What a remote tab's header says, by phase; nil for none.
    private enum RemoteHeader {
        case disconnected
        case unknown(String)
        case stopFailed(String)
        case failure

        static func make(_ phase: RemoteTabState.Phase) -> RemoteHeader? {
            switch phase {
            case .opening, .connected, .checking, .stopping: nil
            case .disconnected: .disconnected
            case .unknown(let reason): .unknown(reason)
            case .stopFailed(let message): .stopFailed(message)
            case .failedToStart, .exitedEarly: .failure
            }
        }
    }

    @ViewBuilder
    private func remoteHeader(_ header: RemoteHeader) -> some View {
        let host = tab.host.rawValue
        switch header {
        case .failure:
            if case .exited(let status) = tab.activity { launchFailure(status: status) }
        case .disconnected:
            notice(symbol: "bolt.horizontal.circle", text: RemoteCopy.disconnected(host)) {
                Button("Reconnect") { model.openSessions.reconnect(tab) }
            }
        case .unknown(let reason):
            notice(symbol: "questionmark.circle", text: RemoteCopy.unknown(host, agent: tab.agent, reason: reason)) {
                HStack(spacing: 12) {
                    Button("Reconnect") { model.openSessions.reconnect(tab) }
                    if tab.sessionID != nil {
                        Button("Resume anyway") { confirmingResumeAnyway = true }
                    }
                }
            }
        case .stopFailed(let message):
            notice(symbol: "exclamationmark.triangle", text: message) {
                Button("Sessions on \(host)") { model.showRemoteSessions(tab.host) }
            }
        }
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
