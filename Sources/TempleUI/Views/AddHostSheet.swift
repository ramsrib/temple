import SwiftUI
import TempleCore

/// What the Add host sheet ended with.
enum AddHostOutcome: Equatable {
    /// A config alias, turned on.
    case added(String)
    /// The full form, prefilled from what was typed (empty for Enter details…).
    case details(RemoteHostForm)
    case editConfig
    case cancelled
}

/// The Add host sheet's model (docs/designs/remote-ssh.md section 7): the
/// config's unused aliases, ranked, filtered by the field, and what `ssh -G`
/// says each resolves to. The aliases are a snapshot of the config read as
/// the sheet opened; `ssh -G` runs only for the rows shown, a few at a time,
/// once each, and stops with the sheet.
@MainActor
final class AddHostSheetModel: ObservableObject, Identifiable {
    /// Rows shown before "Show all N…".
    static let pageSize = 6
    /// `ssh -G` runs at most this many at once.
    static let maxConcurrentResolutions = 4

    /// What the field holds.
    @Published var text = "" {
        didSet { if text != oldValue { note = nil; resolveShown() } }
    }
    /// "Show all N…" was chosen: every match is shown.
    @Published private(set) var expanded = false
    /// `user@hostname` per alias, from `ssh -G`.
    @Published private(set) var destinations: [String: String] = [:]
    /// A line under the field: the typed name is a host already in use.
    @Published private(set) var note: String?
    private(set) var outcome: AddHostOutcome?

    /// The config's aliases not in use, ranked (`ranked`).
    let offered: [SSHConfigHost]
    /// The config names no host at all.
    let configIsEmpty: Bool

    private let hosts: RemoteHostsModel
    private let resolve: @Sendable (String) async -> ConnectionTest.Resolution
    private var queue: [String] = []
    private var running: [String: Task<Void, Never>] = [:]
    /// Aliases `ssh -G` could not answer for: shown without a destination.
    private(set) var unresolved: Set<String> = []
    private var closed = false

    /// Reads `~/.ssh/config` (the sheet is opening) and starts resolving
    /// the first rows.
    init(hosts: RemoteHostsModel) {
        self.hosts = hosts
        resolve = hosts.resolveAlias
        hosts.loadConfigAliases()
        let configHosts = hosts.configHosts ?? []
        let names = Set(hosts.records.map(\.name))
        configIsEmpty = configHosts.isEmpty
        offered = Self.ranked(configHosts.filter { !names.contains($0.alias) })
        resolveShown()
    }

    // MARK: What is shown

    /// Aliases that say how to log in (`User`, `IdentityFile`) first, bare
    /// names (`Host github.com`: no login, going where it says) last, the
    /// rest between; the config's order within each. Nothing is hidden.
    static func ranked(_ hosts: [SSHConfigHost]) -> [SSHConfigHost] {
        func tier(_ host: SSHConfigHost) -> Int { host.setsLogin ? 0 : host.isBare ? 2 : 1 }
        return hosts.enumerated()
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .map(\.element)
    }

    /// The aliases the field matches, ignoring case: those it starts, then
    /// those it is inside of, each in rank order. Empty: all of them.
    static func matching(_ hosts: [SSHConfigHost], query: String) -> [SSHConfigHost] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return hosts }
        let prefixed = hosts.filter { $0.alias.lowercased().hasPrefix(query) }
        let inside = hosts.filter { !$0.alias.lowercased().hasPrefix(query) && $0.alias.lowercased().contains(query) }
        return prefixed + inside
    }

    var matches: [SSHConfigHost] { Self.matching(offered, query: text) }

    /// The rows under the field: the first `pageSize` matches until Show all.
    var shown: [SSHConfigHost] {
        let matches = matches
        return expanded ? matches : Array(matches.prefix(Self.pageSize))
    }

    /// How many matches "Show all N…" would show, nil when all are shown.
    var showAllCount: Int? {
        let count = matches.count
        return !expanded && count > Self.pageSize ? count : nil
    }

    /// Why no alias is offered, with none to offer.
    var emptyNote: String? {
        if configIsEmpty { return RemoteCopy.addHostNoConfigHosts }
        return offered.isEmpty ? RemoteCopy.addHostAllInUse : nil
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func showAll() {
        expanded = true
        resolveShown()
    }

    // MARK: Ending

    /// A row: the alias is turned on at once.
    func choose(_ alias: String) {
        guard outcome == nil else { return }
        hosts.setConfigHost(alias, enabled: true)
        finish(.added(alias))
    }

    /// Return or Add: an offered alias turns on; a host already in use says
    /// so and stays; anything else is an address for the full form.
    func submit() {
        let typed = trimmedText
        guard outcome == nil, !typed.isEmpty else { return }
        if hosts.record(named: typed) != nil {
            note = RemoteCopy.addHostAlreadyInUse(typed)
        } else if offered.contains(where: { $0.alias == typed }) {
            choose(typed)
        } else {
            finish(.details(Self.form(for: typed)))
        }
    }

    func enterDetails() { finish(.details(RemoteHostForm())) }
    func editConfig() { finish(.editConfig) }
    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: AddHostOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        dismissed()
    }

    /// `user@address[:port]` or an address, as the form's fields. The name
    /// is the address's first label for a host name (the form says it
    /// can't be changed later, and checks it); empty for an IP address.
    static func form(for text: String) -> RemoteHostForm {
        var form = RemoteHostForm()
        var rest = Substring(text)
        if let at = rest.lastIndex(of: "@") {
            form.user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            form.address = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { form.port = String(after.dropFirst()) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            form.address = String(rest[..<colon])
            form.port = String(rest[rest.index(after: colon)...])
        } else {
            form.address = String(rest)
        }
        let isIP = form.address.contains(":") || form.address.allSatisfy { $0.isNumber || $0 == "." }
        if !isIP, let label = form.address.split(separator: ".").first {
            form.name = String(label)
        }
        return form
    }

    // MARK: ssh -G

    /// Queues `ssh -G` for the rows shown that have no answer yet (a row no
    /// longer shown leaves the queue) and starts what the bound allows.
    private func resolveShown() {
        guard !closed else { return }
        let shown = shown.map(\.alias)
        let visible = Set(shown)
        queue = queue.filter(visible.contains)
        for alias in shown where destinations[alias] == nil && !unresolved.contains(alias)
            && running[alias] == nil && !queue.contains(alias) {
            queue.append(alias)
        }
        pump()
    }

    private func pump() {
        while !closed, running.count < Self.maxConcurrentResolutions, !queue.isEmpty {
            let alias = queue.removeFirst()
            let resolve = resolve
            running[alias] = Task { [weak self] in
                // Off the main actor: `resolve` is nonisolated.
                let answer = await resolve(alias)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.running[alias] = nil
                if case .resolved(let values) = answer, let destination = Self.destination(values) {
                    self.destinations[alias] = destination
                } else {
                    self.unresolved.insert(alias)
                }
                self.pump()
            }
        }
    }

    /// `user@hostname` from `ssh -G`'s answer.
    static func destination(_ values: [String: String]) -> String? {
        guard let host = values["hostname"], !host.isEmpty else { return nil }
        guard let user = values["user"], !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }

    /// The sheet is gone: every `ssh -G` still running is cancelled (and
    /// with it its process), and nothing more starts.
    func dismissed() {
        closed = true
        queue = []
        for task in running.values { task.cancel() }
        running = [:]
    }

    /// For tests: resolutions running or waiting.
    var pendingResolutions: Int { running.count + queue.count }
}

/// Add host… (section 7): the folder sheet's shape. One field, the config's
/// unused aliases as links under it (each with where ssh says it goes), the
/// full form and the config behind two links. A row adds its alias at
/// once; Return adds what the field holds.
///
/// Layout as for the rest of the app's sheets (AGENTS.md): no `.fixedSize`,
/// `List` or `Form`, no scroll view (Show all grows the sheet).
struct AddHostSheet: View {
    @ObservedObject var sheet: AddHostSheetModel
    let onFinish: (AddHostOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteCopy.addHostTitle)
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(RemoteCopy.addHostFieldLabel).font(.system(size: 12))
                // The folder sheet's field: plain, on the control fill.
                TextField("", text: $sheet.text, prompt: Text(RemoteCopy.addHostPlaceholder))
                    .accessibilityLabel(RemoteCopy.addHostFieldLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .focused($focused)
                    .onSubmit { act { sheet.submit() } }
                if let note = sheet.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            aliases
            HStack(spacing: 6) {
                Text(RemoteCopy.addHostNotInConfig).foregroundStyle(.secondary)
                Button(RemoteCopy.addHostEnterDetails) { act { sheet.enterDetails() } }
                    .buttonStyle(.link)
                Spacer(minLength: 12)
                Button(RemoteCopy.addHostEditConfig) { act { sheet.editConfig() } }
                    .buttonStyle(.link)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.top, 4)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { act { sheet.cancel() } }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { act { sheet.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheet.trimmedText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { focused = true }
        // Closed any way at all: every ssh -G still running stops.
        .onDisappear { sheet.dismissed() }
    }

    @ViewBuilder
    private var aliases: some View {
        if let empty = sheet.emptyNote {
            Text(empty)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            let shown = sheet.shown
            if !shown.isEmpty || sheet.showAllCount != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                        ForEach(shown, id: \.alias) { host in
                            GridRow {
                                Button(host.alias) { act { sheet.choose(host.alias) } }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // The same click: the whole row adds the alias.
                                Button { act { sheet.choose(host.alias) } } label: {
                                    Text(sheet.destinations[host.alias] ?? "")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(sheet.destinations[host.alias] == nil)
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    if let count = sheet.showAllCount {
                        Button(RemoteCopy.addHostShowAll(count)) { sheet.showAll() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    /// Runs a sheet action; if it ended the sheet, says how and closes,
    /// once (Return reaches both the field and the default button).
    private func act(_ action: () -> Void) {
        guard sheet.outcome == nil else { return }
        action()
        guard let outcome = sheet.outcome else { return }
        onFinish(outcome)
        dismiss()
    }
}
