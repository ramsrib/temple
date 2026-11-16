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
/// Settings' Hosts section: how many hosts Temple has, and Manage Hosts…,
/// which opens the hosts manager (`HostsManagerSheet`). The list itself used
/// to live here, four bordered buttons a host wrapping differently per name;
/// hosts are a working thing, not a preference, so they got their own panel
/// (docs/designs/ux-pass-2026-11.md section 5). Always shown: with no host
/// enabled this is still the one remote surface, and the way to add one.
///
/// Layout rules as for the rest of Settings (AGENTS.md, the split view's
/// titlebar inset): no `.fixedSize`, `.allowsHitTesting`, `layoutPriority`,
/// `List` or `Form`.
struct HostsSettingsSection: View {
    /// The notes under the section, folded until asked for.
    @State private var notesShown = false
    @EnvironmentObject var model: AppModel
    @ObservedObject var hosts: RemoteHostsModel
    /// Codex's arguments as set above: whether they carry `--no-daemon`.
    var codexArguments: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRule("Hosts")
            // The hosts themselves, each with its last test's dot, not a
            // count under a label that repeated the section's title (owner,
            // round 3). Changes happen in the manager.
            VStack(alignment: .leading, spacing: 0) {
                let records = Self.inUse(hosts.records)
                if records.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.emptyLine)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Add Host…") { model.showHostsManager(adding: true) }
                            .buttonStyle(.temple)
                    }
                } else {
                    // A grouped list, System Settings' shape: one box,
                    // rows split by hairlines, each opening the manager on
                    // its host (owner, round 3: a bare list read as bullets).
                    VStack(spacing: 0) {
                        ForEach(Array(records.prefix(Self.listed).enumerated()), id: \.element.id) { index, record in
                            if index > 0 {
                                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 32)
                            }
                            SettingsHostRow(record: record, tone: HostsManagerSheet.tone(hosts.summaries[record.name])) {
                                model.showHostsManager(selecting: record.name)
                            }
                        }
                        if records.count > Self.listed {
                            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 32)
                            Button { model.showHostsManager() } label: {
                                Text("and \(records.count - Self.listed) more")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 32)
                                    .frame(height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
                    HStack {
                        Spacer()
                        Button("Manage Hosts…") { model.showHostsManager() }
                            .buttonStyle(.temple)
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.vertical, 14)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            // The notes fold away behind one line (owner, round 3: two
            // paragraphs of small print made the page look weird); open,
            // each is a point of its own.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { notesShown.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(notesShown ? 90 : 0))
                        .frame(width: 10)
                    Text(Self.notesTitle)
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            if notesShown {
                VStack(alignment: .leading, spacing: 8) {
                    note(Self.flagsAsCode(Self.argumentsNote))
                    note(Self.noDaemonHint(enabled: codexArguments.contains("--no-daemon")))
                }
                .padding(.top, 8)
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .padding(.top, 26)
    }

    static let notesTitle = "How hosts use your agent arguments"

    private func note(_ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.tertiary)
            Text(text)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    static func summary(_ count: Int) -> String {
        switch count {
        case 0: inUseEmpty
        case 1: "1 host"
        default: "\(count) hosts"
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
    /// With no host yet: what a host is for, beside Add Host….
    static let emptyLine = "No hosts yet. Add a machine you reach with ssh to run sessions there."
    /// Hosts listed before "and N more".
    static let listed = 5

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

/// One host in Settings' list: its last test's dot, name and address, the
/// dot in words at the trailing edge, and a chevron: the row opens the
/// hosts manager on it.
private struct SettingsHostRow: View {
    let record: RemoteHostRecord
    let tone: HostsManagerSheet.Tone
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                HostStatusDot(tone: tone)
                    .frame(width: 12)
                Text(record.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(record.source == .config ? HostsSettingsSection.Caption.sshConfig.text : record.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(HostsManagerSheet.toneLabel(tone))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(hovering ? Palette.hoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(record.name) in the hosts manager")
    }
}

