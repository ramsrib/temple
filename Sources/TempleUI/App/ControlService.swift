import AppKit
import TempleCore

/// The running app's side of the `temple` command line (ADR-034). Every
/// answer is read from the open tabs, and every action goes through the call
/// the app's own UI makes for it, guards included: the command line adds no
/// behaviour of its own.
extension AppModel {
    /// Listens for the command line. The app's alone: `StartupRootView` calls
    /// it, so a model built by a test or a tool never opens a socket, and a
    /// model on an in-memory database has no state directory to put one in.
    public func startControlServer() {
        guard controlServer == nil, let directory = databaseDirectory else { return }
        let url = ControlSocket.url(in: directory)
        switch ControlServer.start(at: url, handler: { [weak self] request, commit in
            guard let self else { return .failure(.refused, "Temple is quitting") }
            return await self.handleControl(request, commit: commit)
        }) {
        case .success(let server):
            controlServer = server
            TempleUILog.control.notice("listening at \(url.path, privacy: .public)")
            controlTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controlServer?.stop() }
                }
        case .failure(.alreadyServed):
            // Another Temple on this state directory answers the command
            // line; this one stays out of its way.
            TempleUILog.control.notice("another Temple answers at \(url.path, privacy: .public); not listening")
        case .failure(.failed(let reason)):
            TempleUILog.control.error("not listening: \(reason, privacy: .public)")
        }
    }

    /// `commit` is claimed in the same synchronous turn as any change, right
    /// before it: a request whose deadline has passed changes nothing.
    func handleControl(_ request: ControlRequest, commit: ControlCommit = ControlCommit()) async -> ControlResponse {
        // Quitting freezes the tab set for the next launch; nothing changes it.
        if openSessions.isQuitting, [.sessionsNew, .sessionsOpen, .sessionsClose].contains(request.command) {
            return Self.quitting
        }
        switch request.command {
        case .projectsList:
            return ControlResponse(projects: controlProjects())
        case .projectsGet:
            guard let directory = request.directory else { return .failure(.invalid, "projects get needs a folder") }
            guard let key = openProjectKey(for: directory), let project = controlProjects().first(where: { $0.path == key.path })
            else { return .failure(.notFound, "No tabs are open in \(directory).") }
            return ControlResponse(sessions: controlSessions(in: key), project: project)
        case .sessionsList:
            var tabs = orderedSessionTabs()
            if let directory = request.directory {
                guard let key = openProjectKey(for: directory) else { return ControlResponse(sessions: []) }
                tabs = tabs.filter { $0.projectKey == key }
            }
            if let cli = request.cli { tabs = tabs.filter { $0.agent == cli } }
            return ControlResponse(sessions: tabs.map { controlSession($0) })
        case .sessionsSearch:
            let term = request.term?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !term.isEmpty else { return .failure(.invalid, "sessions search needs a term") }
            var tabs = searchOpenTabs(term)
            if let cli = request.cli { tabs = tabs.filter { $0.agent == cli } }
            return ControlResponse(sessions: tabs.map { controlSession($0) })
        case .sessionsGet:
            guard let id = request.id else { return .failure(.invalid, "sessions get needs an id") }
            let host = Self.host(request)
            // A tab of a host since removed is still a tab: found first.
            guard let tab = openSessions.openTab(for: SessionKey(id: id, host: host)) else {
                return unknownHost(request.host) ?? notOpen(id, host: host)
            }
            return ControlResponse(session: controlSession(tab, detail: true))
        case .sessionsNew:
            return newSession(request, commit: commit)
        case .sessionsOpen:
            guard let id = request.id else { return .failure(.invalid, "sessions open needs an id") }
            if openSessions.openTab(for: SessionKey(id: id, host: Self.host(request))) == nil,
               let unknown = unknownHost(request.host) { return unknown }
            return await openSession(id, host: Self.host(request), commit: commit)
        case .sessionsClose:
            guard let id = request.id else { return .failure(.invalid, "sessions close needs an id") }
            let host = Self.host(request)
            guard let tab = openSessions.openTab(for: SessionKey(id: id, host: host)) else {
                return unknownHost(request.host) ?? notOpen(id, host: host)
            }
            // ⌘W's guard: only a working agent with a live terminal asks, and
            // the command line cannot ask, so it refuses. At rest by ⌘W's
            // own early rule (nothing done since its spawn) is decided
            // without touching the tab; it is applied only once committed.
            let atRest = openSessions.isAtRestNow(tab)
            let working = tab.activity == .running && !atRest
            if tab.remote != nil, tab.hasLiveProcess, working {
                // On a host, a working agent is never stopped from here:
                // refused, or with --force detached (it keeps working).
                guard request.force == true else {
                    return .failure(.refused, RemoteCopy.workingCLIRefusal(tab.host.rawValue))
                }
                let closed = controlSession(tab)
                guard commit.commit() else { return Self.expired }
                openSessions.remoteTabs.detach(tab.id)
                return ControlResponse(session: closed)
            }
            if tab.hasSurface, working, request.force != true {
                return .failure(.refused, "Its agent is working. Pass --force to close it anyway.")
            }
            // A restored chip of a session with a live run on its host: ⌘W
            // asks whether to stop it; the command line can't, so it refuses,
            // and with --force removes the chip and leaves the run as it is.
            if openSessions.chipMayBeRunning(tab) {
                guard request.force == true else {
                    return .failure(.refused, RemoteCopy.mayBeRunningCLIRefusal(tab.host.rawValue))
                }
                let closed = controlSession(tab)
                guard commit.commit() else { return Self.expired }
                openSessions.closeTab(tab.id)
                return ControlResponse(session: closed)
            }
            let closed = controlSession(tab, atRest: atRest)
            guard commit.commit() else { return Self.expired }
            if atRest { openSessions.settleNow(tab) }
            // An idle agent on a host is stopped now, as ⌘W stops it.
            openSessions.closeTab(tab.id)
            return ControlResponse(session: closed)
        }
    }

    // MARK: Reads

    /// Session tabs grouped by project, projects in the switcher's order,
    /// tabs in strip order within each.
    private func orderedSessionTabs() -> [SessionTab] {
        let tabs = openSessions.tabs.filter { $0.kind == .session }
        return openSessions.openProjectKeys.flatMap { key in tabs.filter { $0.projectKey == key } }
    }

    private func controlSessions(in key: ProjectKey) -> [ControlSession] {
        orderedSessionTabs().filter { $0.projectKey == key }.map { controlSession($0) }
    }

    private func controlProjects() -> [ControlProject] {
        let tabs = openSessions.tabs.filter { $0.kind == .session }
        return openSessions.openProjectKeys.map { key in
            ControlProject(path: key.path, name: key.displayName,
                           sessions: tabs.filter { $0.projectKey == key }.count,
                           focused: key == openSessions.activeProjectKey)
        }
    }

    private func openProjectKey(for directory: String) -> ProjectKey? {
        openSessions.openProjectKeys.first { $0.path == directory }
            ?? openSessions.openProjectKeys.first { ControlPaths.sameFolder($0.path, directory) }
    }

    /// `atRest`: the close decided it at rest before applying that (its
    /// answer says what the close found).
    func controlSession(_ tab: SessionTab, detail: Bool = false, atRest: Bool = false) -> ControlSession {
        let state: ControlSession.State
        if !tab.hasSurface { state = .restored }
        else {
            switch tab.activity {
            case .running: state = atRest ? .idle : .running
            case .idle: state = .idle
            case .needsAttention: state = .attention
            case .exited: state = .exited
            }
        }
        let argv = detail ? resumeArgv(for: tab) : []
        return ControlSession(
            id: tab.sessionID, host: tab.host.rawValue, cli: tab.agent, project: tab.projectPath,
            title: sessionTabTitle(tab), state: state,
            focused: tab.id == openSessions.activeTabID,
            resumeCommand: detail && !argv.isEmpty ? argv : nil,
            transcript: detail ? tab.sessionKey.flatMap { transcriptURL(for: $0)?.path } : nil)
    }

    /// ⌘K's ranking (`SessionRowSearch`) over the open sessions Temple has
    /// rows for, then any tab without one (a Codex session still pending, an
    /// outside session not joined yet) whose title has the term.
    private func searchOpenTabs(_ term: String) -> [SessionTab] {
        let tabs = orderedSessionTabs()
        let rows = tabs.compactMap { $0.sessionKey.flatMap { presentedByID[$0] } }
        var ranked = SessionRowSearch.rank(rows, query: term).compactMap { openSessions.openTab(for: $0.id) }
        let needle = term.lowercased()
        ranked += tabs.filter { tab in
            (tab.sessionKey.flatMap { presentedByID[$0] } == nil) && sessionTabTitle(tab).lowercased().contains(needle)
        }
        return ranked
    }

    /// The host a request names: `--host`, and this Mac without one. A
    /// session is its id on a host (ADR-041); one on another machine is
    /// named with its host.
    static func host(_ request: ControlRequest) -> HostID { HostID(cliValue: request.host ?? "") }

    private func notOpen(_ id: String, host: HostID) -> ControlResponse {
        let on = host.isLocal ? "" : " on \(host.displayName)"
        let flag = host.isLocal ? "" : " --host \(host.rawValue)"
        return .failure(.notFound, "No open session has the id \(id)\(on). `temple history get \(id)\(flag)` finds closed ones.")
    }

    /// A `--host` naming no host Temple has: said as that, never as a
    /// session that isn't there.
    private func unknownHost(_ host: String?) -> ControlResponse? {
        guard let host else { return nil }
        let named = HostID(cliValue: host)
        guard !named.isLocal, !remoteHosts.records.contains(where: { $0.host == named }),
              hostRegistry.entry(for: named) == nil else { return nil }
        return .failure(.notFound, "Temple has no host named \(named.rawValue).")
    }

    // MARK: Actions

    private func newSession(_ request: ControlRequest, commit: ControlCommit) -> ControlResponse {
        guard let directory = request.directory else { return .failure(.invalid, "sessions new needs a folder") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notFound, "\(directory) is not a folder.")
        }
        // A folder Temple already knows keeps the spelling its sessions have.
        let known = (openSessions.openProjectKeys + sessions.compactMap(\.project))
            .first { $0.host == .local && ControlPaths.sameFolder($0.path, directory) }
        let key = known ?? ProjectKey(host: .local, path: directory)
        guard commit.commit() else { return Self.expired }
        let tab = openSessions.newSession(agent: request.cli ?? settings.defaultAgent, project: key)
        bringForward()
        return ControlResponse(session: controlSession(tab))
    }

    /// The app's Open. A session with a tab is focused, as clicking its
    /// chip does. Any other is judged by History's rule for its id: the
    /// catalog is read first (the slow part, `HistoryReader.lookup`), then,
    /// in one synchronous turn, the id's rows are built against membership,
    /// archived projects and tabs as they are now, and the open acts on that
    /// verdict or refuses with the reason. Nothing that happened during the
    /// read is missed, because nothing is judged before it ended. A member
    /// opens as the sidebar opens it (an archived one is restored on the way);
    /// a session Temple has never seen joins as opened.
    ///
    /// `host`: the session's host (this Mac unless `--host` said another,
    /// ADR-041). A host named for a session Temple has no row of there is
    /// asked directly, as Open Session by ID asks it: a host has no catalog
    /// for History to read.
    private func openSession(_ id: String, host: HostID, commit: ControlCommit) async -> ControlResponse {
        let key = SessionKey(id: id, host: host)
        if !host.isLocal, presentedByID[key] == nil, openSessions.openTab(for: key) == nil {
            return await openOnHost(id, host: host, commit: commit)
        }
        if let tab = openSessions.openTab(for: key) {
            guard commit.commit() else { return Self.expired }
            // As the sidebar's click: a tab on a host whose client ended
            // reconnects, not only comes forward.
            openSessions.focusOrReconnect(tab)
            return opened(key)
        }
        guard let lookup = await HistoryReader.lookup(id, hosts: hostRegistry, members: sessions) else {
            return Self.expired  // cancelled: the deadline has answered already
        }
        var facts = lookup.facts
        // The member's folder now may be one the read never asked about.
        if let project = presentedByID[key]?.project, facts.folders[project] == nil {
            facts.folders[project] = await hostRegistry.entry(for: project.host)?.source.directoryEvidence(project.path) ?? .unknown
            guard presentedByID[key]?.project == project else { return Self.changed }
        }

        // One synchronous turn from here: judge against now, then act.
        if openSessions.isQuitting { return Self.quitting }
        if let tab = openSessions.openTab(for: key) {
            guard commit.commit() else { return Self.expired }
            openSessions.focusOrReconnect(tab)
            return opened(key)
        }
        let openTabs = Set(openSessions.tabs.compactMap(\.sessionKey))
        let rows = HistoryReader.rows(facts, members: members(id), archivedProjects: overlay.archivedProjectKeys,
                                      openTabs: openTabs).filter { $0.host == host }
        guard let row = rows.first else {
            // A store that did not read proves nothing about what is in it.
            if let failure = lookup.failures.first {
                return .failure(.refused, "Temple could not read the \(failure.agent.displayName) sessions, "
                                + "so it cannot tell whether \(id) is one: \(failure.message)")
            }
            return .failure(.notFound, "No session has the id \(id)\(host.isLocal ? "" : " on \(host.displayName)").")
        }
        guard rows.count == 1 else {
            return .failure(.ambiguous, "\(rows.count) sessions have the id \(id).")
        }
        if let conflict = row.conflict { return .failure(.refused, conflict.message) }
        guard row.canResume else { return .failure(.refused, Self.cannotResume(row)) }
        guard commit.commit() else { return Self.expired }
        if let member = row.member {
            openSessions.openSession(member)
        } else if let catalog = row.catalog {
            openSessions.openSession(catalog)
        }
        return opened(key)
    }

    /// Open on a named host Temple has no row for this id on: that host is
    /// asked for the session (`HostSessionSource.lookup`), and it opens in
    /// the folder its transcript records. "Not found" only when every store
    /// there was listed to the end.
    private func openOnHost(_ id: String, host: HostID, commit: ControlCommit) async -> ControlResponse {
        guard let source = hostRegistry.entry(for: host)?.source else {
            return .failure(.refused, "\(host.displayName) isn't connected.")
        }
        // An answer for a host edited, removed or added again meanwhile is
        // another machine's: it opens nothing (Open Session by ID's rule).
        let configuration = history.hostConfiguration(host)
        let lookup: SessionLookup
        do { lookup = try await source.lookup(id: id) } catch {
            let line: String
            if case LocateError.transport(let words) = error { line = words } else { line = error.localizedDescription }
            return .failure(.refused, "Temple couldn't reach \(host.displayName): \(RemoteCopy.trimmed(line)).")
        }
        let found = lookup.found
        guard let agent = found.first else {
            if lookup.notFoundAnywhere { return .failure(.notFound, "No session has the id \(id) on \(host.displayName).") }
            return .failure(.refused, OpenByIDSheetModel.notFoundLine(lookup, id: id, host: host.displayName))
        }
        guard found.count == 1 else {
            return .failure(.ambiguous, "\(id) is \(found.map { "a \($0.displayName)" }.formatted(.list(type: .and))) session on \(host.displayName). "
                            + "Open it from File ▸ Open Session by ID…, which asks which.")
        }
        guard case .found(let locator, let recorded) = lookup[agent], let directory = recorded, !directory.isEmpty else {
            return .failure(.refused, "The session's transcript on \(host.displayName) records no folder. "
                            + "Open it from File ▸ Open Session by ID…, which asks for one.")
        }
        if openSessions.isQuitting { return Self.quitting }
        guard history.hostConfiguration(host) == configuration, hostRegistry.entry(for: host) != nil else {
            return Self.changed
        }
        guard commit.commit() else { return Self.expired }
        guard openSessions.resume(ResumeRequest(host: host, agent: agent, id: id, locator: locator,
                                                title: agent.newSessionTitle, launchDirectory: directory)) else {
            return .failure(.refused, "Temple did not open it.")
        }
        return opened(SessionKey(id: id, host: host))
    }

    /// Temple's sessions with this id, by host.
    private func members(_ id: String) -> [HostID: Session] {
        var found: [HostID: Session] = [:]
        for session in sessions where session.sessionID == id {
            found[session.host] = session
        }
        return found
    }

    /// Success only for what is on screen now: the session's tab, focused.
    private func opened(_ key: SessionKey?) -> ControlResponse {
        guard let key, let tab = openSessions.activeTab, tab.sessionKey == key else {
            return .failure(.refused, "Temple did not open it.")
        }
        bringForward()
        return ControlResponse(session: controlSession(tab))
    }

    static let quitting = ControlResponse.failure(.refused, "Temple is quitting.")
    static let changed = ControlResponse.failure(.refused, "It changed while Temple was looking. Try again.")
    /// Never seen by the command line: the deadline answered first.
    static let expired = ControlResponse.failure(.refused, "Temple did not answer in time, and changed nothing.")

    /// Why a History row cannot resume, in the row's own terms.
    static func cannotResume(_ row: HistoryRow) -> String {
        if let member = row.member {
            if member.agent == nil { return "Temple doesn't know which CLI this session ran in." }
            if member.directory == nil { return "Temple doesn't know which folder this session ran in." }
        }
        if row.transcriptMissing { return "No transcript on disk carries this session." }
        if row.folderMissing { return "The folder it ran in is gone." }
        return "This session cannot be resumed."
    }

    /// The command line acted for the person at the keyboard: show them.
    /// A snapshot run never takes focus (as at launch).
    private func bringForward() {
        guard ProcessInfo.processInfo.environment["TEMPLE_SNAPSHOT_DIR"] == nil else { return }
        for window in NSApplication.shared.windows where window.isMiniaturized { window.deminiaturize(nil) }
        NSApplication.shared.activate()
    }
}
