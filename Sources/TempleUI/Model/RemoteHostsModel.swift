import Foundation
import TempleCore

/// The Hosts connection manager's model (docs/designs/remote-ssh.md
/// section 7): the enabled hosts, the aliases `~/.ssh/config` offers, and
/// what each host's last Test connection found.
///
/// Settings layers (AGENTS.md): the host list is the user layer, the only
/// thing persisted, under `temple.settings.remoteHosts` in Temple's own
/// settings domain (`TempleState.settingsDefaults`, so a demo's list follows
/// `TEMPLE_DEFAULTS_SUITE`). Test results, the config's aliases and
/// anything ssh resolves are memory only and recomputed.
///
/// No flag: remote is invisible until a host is enabled. With the list
/// empty the app registers no remote host, reads no ssh config (until the
/// Hosts card is shown) and runs nothing; every remote surface (⌘N's and
/// the launcher's host rows, the shortcuts note, the sidebar's notices)
/// appears only for an enabled host (`hasHosts`). The key of the old flag
/// (`temple.feature.remoteHosts`) is ignored.
@MainActor
public final class RemoteHostsModel: ObservableObject {
    static let hostsKey = "temple.settings.remoteHosts"

    /// The enabled hosts, in the order they were added.
    @Published private(set) var records: [RemoteHostRecord]
    /// Aliases in `~/.ssh/config` (nil until read).
    @Published private(set) var configAliases: [String]?
    /// Each host's last Test connection, by name; memory only.
    @Published private(set) var summaries: [String: HostTestSummary] = [:]

    /// The enabled list changed: the registry is rebuilt from it.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let readConfigAliases: () -> [String]
    private let stateDirectory: () -> URL
    private let makeTest: @MainActor (RemoteHostRecord, URL) -> ConnectionTest
    /// The test in progress, per host, so Remove, Disable and Edit can stop it.
    private var running: [String: ConnectionTest] = [:]

    init(defaults: UserDefaults,
         readConfigAliases: @escaping () -> [String] = RemoteHostComposition.configAliases,
         stateDirectory: @escaping () -> URL = { TempleState.directory },
         makeTest: @escaping @MainActor (RemoteHostRecord, URL) -> ConnectionTest = {
             RemoteHostComposition.connectionTest(for: $0, stateDirectory: $1)
         }) {
        self.defaults = defaults
        self.readConfigAliases = readConfigAliases
        self.stateDirectory = stateDirectory
        self.makeTest = makeTest
        records = Self.load(defaults).records
    }

    /// The hosts the registry carries: every enabled one, tested or not.
    var registeredHosts: [RemoteHostRecord] { records }

    /// At least one host is enabled: only then does any remote UI appear.
    var hasHosts: Bool { !records.isEmpty }

    func record(named name: String) -> RemoteHostRecord? { records.first { $0.name == name } }

    // MARK: ~/.ssh/config

    /// Reads the aliases now (on showing the Hosts card, and on request).
    func loadConfigAliases() {
        configAliases = readConfigAliases()
    }

    /// A config alias turned on or off in Temple.
    func setConfigHost(_ alias: String, enabled: Bool) {
        if enabled {
            guard record(named: alias) == nil else { return }
            mutate { $0.append(.config(alias)) }
        } else {
            remove(alias)
        }
    }

    // MARK: Hosts added in Temple

    /// Adds `record`, or replaces the one named `editing`. An edit forgets
    /// the last test: it was about the old address.
    func save(_ record: RemoteHostRecord, editing: String?) {
        if let editing {
            stopTest(editing)
            summaries[editing] = nil
            mutate { list in
                if let index = list.firstIndex(where: { $0.name == editing }) { list[index] = record }
            }
        } else {
            guard self.record(named: record.name) == nil else { return }
            mutate { $0.append(record) }
        }
    }

    /// Removes a host (or disables a config alias): its test stops, its
    /// engine and entry go. Its master, if any, is left to expire.
    func remove(_ name: String) {
        stopTest(name)
        summaries[name] = nil
        mutate { $0.removeAll { $0.name == name } }
    }

    // MARK: Tests

    /// A new Test connection for a host; its result is kept when it ends.
    func startTest(for name: String) -> ConnectionTest? {
        guard let record = record(named: name) else { return nil }
        stopTest(name)
        let test = makeTest(record, stateDirectory())
        test.onFinished = { [weak self, weak test] summary in
            guard let self, let test, self.running[name] === test else { return }
            self.recordSummary(summary, for: name)
        }
        running[name] = test
        return test
    }

    /// A finished test's findings, kept for this run only.
    func recordSummary(_ summary: HostTestSummary, for name: String) {
        guard record(named: name) != nil else { return }
        summaries[name] = summary
    }

    /// The sheet closed.
    func endTest(_ test: ConnectionTest) {
        test.cancel()
        if running[test.record.name] === test { running[test.record.name] = nil }
    }

    private func stopTest(_ name: String) {
        running.removeValue(forKey: name)?.cancel()
    }

    func statusLine(for name: String) -> String {
        summaries[name]?.statusLine ?? HostTestSummary.notTested
    }

    /// `.unavailable` only when a test connected and the CLI or tmux did not
    /// run; `.available` otherwise, untested and unreachable included.
    func availability(of name: String, agent: Agent) -> LaunchAvailability {
        guard let reason = summaries[name]?.unavailableReason(for: agent) else { return .available }
        return .unavailable(reason: reason)
    }

    // MARK: Persistence

    /// Read-modify-write against what is stored now, one key: an entry
    /// another Temple on the same domain added since this one loaded
    /// survives, and an entry this build cannot read is written back
    /// untouched. Not a transaction across processes (UserDefaults has
    /// none): two writes in the same instant can still lose one.
    private func mutate(_ change: (inout [RemoteHostRecord]) -> Void) {
        var list = Self.load(defaults)
        change(&list.records)
        defaults.set(list.encode(), forKey: Self.hostsKey)
        records = list.records
        onChange?()
    }

    static func load(_ defaults: UserDefaults) -> RemoteHostList {
        switch defaults.object(forKey: hostsKey) {
        case let data as Data: return RemoteHostList.decode(data)
        case let text as String: return RemoteHostList.decode(Data(text.utf8))
        default: return RemoteHostList()
        }
    }
}
