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
                if sheet.stopping.contains(session.handle) {
                    ProgressView().controlSize(.small)
                } else if sheet.kept.contains(session.handle) {
                    Text("Kept").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Stop") { sheet.stop(session) }
                    Button("Keep") { sheet.keep(session) }
                }
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
                Text("Folder on \(host)").font(.system(size: 12))
                TextField(placeholder, text: $sheet.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
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
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
