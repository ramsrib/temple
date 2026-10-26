import Foundation
import SwiftUI
import TempleCore

/// A line at the foot of the rail about sessions left running on a host.
public struct RemoteNotice: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// A close could not stop the session (shown once, at the close).
        case closed
        /// Found at launch: these runs (those a close left running, those
        /// whose tab was connected at the quit) are flagged on a host that
        /// just answered, and were running there and not open in a tab
        /// (shown once per flag). A run stopped or reattached since is
        /// taken out before the line shows, or while it does.
        case count(closed: [String], quit: [String])
     }

    /// The launch line for a host's flagged runs, or nil with none left.
    static func count(host: HostID, closed: [String], quit: [String]) -> RemoteNotice? {
        guard !closed.isEmpty || !quit.isEmpty else { return nil }
        let lines = [closed.isEmpty ? nil : RemoteCopy.leftRunningCount(closed.count, host: host.rawValue),
                     quit.isEmpty ? nil : RemoteCopy.quitCount(quit.count, host: host.rawValue)]
        return RemoteNotice(host: host, message: lines.compactMap { $0 }.joined(separator: " "),
                            kind: .count(closed: closed, quit: quit))
    }
    public let id = UUID()
    public let host: HostID
    public let message: String
    public let kind: Kind
    public init(host: HostID, message: String, kind: Kind) {
        self.host = host; self.message = message; self.kind = kind
    }

    /// The line says a session is (or may be) still running there: orange.
    public var saysStillRunning: Bool {
        if case .count = kind { return true }
        return message.hasSuffix(RemoteCopy.mayStillBeRunning)
    }
}

/// "Running sessions on <host>" for one host.
public struct RemoteSessionsRequest: Identifiable, Equatable {
    public let id = UUID()
    public let host: HostID
}

/// Remove found Temple-started sessions still running on the host it is
/// about to remove (either kind of host): the alert asks whether to leave
/// them running or stop them first.
public struct RemoteRemoval: Identifiable, Equatable {
    public let id = UUID()
    public let name: String
    /// The host came from `~/.ssh/config` (the file is not changed).
    public let fromConfig: Bool
    /// Running, in a tab here or not.
    public let live: [RemoteTrackedSession]
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

    /// Every registered remote host (none until a host is enabled).
    var remoteHostIDs: [HostID] {
        hostRegistry.entries.compactMap { $0.launcher is RemoteSessionHost ? $0.source.host : nil }
    }

    /// What Discard does to this session's row: archived (the user named,
    /// pinned or colored it, or it has a transcript or was imported), or
    /// removed. Said in Discard's help tag.
    public func discardArchives(_ sessionID: String) -> Bool {
        guard let row = overlay.rows[sessionID] else { return false }
        return row.pinned || row.archived || row.customName != nil || row.color != nil
            || row.transcriptPath != nil || row.joinedVia != .created
    }

    /// Why a sidebar row's Archive is disabled, said in its place: its tab
    /// is open, or (on a host) its agent still runs there. Nil: it can be
    /// archived.
    public func archiveBlocker(_ session: Session) -> String? {
        if openSessions.openTab(forSessionID: session.id) != nil { return "Close tab to archive" }
        if !session.host.isLocal, openSessions.remoteTabs.hasRun(sessionID: session.id, host: session.host) {
            return RemoteCopy.stopToArchive(session.host.rawValue)
        }
        return nil
    }

    /// Hosts a new session can start on: every enabled host whose last
    /// test did not prove tmux missing or older than 3.2 (the tmux rule),
    /// in the order they were added.
    public var remoteLaunchHosts: [HostID] {
        remoteHosts.registeredHosts.filter { !(remoteHosts.summaries[$0.name]?.provesTmuxUnusable ?? false) }
            .map(\.host).filter { remoteHost($0) != nil }
    }

    /// The tmux rule's line for a host, when its last test proved no
    /// session can start there; nil otherwise.
    public func remoteTmuxProblem(_ host: HostID) -> String? {
        remoteHosts.summaries[host.rawValue]?.tmuxProblem
    }

    /// The sidebar's Show: the sheet for that host. A count line is then
    /// acted on, and never comes back for the same flags.
    public func showRemoteSessions(_ host: HostID) {
        // Only for an enabled host: a notice or menu of one that is gone
        // opens nothing.
        guard remoteHost(host) != nil else {
            dropRemoteNotices(host: host)
            return
        }
        if case .count? = remoteNotice?.kind, remoteNotice?.host == host, let launcher = remoteHost(host) {
            advanceRemoteNotice()
            openSessions.remoteTabs.operations.run(host: host, .write) { await launcher.noticeLeftRunning() }
        }
        remoteSessionsSheet = RemoteSessionsRequest(host: host)
    }

    /// One line at a time: a notice that arrives while one shows waits its
    /// turn, so a second host's launch count, or a close's notice during
    /// the launch line, is not lost.
    func showRemoteNotice(_ notice: RemoteNotice) {
        guard let notice = current(notice) else { return }
        if remoteNotice == nil { remoteNotice = notice } else { queuedRemoteNotices.append(notice) }
    }

    /// The shown notice goes; the next waiting one that still holds, if
    /// any, takes its place.
    private func advanceRemoteNotice() {
        remoteNotice = nil
        while !queuedRemoteNotices.isEmpty, remoteNotice == nil {
            remoteNotice = current(queuedRemoteNotices.removeFirst())
        }
    }

    /// A count line as of now: a run stopped since (its stop confirmed) or
    /// open in a tab here is taken out; nil once none is left. A close's
    /// notice is as it was said.
    private func current(_ notice: RemoteNotice) -> RemoteNotice? {
        guard case .count(let closed, let quit) = notice.kind else { return notice }
        let stopped = stoppedRemoteHandles[notice.host] ?? []
        let tabs = openSessions.remoteTabs
        func still(_ handle: String) -> Bool { !stopped.contains(handle) && !tabs.hasLiveTab(handle: handle, host: notice.host) }
        return RemoteNotice.count(host: notice.host, closed: closed.filter(still), quit: quit.filter(still))
    }

    /// A run's stop was confirmed: a line counting it, shown or waiting,
    /// counts it no more (a line left with nothing goes). The flags
    /// themselves are the store's: the stop cleared this run's.
    func remoteRunEnded(host: HostID, handle: String) {
        stoppedRemoteHandles[host, default: []].insert(handle)
        queuedRemoteNotices = queuedRemoteNotices.compactMap(current)
        if let shown = remoteNotice, shown.host == host {
            if let updated = current(shown) {
                if updated.message != shown.message { remoteNotice = updated }
            } else {
                advanceRemoteNotice()
            }
        }
    }

    /// Nothing of a host that is gone stays on screen or in the queue.
    func dropRemoteNotices(host: HostID) {
        queuedRemoteNotices.removeAll { $0.host == host }
        if remoteNotice?.host == host { advanceRemoteNotice() }
    }

    /// The notice's action opens the host's running sessions.
    public func actOnRemoteNotice(_ notice: RemoteNotice) {
        showRemoteSessions(notice.host)
    }

    /// The notice's action's label.
    public func remoteNoticeAction(_ notice: RemoteNotice) -> String {
        return RemoteCopy.sessionsOnMenuItem(notice.host.rawValue)
    }

    public func dismissRemoteNotice() {
        guard let notice = remoteNotice else { return }
        advanceRemoteNotice()
        if case .count = notice.kind, let launcher = remoteHost(notice.host) {
            openSessions.remoteTabs.operations.run(host: notice.host, .write) { await launcher.noticeLeftRunning() }
        }
    }

    /// At launch, a host with flagged sessions (whose line has not been
    /// shown) is asked about each of them, on its own pinned server: those
    /// a close left running, and those whose tab was connected when Temple
    /// quit (the launch notice). When the host answers, the line says how
    /// many of each are still running there, once; Running sessions… or ×
    /// marks them seen. Nothing is stopped: a contact only asks.
    func contactHostsWithSessionsLeftRunning() {
        for host in remoteHosts.registeredHosts.map(\.host) {
            guard let launcher = remoteHost(host) else { continue }
            let ticket = openSessions.remoteTabs.gate.ticket(host: host)
            openSessions.remoteTabs.operations.run(host: host, .query) { [weak self] in
                let found = await launcher.contactLeftRunning()
                guard let self, self.openSessions.remoteTabs.gate.admit(.contactNotice, ticket), let found else { return }
                // Proven running there, and not open in a tab here now (one
                // reattached while the host was asked is not news).
                let tabs = self.openSessions.remoteTabs
                let closed = found.closed.filter { !tabs.hasLiveTab(handle: $0, host: host) }
                let quit = found.quit.filter { !tabs.hasLiveTab(handle: $0, host: host) }
                if let notice = RemoteNotice.count(host: host, closed: closed, quit: quit) { self.showRemoteNotice(notice) }
            }
        }
    }

    // MARK: Removing a host

    /// Remove, either kind of host: the host is asked what Temple started
    /// there first. None running, or a host that doesn't answer: removed at
    /// once (`completion(nil)`). Otherwise the running ones, for the alert.
    /// Nothing is removed while the question is out.
    public func requestRemoveHost(_ name: String, completion: @escaping @MainActor (RemoteRemoval?) -> Void) {
        guard let record = remoteHosts.record(named: name) else { return }
        guard let launcher = remoteHost(record.host) else {
            remoteHosts.remove(name)
            completion(nil)
            return
        }
        let ticket = openSessions.remoteTabs.gate.ticket(host: record.host)
        openSessions.remoteTabs.operations.run(host: record.host, .query) { [weak self] in
            let answer = await launcher.trackedSessions()
            guard let self, self.openSessions.remoteTabs.gate.admit(.removalCheck, ticket) else { return }
            let live = self.runningForRemoval(record.host, answer: answer)
            guard !live.isEmpty else {
                self.remoteHosts.remove(name)
                completion(nil)
                return
            }
            completion(RemoteRemoval(name: name, fromConfig: record.source == .config, live: live))
        }
    }

    /// What Remove counts as running on a host: what the host proved
    /// present when it answered, and, whatever it answered, every session
    /// with a connected tab here (a live client proves its agent runs,
    /// even where the host's probe of it came back unknown). A tab's run
    /// the listing lacks is added from the tab.
    func runningForRemoval(_ host: HostID, answer: (sessions: [RemoteTrackedSession], checked: Bool))
        -> [RemoteTrackedSession] {
        let tabs = openSessions.remoteTabs
        var live = answer.sessions.filter { session in
            if answer.checked, case .present = session.state { return true }
            return tabs.hasLiveTab(handle: session.handle, host: host)
        }
        let listed = Set(answer.sessions.map(\.handle))
        for tab in openSessions.tabs where tab.kind == .session && tab.host == host {
            guard let handle = tab.remote?.handle, !listed.contains(handle),
                  tabs.hasLiveTab(handle: handle, host: host) else { continue }
            live.append(RemoteTrackedSession(handle: handle, sessionID: tab.sessionID, agent: tab.agent,
                                             state: .present(attached: true), leftRunning: nil,
                                             directory: tab.projectPath))
        }
        return live
    }

    /// The host list changed: a host whose name went is removed (an edit
    /// keeps its name); one added again is not.
    func noteRemovedRemoteHosts() {
        let names = Set(remoteHosts.records.map(\.name))
        for gone in knownRemoteHostNames.subtracting(names) { removedRemoteHosts.insert(HostID(rawValue: gone)) }
        for back in names { removedRemoteHosts.remove(HostID(rawValue: back)) }
        knownRemoteHostNames = names
    }

    /// A tab on a host removed from Temple this run: it says so, at once.
    public func tabHostWasRemoved(_ tab: SessionTab) -> Bool {
        tab.kind == .session && !tab.host.isLocal && removedRemoteHosts.contains(tab.host)
    }

    /// "Remove, leave them running": the host goes; its connected tabs are
    /// detached (retiring the host does that), and the agents keep running
    /// there, out of Temple's reach until the host is added again.
    public func removeHostLeavingSessions(_ removal: RemoteRemoval) {
        remoteHosts.remove(removal.name)
    }

    /// Why "Stop them and remove" kept the host: every session it tried,
    /// in the alert's order, each with its outcome (stopped, not stopped
    /// and why, or not known), so none is unaccounted for. Empty: removed.
    public struct RemovalFailures: Equatable {
        public var lines: [String] = []
        public var isEmpty: Bool { lines.isEmpty }
    }

    /// "Stop them and remove": each running session is stopped (no
    /// confirmation per session), then the host goes. A stop that fails, or
    /// whose outcome can't be saved, keeps the host, and `completion` gets
    /// what the failures say (empty: removed).
    public func stopSessionsAndRemoveHost(_ removal: RemoteRemoval,
                                          completion: @escaping @MainActor (RemovalFailures) -> Void) {
        guard let record = remoteHosts.record(named: removal.name) else { return }
        let host = record.host
        var remaining = removal.live.count
        var outcomes = [String?](repeating: nil, count: removal.live.count)
        var blocked = false
        let ticket = openSessions.remoteTabs.gate.ticket(host: host)
        for (index, session) in removal.live.enumerated() {
            let title = trackedTitle(session)
            openSessions.remoteTabs.stopTracked(handle: session.handle, host: host, agent: session.agent) { [weak self] result in
                remaining -= 1
                switch result {
                case .stopped:
                    outcomes[index] = RemoteCopy.removalStopped(title)
                case .leftRunning(let reason, let detail):
                    blocked = true
                    outcomes[index] = RemoteCopy.removalNotStopped(title, host: host.rawValue, reason: reason, detail: detail)
                case .unrecorded(let detail):
                    blocked = true
                    outcomes[index] = RemoteCopy.removalUnrecorded(title, host: host.rawValue, detail: detail)
                }
                guard remaining == 0, let self, self.openSessions.remoteTabs.gate.admit(.removalStopOutcome, ticket) else { return }
                guard blocked else {
                    self.remoteHosts.remove(removal.name)
                    completion(RemovalFailures())
                    return
                }
                completion(RemovalFailures(lines: outcomes.compactMap { $0 }))
            }
        }
    }

    /// Whether a session's conversation can be resumed after a stop: kept
    /// when its row's transcript is known, absent only when the host's
    /// enumeration proved no transcript carries its id, unknown otherwise
    /// (an unidentified run, or a transcript not looked up yet).
    public func resumability(_ sessionID: String?) -> RemoteCopy.Resumability {
        guard let sessionID, let row = overlay.rows[sessionID] else { return .unknown }
        if row.transcriptPath != nil { return .kept }
        return sessions.first(where: { $0.id == sessionID })?.transcriptConfirmedMissing == true ? .absent : .unknown
    }

    /// A tracked session's name as Running sessions shows it: its row's
    /// title, or the new-session title.
    public func trackedTitle(_ session: RemoteTrackedSession) -> String {
        guard let id = session.sessionID else { return session.agent.newSessionTitle }
        return sessions.first(where: { $0.id == id })?.displayTitle ?? session.agent.newSessionTitle
    }

    func sessionsSheetModel(_ request: RemoteSessionsRequest) -> RemoteSessionsSheetModel {
        RemoteSessionsSheetModel(request: request, openSessions: openSessions,
                                 launcher: { [weak self] in self?.remoteHost(request.host) })
    }

    func folderSheetModel(_ request: RemoteFolderRequest) -> RemoteFolderSheetModel {
        RemoteFolderSheetModel(request: request, openSessions: openSessions,
                               launcher: { [weak self] in self?.remoteHost(request.host) },
                               startTest: { [weak self] in self?.remoteHosts.startTest(for: request.host.rawValue) },
                               tmuxProblem: { [weak self] in self?.remoteTmuxProblem(request.host) },
                               start: { [weak self] folder in
                                   guard let self, self.remoteFolderSheet?.id == request.id else { return }
                                   self.startRemoteSession(host: request.host, agent: request.agent, folder: folder)
                               })
    }

    /// ⌘N's "Choose folder on <host>…" and the launcher's host row.
    public func chooseRemoteFolder(host: HostID, agent: Agent? = nil) {
        newSessionPickerPresented = false
        guard remoteHost(host) != nil else { return }
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

/// Marks a sheet as remote's while it is up (`AppModel.openRemoteSheets`),
/// so the key catcher leaves every key to it. Remote's sheets only: the
/// catcher treats every other window exactly as it did before remote.
private struct RemoteSheetMarker: ViewModifier {
    let model: AppModel
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.openRemoteSheets.insert(token) }
            .onDisappear { model.openRemoteSheets.remove(token) }
    }
}

extension View {
    /// This sheet is remote's: keys are its own while it is up.
    func remoteSheet(_ model: AppModel) -> some View { modifier(RemoteSheetMarker(model: model)) }
}
