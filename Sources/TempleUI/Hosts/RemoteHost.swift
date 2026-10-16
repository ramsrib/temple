import Foundation
import TempleCore
import TempleRemoteHost

// The one place TempleUI names `TempleRemoteHost` (docs/designs/
// remote-ssh.md section 6; `ModuleBoundaryTests` asserts it). The rest of
// the app reaches a remote host through `HostRegistry`, and the Hosts
// connection manager through the names below. Deleting remote means
// deleting the module, this file, the Hosts views and `RemoteHostsModel`.

typealias RemoteHostRecord = TempleRemoteHost.RemoteHostRecord
typealias RemoteHostList = TempleRemoteHost.RemoteHostList
typealias RemoteHostForm = TempleRemoteHost.RemoteHostForm
typealias HostTestSummary = TempleRemoteHost.HostTestSummary
typealias ConnectionTest = TempleRemoteHost.ConnectionTest
typealias SSHFailure = TempleRemoteHost.SSHFailure
typealias RemoteHostFormField = TempleRemoteHost.RemoteHostForm.Field
typealias ConnectionCheckRow = TempleRemoteHost.ConnectionTest.Row

extension HostRegistry.Entry {
    /// An enabled host's entry, registered whether or not it was tested.
    /// Its source runs nothing (phase 0); its launcher refuses to launch
    /// until sessions on hosts exist, and reports what a test proved.
    @MainActor static func remote(_ record: RemoteHostRecord,
                                  availability: @escaping (Agent) -> LaunchAvailability) -> HostRegistry.Entry {
        HostRegistry.Entry(source: RemoteSessionSource(host: record.host),
                           launcher: RemoteHostLauncher(host: record.host, availability: availability))
    }
}

/// A host's launcher before sessions on hosts exist. `availability` is the
/// last test's proof (`.unavailable` only when a test connected and a CLI
/// or tmux did not run).
@MainActor
final class RemoteHostLauncher: HostLauncher {
    let host: HostID
    private let check: (Agent) -> LaunchAvailability

    init(host: HostID, availability: @escaping (Agent) -> LaunchAvailability) {
        self.host = host; self.check = availability
    }

    func availability(_ agent: Agent) -> LaunchAvailability { check(agent) }

    func prepare(_ spec: AgentLaunchSpec) throws -> AgentLaunch {
        throw HostLaunchError.unavailable(reason: "Temple can't start sessions on \(host.rawValue) yet.")
    }
}

enum RemoteHostComposition {
    /// Every process the remote module has started in this process.
    static var processLaunches: Int { RemoteProcessCounter.launches }

    /// The aliases in the user's `~/.ssh/config`, read-only, one level of
    /// `Include`. Called only by the Hosts connection manager, and only
    /// while the feature is on.
    static func configAliases() -> [String] {
        let ssh = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
        return SSHConfigHosts.load(configURL: ssh.appendingPathComponent("config"), sshDirectory: ssh)
    }

    /// The user's ssh: the login shell's, else the system's.
    static var sshPath: String { LoginShellEnvironment.locate("ssh") ?? "/usr/bin/ssh" }

    /// A Test connection for `record`, over the user's ssh, with its master
    /// socket under `stateDirectory`.
    @MainActor
    static func connectionTest(for record: RemoteHostRecord, stateDirectory: URL) -> ConnectionTest {
        let connection = SSHConnection(record: record, stateDirectory: stateDirectory, sshPath: sshPath)
        let argv = connection.resolutionArgv
        return ConnectionTest(record: record, connection: connection,
                              makeExec: { SSHExec(connection: connection, path: $0) },
                              resolve: {
                                  guard let output = try? await ProcessRunner.run(argv[0], Array(argv.dropFirst()), deadline: 5),
                                        output.status == 0 else { return [:] }
                                  return ConnectionTest.parseResolution(output.stdout)
                              })
    }
}
