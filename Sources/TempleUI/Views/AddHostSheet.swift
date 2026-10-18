import AppKit
import Combine
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
/// config's unused aliases, ranked and filtered by the field, each with the
/// `user@hostname` its own blocks set. The config is read again as the
/// sheet opens, off the main actor; the rows follow it. Nothing is run to show it: `ssh -G` would evaluate a
/// config's `Match exec` commands for aliases nobody chose, so it runs only
/// where it already did, for a host being tested or used.
@MainActor
final class AddHostSheetModel: ObservableObject, Identifiable {
    /// Rows shown before "Show N more".
    static let pageSize = 6

    /// What the field holds.
    @Published var text = "" {
        didSet { if text != oldValue { note = nil; waitingForConfig = false } }
    }
    /// "Show N more" was chosen: every match is shown.
    @Published private(set) var expanded = false
    /// A line under the field: the typed name is in use, or can't be read.
    @Published private(set) var note: String?
    /// How the sheet ended; the view closes on it.
    @Published private(set) var outcome: AddHostOutcome?
    /// Return came while the config was still being read: it is decided
    /// once the read ends (an alias not yet listed is not an address).
    /// Typing again drops it.
    @Published private(set) var waitingForConfig = false

    /// The config's aliases not in use, ranked (`ranked`).
    @Published private(set) var offered: [SSHConfigHost] = []
    /// The config has been read (by this sheet or the card before it).
    @Published private(set) var configKnown = false
    /// The config names no host at all.
    @Published private(set) var configIsEmpty = false

    private let hosts: RemoteHostsModel
    private var subscriptions: [AnyCancellable] = []
    /// The model's read is under way (as published: set before the
    /// model's own property is).
    private var reading = false

    /// Reads `~/.ssh/config`: the sheet is opening. Until the read ends,
    /// the rows are what the card's read found.
    init(hosts: RemoteHostsModel) {
        self.hosts = hosts
        // Published as it is set: the value given is the new one.
        subscriptions.append(hosts.$configHosts.sink { [weak self] configHosts in self?.update(configHosts) })
        // The hosts are published before the read is said to be over, so
        // a waiting Return is decided against the new list.
        subscriptions.append(hosts.$configReading.sink { [weak self] reading in self?.readingChanged(reading) })
        hosts.loadConfigAliases()
    }

    private func readingChanged(_ reading: Bool) {
        self.reading = reading
        guard !reading, waitingForConfig else { return }
        waitingForConfig = false
        submit()
    }

    private func update(_ configHosts: [SSHConfigHost]?) {
        guard let configHosts else { return }
        let names = Set(hosts.records.map(\.name))
        configKnown = true
        configIsEmpty = configHosts.isEmpty
        offered = Self.ranked(configHosts.filter { !names.contains($0.alias) })
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

    /// The rows under the field: the first `pageSize` matches until Show more.
    var shown: [SSHConfigHost] {
        let matches = matches
        return expanded ? matches : Array(matches.prefix(Self.pageSize))
    }

    /// How many matches are not shown, nil when all are.
    var hiddenCount: Int? {
        let hidden = matches.count - shown.count
        return hidden > 0 ? hidden : nil
    }

    /// Why no alias is offered, with none to offer.
    var emptyNote: String? {
        guard configKnown else { return nil }
        if configIsEmpty { return RemoteCopy.addHostNoConfigHosts }
        return offered.isEmpty ? RemoteCopy.addHostAllInUse : nil
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func showAll() { expanded = true }

    /// What Return (and the default button) would do with the text now:
    /// open the form for an address. False for nothing typed, an added
    /// host, an alias, or text that can't be read as an address.
    var readsAsAddress: Bool {
        let typed = trimmedText
        guard !typed.isEmpty else { return false }
        let names = hosts.records.map(\.name) + offered.map(\.alias)
        guard !names.contains(where: { $0.lowercased() == typed.lowercased() }) else { return false }
        return Self.form(for: typed) != nil
    }

    /// The default button's label: Add for an alias (or nothing typed),
    /// the form's name for an address (it opens the form, prefilled).
    var defaultActionTitle: String { readsAsAddress ? RemoteCopy.addHostByAddress : RemoteCopy.addHostAdd }

    // MARK: Ending

    /// A row: the alias is turned on at once.
    func choose(_ alias: String) {
        guard outcome == nil else { return }
        hosts.setConfigHost(alias, enabled: true)
        outcome = .added(alias)
    }

    /// Return or Add. A name is looked up exactly first, then ignoring case
    /// when that finds just one (the list filters ignoring case): an offered
    /// alias turns on, a host in use says so and the sheet stays. Anything
    /// else is an address for the full form, or, unreadable as one, stays
    /// in the field with a note.
    func submit() {
        let typed = trimmedText
        guard outcome == nil, !typed.isEmpty else { return }
        guard !reading else {
            waitingForConfig = true
            return
        }
        let inUse = hosts.records.map(\.name)
        let aliases = offered.map(\.alias)
        func unique(_ names: [String]) -> String? {
            let found = names.filter { $0.lowercased() == typed.lowercased() }
            return found.count == 1 ? found[0] : nil
        }
        if inUse.contains(typed) {
            note = RemoteCopy.addHostAlreadyInUse(typed)
        } else if aliases.contains(typed) {
            choose(typed)
        } else if let alias = unique(aliases) {
            choose(alias)
        } else if let name = unique(inUse) {
            note = RemoteCopy.addHostAlreadyInUse(name)
        } else if let form = Self.form(for: typed) {
            outcome = .details(form)
        } else {
            note = RemoteCopy.addHostUnreadable
        }
    }

    func enterDetails() { finish(.details(RemoteHostForm())) }
    func editConfig() { finish(.editConfig) }
    func cancel() { finish(.cancelled) }

    private func finish(_ outcome: AddHostOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
    }

    /// `user@address[:port]` or an address, as the form's fields; nil when
    /// it can't be read as one (the form then checks each field itself). An
    /// IPv6 address takes brackets for a port, and the bracket must end the
    /// text or come right before the `:port`. The name is the address's
    /// first label for a host name (the form says it can't be changed
    /// later); empty for an IP address.
    static func form(for text: String) -> RemoteHostForm? {
        guard !text.contains(where: \.isWhitespace), text.filter({ $0 == "@" }).count <= 1 else { return nil }
        var form = RemoteHostForm()
        var rest = Substring(text)
        if let at = rest.firstIndex(of: "@") {
            form.user = String(rest[..<at])
            guard !form.user.isEmpty else { return nil }
            rest = rest[rest.index(after: at)...]
        }
        func isPort(_ text: Substring) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            form.address = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), isPort(after.dropFirst()) else { return nil }
                form.port = String(after.dropFirst())
            }
        } else {
            guard !rest.contains("["), !rest.contains("]") else { return nil }
            if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
                let port = rest[rest.index(after: colon)...]
                guard isPort(port) else { return nil }
                form.address = String(rest[..<colon])
                form.port = String(port)
            } else {
                form.address = String(rest)
            }
        }
        guard !form.address.isEmpty, !form.address.contains("[") else { return nil }
        let isIP = form.address.contains(":") || form.address.allSatisfy { $0.isNumber || $0 == "." }
        if !isIP, let label = form.address.split(separator: ".").first {
            form.name = String(label)
        }
        return form
    }
}

/// Add host… (section 7): the remote sheets' chrome. One field, a caption
/// saying a row adds its host at once, the config's unused aliases under
/// it (each with the `user@hostname` its own blocks set), then the form for
/// an address and the config behind two links. Return adds what the field
/// holds; the default button says which it will do (Add, or Add host by
/// address…).
///
/// Layout as for the rest of the app's sheets (AGENTS.md): no `.fixedSize`,
/// `List` or `Form`, no scroll view (Show more grows the sheet).
struct AddHostSheet: View {
    @ObservedObject var sheet: AddHostSheetModel
    let onFinish: (AddHostOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var finished = false

    /// The alias column: fixed, so the destinations stay put whichever rows
    /// show (sized to the widest alias shown, it moved as the list filtered).
    static let aliasColumn: CGFloat = 200

    var body: some View {
        RemoteSheetChrome {
            RemoteSheetTitle(title: RemoteCopy.addHostTitle)
            RemoteFormRow(label: RemoteCopy.addHostFieldLabel) {
                TextField("", text: $sheet.text, prompt: Text(RemoteCopy.addHostPlaceholder))
                    .accessibilityLabel(RemoteCopy.addHostFieldLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { act { sheet.submit() } }
                    .templeFieldChrome(focused: focused)
                if let note = sheet.note { RemoteHint(note) }
            }
            aliases
            HStack(spacing: 6) {
                // While the default button reads "Add host by address…", the
                // same words here would read as a second, different action.
                if !sheet.readsAsAddress {
                    Text(RemoteCopy.addHostNotInConfig).foregroundStyle(.secondary)
                    Button(RemoteCopy.addHostEnterDetails) { act { sheet.enterDetails() } }
                        .buttonStyle(.neutralLink)
                }
                Spacer(minLength: 12)
                Button(RemoteCopy.addHostEditConfig) { act { sheet.editConfig() } }
                    .buttonStyle(.neutralLink)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.top, 4)
            HStack(spacing: 8) {
                if sheet.waitingForConfig {
                    // Return waits for the config's read to end.
                    ProgressView().controlSize(.small)
                    Text(RemoteCopy.addHostReadingConfig)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { act { sheet.cancel() } }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.defaultActionTitle) { act { sheet.submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sheet.trimmedText.isEmpty || sheet.waitingForConfig)
            }
            .padding(.top, 8)
        }
        .onAppear { focused = true }
        // Ended now or, for a Return that waited for the config, later.
        .onChange(of: sheet.outcome) {
            guard let outcome = sheet.outcome, !finished else { return }
            finished = true
            onFinish(outcome)
            dismiss()
        }
    }

    @ViewBuilder
    private var aliases: some View {
        if let empty = sheet.emptyNote {
            Text(empty)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            let shown = sheet.shown
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    RemoteListCaption(RemoteCopy.addHostListCaption)
                        .padding(.leading, 6)
                        .padding(.bottom, 2)
                    ForEach(shown, id: \.alias) { host in row(host) }
                    if let hidden = sheet.hiddenCount {
                        Button(RemoteCopy.addHostShowMore(hidden)) { sheet.showAll() }
                            .buttonStyle(.neutralLink)
                            .font(.system(size: 11))
                            .padding(.leading, 6)
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// One click target across the row: the alias (12 medium, primary),
    /// its destination (11 mono, secondary), or a tertiary note that its
    /// blocks set neither.
    private func row(_ host: SSHConfigHost) -> some View {
        RemoteListRow(action: { act { sheet.choose(host.alias) } }) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(host.alias)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.aliasColumn, alignment: .leading)
                Group {
                    if let destination = host.destination {
                        Text(destination)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(RemoteCopy.addHostNoDestination)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(host.destination.map { "\(host.alias), \($0)" } ?? host.alias)
    }

    /// Runs a sheet action unless the sheet has ended (Return reaches both
    /// the field and the default button); an ending closes it (`onChange`).
    private func act(_ action: () -> Void) {
        guard sheet.outcome == nil else { return }
        action()
    }
}
