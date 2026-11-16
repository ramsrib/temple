import SwiftUI
import AppKit
import TempleCore

/// The hosts manager (docs/designs/ux-pass-2026-11.md section 5): every host
/// Temple reaches, in the shape of macOS's Internet Accounts. The list is on
/// the left, each host with a status dot; the selected host's details and
/// actions are on the right; + and − sit under the list. Opened by Manage
/// Hosts… in Settings, the Project menu, and a host project's context menu.
///
/// A sheet, not a window of its own: Temple is single-window, and closing
/// its window is quitting (AGENTS.md, "Quitting"). A second window would
/// put that logic on a window it was never written for.
///
/// It owns the flows Settings' Hosts section used to: Add host, the host
/// form, Test connection, Remove and its "still running" alert, and the
/// Running sessions sheet, each a sheet over this one.
struct HostsManagerSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var hosts: RemoteHostsModel
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var form: HostFormRequest?
    @State private var addHost: AddHostSheetModel?
    /// The form Add host ended with: it opens once that sheet is gone.
    @State private var formAfterAddHost: HostFormRequest?
    @State private var test: ConnectionTest?
    /// "Save and test": the test opens once the form's sheet is gone.
    @State private var testAfterForm: String?
    /// Remove found sessions still running on the host: the alert.
    @State private var removal: RemoteRemoval?
    /// Hosts whose Remove is asking the host, or stopping its sessions.
    @State private var removing: Set<String> = []
    /// A Stop them and remove that could not stop everything, by host.
    @State private var removeProblems: [String: AppModel.RemovalFailures] = [:]
    /// The selected host's running sessions, once asked for: filled in
    /// place, never on selection alone (a host may ask for a passphrase).
    @State private var sessions: RemoteSessionsSheetModel?

    /// Round 3: the 680×400 sheet was crowded. It fits Temple's narrowest
    /// window (900 × 600).
    static let size = CGSize(width: 760, height: 500)
    static let listWidth: CGFloat = 240

    private var records: [RemoteHostRecord] { HostsSettingsSection.inUse(hosts.records) }
    private var selected: RemoteHostRecord? {
        records.first { $0.name == selection } ?? records.first
    }

    /// System Settings' shape: the list in a shaded column with the title
    /// over it, the selected host's details beside it, Done at the bottom
    /// of the details. No title bar across the top.
    var body: some View {
        HStack(spacing: 0) {
            hostList
                .frame(width: Self.listWidth)
                .background(Palette.surfaceFill)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.templePrimary)
                }
                .padding(20)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(Palette.accent)
        .onAppear {
            hosts.loadConfigAliases()
            if model.hostsManagerStartsAdding {
                model.hostsManagerStartsAdding = false
                addHost = AddHostSheetModel(hosts: hosts)
            }
            // Dev-only (TEMPLE_SNAPSHOT_DIR + TEMPLE_SNAPSHOT_PRESENT=hosts-add):
            // Add host over the manager, for its field's first moments.
            let env = ProcessInfo.processInfo.environment
            if env["TEMPLE_SNAPSHOT_DIR"] != nil, env["TEMPLE_SNAPSHOT_PRESENT"] == "hosts-add" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { addHost = AddHostSheetModel(hosts: hosts) }
            }
        }
        .onChange(of: selected?.name) { endSessions() }
        .onDisappear { endSessions() }
        .alert(removal.map { RemoteCopy.removalTitle($0.live.count, host: $0.name) } ?? "",
               isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
               presenting: removal) { removal in
            Button(RemoteCopy.removalLeave(removal.live.count)) {
                model.removeHostLeavingSessions(removal)
                self.removal = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(RemoteCopy.removalStop(removal.live.count)) { stopAndRemove(removal) }
            Button("Cancel", role: .cancel) { self.removal = nil }
        } message: { removal in
            Text(RemoteCopy.removalMessage(removal.live.count, fromConfig: removal.fromConfig))
        }
        .background { sheets }
    }

    // MARK: List

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hosts")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        HostListRow(record: record, tone: Self.tone(hosts.summaries[record.name]),
                                    selected: record.name == selected?.name) {
                            selection = record.name
                        }
                    }
                }
                .padding(8)
            }
            .thinScrollers()
            Divider()
            HStack(spacing: 0) {
                Button { addHost = AddHostSheetModel(hosts: hosts) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("Add a host")
                Divider().frame(height: 14)
                Button { if let selected { remove(selected) } } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .disabled(selected == nil || selected.map { removing.contains($0.name) } == true)
                .help(selected.map { RemoteCopy.removeHostHelp(fromConfig: $0.source == .config) } ?? "")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// A host's dot: what Temple last learned about reaching it.
    enum Tone: Equatable { case untested, ok, advisory, failure }

    static func tone(_ summary: HostTestSummary?) -> Tone {
        guard let summary else { return .untested }
        if summary.failure != nil { return .failure }
        return summary.isAdvisory ? .advisory : .ok
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let record = selected {
            let caption = HostsSettingsSection.caption(for: record, configAliases: hosts.configAliases)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(record.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let problems = removeProblems[record.name], !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RemoteCopy.notRemoved(record.name))
                            ForEach(Array(problems.lines.enumerated()), id: \.offset) { _, line in Text(line) }
                            Text(RemoteCopy.removeAgain(record.name, count: problems.lines.count)).padding(.top, 2)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    group("Connection") {
                        // Each action sits on the row of the fact it
                        // changes or checks.
                        detailRow("Address") {
                            if caption == .goneFromConfig {
                                Text(caption.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                            } else {
                                Text(record.source == .config ? record.name : record.summary)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        } trailing: { EmptyView() }
                        // Where the host is defined (cold read: "Set up in:
                        // Temple" read as an installation step).
                        detailRow("Source") {
                            Text(record.source == .config ? "~/.ssh/config" : "Added in Temple")
                                .font(.system(size: 13))
                        } trailing: {
                            if record.source == .config {
                                Button(RemoteCopy.openSSHConfig) { HostsSettingsSection.openSSHConfig() }
                            } else {
                                Button("Edit…") { form = HostFormRequest(editing: record) }
                                    .help("Change this host's address, user, port or keys")
                            }
                        }
                        detailRow("Status") {
                            HostStatusLine(text: hosts.statusLine(for: record.name), summary: hosts.summaries[record.name])
                        } trailing: {
                            Button("Test connection") { startTest(record.name) }
                        }
                    }
                    group("Running sessions") {
                        if let sessions, sessions.request.host == record.host {
                            RemoteSessionsList(sheet: sessions, close: { dismiss() }, maxHeight: 220)
                                .padding(.vertical, 4)
                        } else {
                            detailRow(nil) {
                                Text("Not checked yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            } trailing: {
                                Button("Show running sessions") { showSessions(record) }
                                    .help("Ask \(record.name) which sessions Temple started there are still running")
                            }
                        }
                    }
                    if removing.contains(record.name) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Removing…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.temple)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Text("No hosts yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Add a machine you reach with ssh to run sessions there.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Host…") { addHost = AddHostSheetModel(hosts: hosts) }
                    .buttonStyle(.temple)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A labeled group of the details: a quiet label over a shaded box.
    private func group<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// One line of a group: its label in a fixed column, the value, and the
    /// action that belongs to it at the trailing edge.
    private func detailRow<Value: View, Trailing: View>(_ label: String?, @ViewBuilder value: () -> Value,
                                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
            }
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 36)
    }

    // MARK: Sheets over this one

    @ViewBuilder
    private var sheets: some View {
        // One sheet per anchor: SwiftUI keeps one presentation per view.
        Color.clear
            .sheet(item: $form, onDismiss: openPendingTest) { request in
                HostFormSheet(request: request, existing: Set(hosts.records.map(\.name)),
                              configAliases: Set(hosts.configAliases ?? [])) { record, thenTest in
                    hosts.save(record, editing: request.editing?.name)
                    selection = record.name
                    testAfterForm = thenTest ? record.name : nil
                }
                .remoteSheet(model)
            }
        Color.clear
            .sheet(item: $addHost, onDismiss: openPendingForm) { sheet in
                AddHostSheet(sheet: sheet) { outcome in
                    switch outcome {
                    case .details(let prefill): formAfterAddHost = HostFormRequest(editing: nil, prefill: prefill)
                    case .editConfig: HostsSettingsSection.openSSHConfig()
                    case .added, .cancelled: break
                    }
                }
                .remoteSheet(model)
            }
        Color.clear
            .sheet(item: $test) { test in
                ConnectionTestSheet(test: test, surfaceFactory: model.surfaceFactory,
                                    appearance: model.currentAppearance(),
                                    onTestAgain: { startTest(test.record.name) },
                                    onClose: { self.test = nil })
                    .onDisappear { hosts.endTest(test) }
                    .remoteSheet(model)
            }
        // Running sessions on a host, over this sheet while it is up (the
        // root presents it otherwise): one request, `remoteSessionsSheet`,
        // so the model's checks on which sheet is current still hold.
        Color.clear
            .sheet(item: $model.remoteSessionsSheet) { request in
                RemoteSessionsSheet(sheet: model.sessionsSheetModel(request))
                    .environmentObject(model)
                    .remoteSheet(model)
            }
    }

    // MARK: Actions

    private func showSessions(_ record: RemoteHostRecord) {
        endSessions()
        sessions = model.showRunningSessionsInManager(record.host)
        sessions?.load()
    }

    /// Another host selected, or the manager gone: the listing's query is
    /// cancelled and its answers refused.
    private func endSessions() {
        sessions?.dismissed()
        sessions = nil
        model.endRunningSessionsInManager()
    }

    private func startTest(_ name: String) {
        test = hosts.startTest(for: name)
    }

    /// Remove asks the host first; with nothing of Temple's running there
    /// (or no answer), the host goes at once.
    private func remove(_ record: RemoteHostRecord) {
        removeProblems[record.name] = nil
        removing.insert(record.name)
        model.requestRemoveHost(record.name) { found in
            removing.remove(record.name)
            removal = found
        }
    }

    private func stopAndRemove(_ removal: RemoteRemoval) {
        self.removal = nil
        removing.insert(removal.name)
        model.stopSessionsAndRemoveHost(removal) { failures in
            removing.remove(removal.name)
            removeProblems[removal.name] = failures.isEmpty ? nil : failures
        }
    }

    private func openPendingForm() {
        guard let request = formAfterAddHost else { return }
        formAfterAddHost = nil
        form = request
    }

    private func openPendingTest() {
        guard let name = testAfterForm else { return }
        testAfterForm = nil
        startTest(name)
    }
}

/// One host in the manager's list: a status dot, the name, and where it
/// came from.
private struct HostListRow: View {
    let record: RemoteHostRecord
    let tone: HostsManagerSheet.Tone
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                HostStatusDot(tone: tone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.source == .config ? HostsSettingsSection.Caption.sshConfig.text : record.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Palette.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

/// A host's last test, as a dot: green connected, orange with a warning,
/// red couldn't connect, hollow not tested. The manager's list and
/// Settings' Hosts section both show it.
struct HostStatusDot: View {
    let tone: HostsManagerSheet.Tone

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(tone == .untested ? 0.6 : 0), lineWidth: 1))
            .frame(width: 8, height: 8)
            .help(help)
    }

    private var color: Color {
        switch tone {
        case .untested: .clear
        case .ok: .green
        case .advisory: .orange
        case .failure: .red
        }
    }

    private var help: String {
        switch tone {
        case .untested: "Not tested since Temple started"
        case .ok: "Last test connected"
        case .advisory: "Last test connected, with a warning"
        case .failure: "Last test could not connect"
        }
    }
}
