import AppKit
import SwiftUI
import TempleCore
import TempleTerminalAPI

/// Settings' Hosts connection manager (docs/designs/remote-ssh.md section
/// 7), always shown (the one remote surface with no host enabled, and the
/// way to enable one; the ssh config is read when it appears). One "Added
/// hosts" list of every host Temple has, whichever source it came from (a
/// caption says which), each with Test connection, Running sessions on
/// <host>…, Open ~/.ssh/config (a config host) or Edit (one added by
/// address), Remove, and its status line; then Add host…, a sheet
/// (`AddHostSheet`): one field, the `~/.ssh/config` aliases not added under
/// it (choosing one adds it), the form for an address and the config
/// behind links. Remove asks first when sessions Temple started are still
/// running there.
///
/// Labels say what they do: where one doesn't fit on the row, the links
/// move to a line of their own (the cold-read round: "Sessions…" and
/// "Turn off" were cut down for the row's rhythm and read as nothing).
///
/// Layout rules as for the rest of Settings (AGENTS.md, the split view's
/// titlebar inset): no `.fixedSize`, `.allowsHitTesting`, `layoutPriority`,
/// `List` or `Form`. The sheets are their own windows.
struct HostsSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var hosts: RemoteHostsModel
    /// Codex's arguments as set above: whether they carry `--no-daemon`.
    var codexArguments: [String] = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRule("Hosts")
            HostsRow(RemoteCopy.hostsLabel) { addedHosts }
            hairline
            Text(Self.flagsAsCode(Self.argumentsNote))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            Text(Self.noDaemonHint(enabled: codexArguments.contains("--no-daemon")))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(.top, 26)
        .onAppear { hosts.loadConfigAliases() }
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
        .background {
            // One sheet per anchor: SwiftUI keeps one presentation per view.
            Color.clear
                .sheet(item: $form, onDismiss: openPendingTest) { request in
                    HostFormSheet(request: request, existing: Set(hosts.records.map(\.name)),
                                  configAliases: Set(hosts.configAliases ?? [])) { record, thenTest in
                        hosts.save(record, editing: request.editing?.name)
                        testAfterForm = thenTest ? record.name : nil
                    }
                    .remoteSheet(model)
                }
            Color.clear
                .sheet(item: $addHost, onDismiss: openPendingForm) { sheet in
                    AddHostSheet(sheet: sheet) { outcome in
                        switch outcome {
                        case .details(let prefill): formAfterAddHost = HostFormRequest(editing: nil, prefill: prefill)
                        case .editConfig: Self.openSSHConfig()
                        case .added, .cancelled: break
                        }
                    }
                    .remoteSheet(model)
                }
            Color.clear
                .sheet(item: $test) { test in
                    // The app's effective appearance, read again whenever the
                    // sheet's colour scheme changes: dark in dark.
                    ConnectionTestSheet(test: test, surfaceFactory: model.surfaceFactory,
                                        appearance: model.currentAppearance(),
                                        onTestAgain: { startTest(test.record.name) },
                                        onClose: { self.test = nil })
                        .onDisappear { hosts.endTest(test) }
                        .remoteSheet(model)
                }
        }
    }

    static let argumentsNote =
        "Temple reaches these hosts with your own ssh. The arguments set above apply there too, --dangerously-skip-permissions included."

    /// The `--no-daemon` note, the flag set as code, the rest as it reads.
    /// Here rather than in a tab's band (owner, round 2); it follows
    /// Codex's arguments.
    static func noDaemonHint(enabled: Bool) -> AttributedString {
        flagsAsCode(RemoteCopy.noDaemonHint(enabled: enabled))
    }

    /// Every `--flag` in a note set as code (monospaced, same size), as
    /// every other flag on the page is.
    static func flagsAsCode(_ note: String) -> AttributedString {
        var text = AttributedString(note)
        var start = text.startIndex
        while let found = text[start...].range(of: "--") {
            var end = found.upperBound
            while end < text.endIndex, let character = text.characters[end...].first,
                  character.isLetter || character.isNumber || character == "-" {
                end = text.characters.index(after: end)
            }
            text[found.lowerBound..<end].font = .system(size: 11, design: .monospaced)
            start = end
        }
        return text
    }

    // MARK: Added hosts

    /// Every host Temple has, from either source, by name.
    static func inUse(_ records: [RemoteHostRecord]) -> [RemoteHostRecord] {
        records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static let inUseEmpty = RemoteCopy.hostsEmpty

    /// What a row says beside the name: where the host came from.
    enum Caption: Equatable {
        /// A host added by address: its address summary.
        case summary(String)
        /// An alias from `~/.ssh/config`.
        case sshConfig
        /// An added alias the config no longer names (only once the config
        /// has been read: while it is read nothing is known missing). Said
        /// as an orange line under the row, not in the caption's slot.
        case goneFromConfig

        var text: String {
            switch self {
            case .summary(let summary): summary
            case .sshConfig: "from ~/.ssh/config"
            case .goneFromConfig: RemoteCopy.goneFromConfig
            }
        }
    }

    static func caption(for record: RemoteHostRecord, configAliases: [String]?) -> Caption {
        switch record.source {
        case .temple: .summary(record.summary)
        case .config: configAliases.map { $0.contains(record.name) } == false ? .goneFromConfig : .sshConfig
        }
    }

    @ViewBuilder
    private var addedHosts: some View {
        let inUse = Self.inUse(hosts.records)
        VStack(alignment: .leading, spacing: 14) {
            if inUse.isEmpty {
                Text(Self.inUseEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
            ForEach(inUse) { record in hostRow(record) }
            HostLink("Add host…", systemImage: "plus") { addHost = AddHostSheetModel(hosts: hosts) }
                .padding(.top, inUse.isEmpty ? 0 : 2)
        }
        .padding(.top, 5)
    }

    private func hostRow(_ record: RemoteHostRecord) -> some View {
        let caption = Self.caption(for: record, configAliases: hosts.configAliases)
        return VStack(alignment: .leading, spacing: 4) {
            // The links on a line of their own, under the name: "Running
            // sessions on <host>…" names the host in full, and the words
            // never shrink to fit beside it (no measuring view here: the
            // titlebar inset trap, AGENTS.md).
            nameAndCaption(record, caption)
            links(record)
                .padding(.top, 1)
            if caption == .goneFromConfig {
                Text(caption.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HostStatusLine(text: hosts.statusLine(for: record.name), summary: hosts.summaries[record.name])
            if let problems = removeProblems[record.name], !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RemoteCopy.notRemoved(record.name))
                    // Every session the alert counted, each with its outcome.
                    ForEach(Array(problems.lines.enumerated()), id: \.offset) { _, line in Text(line) }
                    Text(RemoteCopy.removeAgain(record.name, count: problems.lines.count)).padding(.top, 2)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func nameAndCaption(_ record: RemoteHostRecord, _ caption: Caption) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(record.name)
                .font(.system(size: 13, weight: .medium))
            if caption != .goneFromConfig {
                Text(caption.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    /// What a row offers, in order: the same four for both kinds of host,
    /// but the file's own editor for a config host where one added by
    /// address has Edit.
    enum HostAction: Equatable {
        case test, runningSessions, openConfig, edit, remove

        func title(_ host: String) -> String {
            switch self {
            case .test: "Test connection"
            case .runningSessions: RemoteCopy.sessionsOnMenuItem(host)
            case .openConfig: RemoteCopy.openSSHConfig
            case .edit: "Edit"
            case .remove: RemoteCopy.removeHost
            }
        }
    }

    static func actions(for record: RemoteHostRecord) -> [HostAction] {
        [.test, .runningSessions, record.source == .config ? .openConfig : .edit, .remove]
    }

    private func links(_ record: RemoteHostRecord) -> some View {
        WrappingRow(spacing: 14) {
            ForEach(Self.actions(for: record), id: \.self) { action in
                if action == .remove, removing.contains(record.name) {
                    ProgressView().controlSize(.mini)
                } else {
                    HostLink(action.title(record.name)) { perform(action, record) }
                        .help(action == .remove ? RemoteCopy.removeHostHelp(fromConfig: record.source == .config) : "")
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func perform(_ action: HostAction, _ record: RemoteHostRecord) {
        switch action {
        case .test: startTest(record.name)
        case .runningSessions: model.showRemoteSessions(record.host)
        case .openConfig: Self.openSSHConfig()
        case .edit: form = HostFormRequest(editing: record)
        case .remove: remove(record)
        }
    }

    // MARK: Actions

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

    /// The user's own editor for the file; Finder if nothing opens it.
    static func openSSHConfig() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: NSWorkspace.shared.urlForApplication(toOpen: url)
                                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}

/// What the Add host / Edit sheet is for.
struct HostFormRequest: Identifiable {
    let id = UUID()
    let editing: RemoteHostRecord?
    /// A new host's fields as the Add host sheet's field gave them.
    var prefill: RemoteHostForm?
}

/// Settings' row shape: a 168pt label column, then the content.
private struct HostsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .padding(.top, 5)
                .frame(width: SettingsView.labelColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

/// A Settings link: plain, 11pt, medium.
struct HostLink: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.primary)
    }
}

/// A host's one status line, the row's caption: 11 pt secondary when it is
/// news (tertiary read too faint in dark), orange when a test proved
/// something wrong, red when it could not connect.
struct HostStatusLine: View {
    let text: String
    let summary: HostTestSummary?

    enum Tone: Equatable { case caption, advisory, failure }

    var tone: Tone {
        guard let summary else { return .caption }
        if summary.failure != nil { return .failure }
        return summary.isAdvisory ? .advisory : .caption
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tone == .failure ? AnyShapeStyle(Color.red)
                             : tone == .advisory ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Add host / Edit

struct HostFormSheet: View {
    let request: HostFormRequest
    let existing: Set<String>
    let configAliases: Set<String>
    let onSave: (RemoteHostRecord, _ thenTest: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: RemoteHostForm
    @State private var problems: [RemoteHostFormField: String] = [:]
    @State private var copied = false
    @FocusState private var focused: RemoteHostFormField?

    init(request: HostFormRequest, existing: Set<String>, configAliases: Set<String>,
         onSave: @escaping (RemoteHostRecord, Bool) -> Void) {
        self.request = request
        self.existing = existing
        self.configAliases = configAliases
        self.onSave = onSave
        _form = State(initialValue: request.editing.map(RemoteHostForm.init) ?? request.prefill ?? RemoteHostForm())
    }

    private var isEditing: Bool { request.editing != nil }

    var body: some View {
        RemoteSheetChrome {
            RemoteSheetTitle(title: isEditing ? "Edit \(request.editing?.name ?? "")" : RemoteCopy.hostFormAddTitle)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 10) {
                field(.name, "Name", text: $form.name, placeholder: "build-box",
                      note: RemoteCopy.hostFormNameNote, disabled: isEditing)
                field(.address, "Address", text: $form.address, placeholder: "build-box.local or 10.0.0.2")
                field(.user, "User", text: $form.user, placeholder: RemoteCopy.hostFormUserPlaceholder)
                field(.port, "Port", text: $form.port, placeholder: "22", width: 90)
                field(.identityFile, "Identity file", text: $form.identityFile, placeholder: "Optional",
                      note: "Adds this key to the ones ssh tries", trailing: AnyView(HostLink("Choose…") { chooseIdentity() }))
                field(.proxyJump, "Jump host", text: $form.proxyJump, placeholder: "Optional")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Temple passes these to your own ssh. Passwords and keys are never stored; ssh asks for them when it connects.")
                if isEditing { Text(RemoteCopy.hostFormEditHint) }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)

            HStack(spacing: 8) {
                HostLink(copied ? "Copied" : "Copy as ssh config", systemImage: copied ? "checkmark" : "doc.on.doc") { copyConfig() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(thenTest: false) }
                Button("Save and test") { save(thenTest: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .onAppear { focused = isEditing ? .address : .name }
    }

    private func field(_ field: RemoteHostFormField, _ label: String, text: Binding<String>, placeholder: String,
                       note: String? = nil, width: CGFloat? = nil, disabled: Bool = false,
                       trailing: AnyView? = nil) -> some View {
        RemoteFormRow(label: label) {
            HStack(spacing: 8) {
                TextField("", text: text, prompt: Text(placeholder))
                    .accessibilityLabel(label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .disabled(disabled)
                    .foregroundStyle(disabled ? .secondary : .primary)
                    .focused($focused, equals: field)
                    .templeFieldChrome(focused: focused == field)
                    .frame(maxWidth: width ?? .infinity)
                    .onChange(of: text.wrappedValue) { problems[field] = nil; copied = false }
                if let trailing { trailing }
            }
            if let problem = problems[field] {
                RemoteProblem(problem)
            } else if let note {
                RemoteHint(note)
            }
        }
    }

    private func validated() -> RemoteHostRecord? {
        switch form.validate(editing: request.editing?.name, existing: existing, configAliases: configAliases) {
        case .success(let record):
            problems = [:]
            return record
        case .failure(let found):
            problems = found.byField
            return nil
        }
    }

    private func save(thenTest: Bool) {
        guard let record = validated() else { return }
        onSave(record, thenTest)
        dismiss()
    }

    private func copyConfig() {
        guard let record = validated() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.sshConfigBlock, forType: .string)
        copied = true
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.identityFile = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Test connection

/// The terminal the sheet shows, and its end.
@MainActor
final class TestTerminal: ObservableObject, TerminalSurfaceDelegate {
    let surface: TerminalSurface
    private weak var test: ConnectionTest?
    private var started = false
    private var stopped = false
    private var startTask: Task<Void, Never>?

    init(surfaceFactory: TerminalSurfaceFactory, appearance: TerminalAppearance) {
        surface = surfaceFactory.makeSurface(appearance: appearance)
        // Applied, not only seeded: the terminal runtime's theme is built
        // once and rebuilt only by an apply, and with no tab open nothing
        // had applied the app's current one (a white terminal in a dark
        // sheet).
        surface.apply(appearance)
    }

    func start(_ test: ConnectionTest) {
        guard !started else { return }
        started = true
        self.test = test
        surface.delegate = self
        // Kept, so closing the sheet cancels it (and the ssh -G it runs).
        startTask = Task { @MainActor [weak self] in
            // Nothing could be prepared, or the sheet closed meanwhile: the
            // test says why (or is gone), and no terminal runs.
            guard await test.start(), let self, !self.stopped, !Task.isCancelled else { return }
            do {
                try self.surface.start(TerminalCommand(argv: test.surfaceArgv, cwd: test.surfaceDirectory))
                self.surface.focus()
            } catch {
                test.terminalExited()
            }
        }
    }

    func stop() {
        stopped = true
        startTask?.cancel()
        startTask = nil
        surface.delegate = nil
        surface.terminate()
        surface.release()
    }

    /// The terminal's process ended: the test asks ssh whether a master is
    /// up (the status the terminal reports is not ssh's).
    func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState) {
        guard case .exited = state else { return }
        test?.terminalExited()
    }
    func surface(_ surface: TerminalSurface, didUpdateTitle title: String) {}
    func surfaceDidRing(_ surface: TerminalSurface) {}
    func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String) {}
}

struct ConnectionTestSheet: View {
    @ObservedObject var test: ConnectionTest
    let onTestAgain: () -> Void
    let onClose: () -> Void
    /// The app's terminal appearance now (its theme resolved against the
    /// effective appearance).
    let appearance: () -> TerminalAppearance
    @StateObject private var terminal: TestTerminal
    @Environment(\.colorScheme) private var colorScheme

    /// The terminal's height: room for a host-key prompt, not a page.
    static let terminalHeight: CGFloat = 160

    init(test: ConnectionTest, surfaceFactory: TerminalSurfaceFactory,
         appearance: @autoclosure @escaping () -> TerminalAppearance,
         onTestAgain: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.test = test
        self.onTestAgain = onTestAgain
        self.onClose = onClose
        self.appearance = appearance
        _terminal = StateObject(wrappedValue: TestTerminal(surfaceFactory: surfaceFactory, appearance: appearance()))
    }

    private var isDone: Bool { test.phase == .finished || test.phase == .failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Test connection")
                    .font(.system(size: 15, weight: .semibold))
                Text(test.record.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("If ssh asks for anything, answer it here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            TerminalSurfaceHost(surface: terminal.surface)
                .frame(height: Self.terminalHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
                .padding(.top, 12)

            headline
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(test.rows) { row in CheckRowView(row: row) }
            }
            .padding(.top, test.rows.isEmpty ? 0 : 10)

            if let details = resolutionDetails {
                Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }

            // No keyboard shortcuts here: Return and Esc belong to the
            // terminal while ssh asks.
            HStack(spacing: 10) {
                Spacer()
                if isDone, test.failure?.allowsRetry ?? true {
                    Button("Test again", action: onTestAgain)
                }
                Button("Close", action: onClose)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 680)
        .onAppear { terminal.start(test) }
        .onDisappear { terminal.stop() }
        // Follows the appearance while open, as every tab's terminal does.
        .onChange(of: colorScheme) { terminal.surface.apply(appearance()) }
    }

    @ViewBuilder
    private var headline: some View {
        switch test.phase {
        case .connecting:
            progress("Connecting with your ssh…")
        case .checking:
            progress(Self.checkingLine(confirmed: test.connectionConfirmed))
        case .failed:
            Text(test.failure?.message ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .finished:
            Text(test.summary?.statusLine ?? "")
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// While checking: neutral until a query has run on the host over the
    /// master, "Connected" only after.
    static func checkingLine(confirmed: Bool) -> String {
        confirmed ? "Connected. Checking the host…" : "Checking the connection…"
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// What ssh resolved for this host (`ssh -G`), for comparing with the
    /// config.
    private var resolutionDetails: String? {
        let keys = ["user", "hostname", "port", "proxyjump"]
        let parts = keys.compactMap { key in test.resolution[key].map { "\(key) \($0)" } }
        return parts.isEmpty ? nil : "ssh -G: " + parts.joined(separator: " · ")
    }
}

private struct CheckRowView: View {
    let row: ConnectionCheckRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyph.frame(width: 14)
            Text(row.line)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let output = row.output, !output.isEmpty {
                ShowOutputLink(title: nil, output: output)
            }
        }
    }

    private var color: Color {
        switch row.verdict {
        case .problem: .red
        case .advisory: .orange
        case .running, .info: .secondary
        case .ok: .primary
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch row.verdict {
        case .running:
            ProgressView().controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
        case .advisory:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
        case .info:
            Image(systemName: "minus").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
