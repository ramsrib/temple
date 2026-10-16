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
            guard let tab = openSessions.openTab(forSessionID: id) else { return notOpen(id) }
            return ControlResponse(session: controlSession(tab, detail: true))
        case .sessionsNew:
            return newSession(request, commit: commit)
        case .sessionsOpen:
            guard let id = request.id else { return .failure(.invalid, "sessions open needs an id") }
            return await openSession(id, commit: commit)
        case .sessionsClose:
            guard let id = request.id else { return .failure(.invalid, "sessions close needs an id") }
            guard let tab = openSessions.openTab(forSessionID: id) else { return notOpen(id) }
            // ⌘W's guard: only a working agent with a live terminal asks, and
            // the command line cannot ask, so it refuses.
            openSessions.settleIfQuietNow(tab)
            if tab.remote != nil, tab.hasLiveProcess, tab.activity == .running {
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
            if tab.hasSurface, tab.activity == .running, request.force != true {
                return .failure(.refused, "Its agent is working. Pass --force to close it anyway.")
            }
            let closed = controlSession(tab)
            guard commit.commit() else { return Self.expired }
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

    func controlSession(_ tab: SessionTab, detail: Bool = false) -> ControlSession {
        let state: ControlSession.State
        if !tab.hasSurface { state = .restored }
        else {
            switch tab.activity {
            case .running: state = .running
            case .idle: state = .idle
            case .needsAttention: state = .attention
            case .exited: state = .exited
            }
        }
        let argv = detail ? resumeArgv(for: tab) : []
        return ControlSession(
            id: tab.sessionID, cli: tab.agent, project: tab.projectPath, title: sessionTabTitle(tab), state: state,
            focused: tab.id == openSessions.activeTabID,
            resumeCommand: detail && !argv.isEmpty ? argv : nil,
            transcript: detail ? tab.sessionID.flatMap { transcriptURL(for: $0)?.path } : nil)
    }

    /// ⌘K's ranking (`SessionRowSearch`) over the open sessions Temple has
    /// rows for, then any tab without one (a Codex session still pending, an
    /// outside session not joined yet) whose title has the term.
    private func searchOpenTabs(_ term: String) -> [SessionTab] {
        let tabs = orderedSessionTabs()
        let rows = tabs.compactMap { $0.sessionID.flatMap { presentedByID[$0] } }
        var ranked = SessionRowSearch.rank(rows, query: term).compactMap { openSessions.openTab(forSessionID: $0.id) }
        let needle = term.lowercased()
        ranked += tabs.filter { tab in
            (tab.sessionID.flatMap { presentedByID[$0] } == nil) && sessionTabTitle(tab).lowercased().contains(needle)
        }
        return ranked
    }

    private func notOpen(_ id: String) -> ControlResponse {
        .failure(.notFound, "No open session has the id \(id). `temple history get \(id)` finds closed ones.")
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
    private func openSession(_ id: String, commit: ControlCommit) async -> ControlResponse {
        if let tab = openSessions.openTab(forSessionID: id) {
            guard commit.commit() else { return Self.expired }
            openSessions.activate(tab)
            return opened(id)
        }
        guard let lookup = await HistoryReader.lookup(id, hosts: hostRegistry, members: sessions) else {
            return Self.expired  // cancelled: the deadline has answered already
        }
        var facts = lookup.facts
        // The member's folder now may be one the read never asked about.
        if let project = presentedByID[id]?.project, facts.folders[project] == nil {
            facts.folders[project] = await hostRegistry.entry(for: project.host)?.source.directoryEvidence(project.path) ?? .unknown
            guard presentedByID[id]?.project == project else { return Self.changed }
        }

        // One synchronous turn from here: judge against now, then act.
        if openSessions.isQuitting { return Self.quitting }
        if let tab = openSessions.openTab(forSessionID: id) {
            guard commit.commit() else { return Self.expired }
            openSessions.activate(tab)
            return opened(id)
        }
        let openTabs = Set(openSessions.tabs.compactMap { tab in tab.sessionID.map { SessionKey(id: $0, host: tab.host) } })
        let rows = HistoryReader.rows(facts, member: presentedByID[id], archivedProjects: overlay.archivedProjectKeys,
                                      openTabs: openTabs)
        guard let row = rows.first else {
            // A store that did not read proves nothing about what is in it.
            if let failure = lookup.failures.first {
                return .failure(.refused, "Temple could not read the \(failure.agent.displayName) sessions, "
                                + "so it cannot tell whether \(id) is one: \(failure.message)")
            }
            return .failure(.notFound, "No session has the id \(id).")
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
        return opened(id)
    }

    /// Success only for what is on screen now: the session's tab, focused.
    private func opened(_ id: String) -> ControlResponse {
        guard let tab = openSessions.activeTab, tab.sessionID == id else {
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
