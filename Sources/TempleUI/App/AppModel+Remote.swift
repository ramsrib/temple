import Foundation
import TempleCore

/// A line at the foot of the rail about sessions left running on a host.
public struct RemoteNotice: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// A close could not stop the session (shown once, at the close).
        case closed
        /// Found at launch: `count` sessions are flagged on a host that just
        /// answered (shown once per flag).
        case count(Int)
    }
    public let id = UUID()
    public let host: HostID
    public let message: String
    public let kind: Kind
    public init(host: HostID, message: String, kind: Kind) {
        self.host = host; self.message = message; self.kind = kind
    }
}

/// "Sessions on <host>" for one host.
public struct RemoteSessionsRequest: Identifiable, Equatable {
    public let id = UUID()
    public let host: HostID
}

/// The folder sheet for a new session on a host.
public struct RemoteFolderRequest: Identifiable, Equatable {
    public let id = UUID()
    public let host: HostID
    public let agent: Agent
}

extension AppModel {
    /// The launcher of a registered remote host.
    func remoteHost(_ host: HostID) -> RemoteSessionHost? {
        hostRegistry.entry(for: host)?.launcher as? RemoteSessionHost
    }

    /// Hosts a new session can start on: every enabled host whose last
    /// test did not prove tmux missing, in the order they were added.
    public var remoteLaunchHosts: [HostID] {
        remoteHosts.registeredHosts.filter { !(remoteHosts.summaries[$0.name]?.provesTmuxMissing ?? false) }
            .map(\.host).filter { remoteHost($0) != nil }
    }

    /// The sidebar's Show: the sheet for that host. A count line is then
    /// acted on, and never comes back for the same flags.
    public func showRemoteSessions(_ host: HostID) {
        if case .count? = remoteNotice?.kind, remoteNotice?.host == host {
            remoteHost(host)?.noticeLeftRunning()
            remoteNotice = nil
        }
        remoteSessionsSheet = RemoteSessionsRequest(host: host)
    }

    public func dismissRemoteNotice() {
        guard let notice = remoteNotice else { return }
        if case .count = notice.kind { remoteHost(notice.host)?.noticeLeftRunning() }
        remoteNotice = nil
    }

    /// At launch, a host with sessions flagged left running (whose line has
    /// not been shown) is asked once, by listing Temple's private server;
    /// when it answers, the line says how many are still left running.
    /// Nothing is stopped: the listing only lists.
    func contactHostsWithSessionsLeftRunning() {
        guard remoteHosts.isEnabled else { return }
        for host in remoteHosts.registeredHosts.map(\.host) {
            guard let launcher = remoteHost(host), launcher.unnoticedLeftRunningCount() > 0 else { continue }
            Task { @MainActor [weak self] in
                guard case .sessions = await launcher.listSessions() else { return }
                let count = launcher.unnoticedLeftRunningCount()
                guard let self, count > 0, self.remoteNotice == nil else { return }
                self.remoteNotice = RemoteNotice(host: host, message: RemoteCopy.leftRunningCount(count, host: host.rawValue),
                                                 kind: .count(count))
            }
        }
    }

    /// ⌘N's and the launcher's "Folder on <host>…".
    public func chooseRemoteFolder(host: HostID, agent: Agent? = nil) {
        newSessionPickerPresented = false
        remoteFolderSheet = RemoteFolderRequest(host: host, agent: agent ?? settings.defaultAgent)
    }

    /// The host's recent folders, from its rows: most recent first.
    public func recentRemoteFolders(_ host: HostID) -> [String] {
        var seen = Set<String>()
        return sessions.filter { $0.host == host }
            .sorted { $0.sortDate > $1.sortDate }
            .compactMap(\.directory).filter { seen.insert($0).inserted }
    }

    /// The folder sheet confirmed a folder: a new session there. What the
    /// sheet resolved is intent; the row records a folder only from the
    /// pane's `ok`.
    public func startRemoteSession(host: HostID, agent: Agent, folder: String) {
        remoteFolderSheet = nil
        openSessions.newSession(agent: agent, project: ProjectKey(host: host, path: folder))
    }
}
