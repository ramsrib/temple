import Foundation
import TempleCore

/// "Running sessions on <host>": its list and its actions. The list's checks can
/// write run outcomes (a session its pinned server says is gone is Ended),
/// so they run as owned operations; every answer passes the gate for this
/// sheet, so nothing reaches a sheet that has gone, a host that changed or
/// a quitting app.
@MainActor
final class RemoteSessionsSheetModel: ObservableObject {
    let request: RemoteSessionsRequest
    @Published private(set) var listing: (sessions: [RemoteTrackedSession], checked: Bool)?
    @Published private(set) var stopping: Set<String> = []
    /// Rows whose left-running note was dismissed (the flag is cleared).
    @Published private(set) var dismissedNotes: Set<String> = []
    /// What a failed Stop said, under its row (S9).
    @Published private(set) var results: [String: String] = [:]

    private let openSessions: OpenSessionsModel
    private let launcher: () -> RemoteSessionHost?
    private var loading: UUID?

    init(request: RemoteSessionsRequest, openSessions: OpenSessionsModel, launcher: @escaping () -> RemoteSessionHost?) {
        self.request = request
        self.openSessions = openSessions
        self.launcher = launcher
    }

    var host: String { request.host.rawValue }

    func load() {
        if let loading { openSessions.remoteTabs.operations.cancel(id: loading) }
        guard let launcher = launcher() else {
            listing = ([], false)
            return
        }
        listing = nil
        let ticket = openSessions.remoteTabs.gate.ticket(host: request.host, sheet: request.id)
        loading = openSessions.remoteTabs.operations.run(host: request.host, .query) { [weak self] in
            let answer = await launcher.trackedSessions()
            guard let self, self.openSessions.remoteTabs.gate.admit(.sheetLoad, ticket) else { return }
            self.listing = answer
        }
    }

    /// The sheet went: its query is cancelled; anything still answering is
    /// refused by the gate.
    func dismissed() {
        if let loading { openSessions.remoteTabs.operations.cancel(id: loading) }
        loading = nil
    }

    func stop(_ session: RemoteTrackedSession) {
        stopping.insert(session.handle)
        results[session.handle] = nil
        let ticket = openSessions.remoteTabs.gate.ticket(host: request.host, sheet: request.id)
        // The stop survives the sheet: the app owns it until its outcome is
        // written. Only what the sheet shows is gated.
        openSessions.remoteTabs.stopTracked(handle: session.handle, host: request.host, agent: session.agent) { [weak self] result in
            guard let self, self.openSessions.remoteTabs.gate.admit(.sheetStopOutcome, ticket) else { return }
            self.stopping.remove(session.handle)
            if result == .stopped {
                self.load()
            } else {
                self.results[session.handle] = RemoteCopy.stopFailure(result, host: self.host, agent: session.agent)
            }
        }
    }

    /// Open: a tab attached to the running session, as clicking its
    /// sidebar row does. A run with no row in Temple's list opens by its
    /// run instead: a Codex run (unidentified, or identified but never
    /// joined, a claim whose core join failed) through the pending path,
    /// which rejoins an identified one before it attaches; any other by
    /// its session id, which joins it as opening a session does. With no
    /// folder on record it can't open, and the row says what to do. Whether
    /// a tab is opening (the sheet closes only then).
    @discardableResult
    func open(_ session: RemoteTrackedSession, rows: [Session]) -> Bool {
        if let id = session.sessionID, let row = rows.first(where: { $0.id == id && $0.host == request.host }) {
            openSessions.openSession(row)
            return true
        }
        guard let directory = session.directory else {
            results[session.handle] = RemoteCopy.cannotOpenTracked(session.handle)
            return false
        }
        if session.agent == .codex {
            openSessions.remoteTabs.openPendingRun(handle: session.handle, host: request.host, directory: directory)
        } else if let id = session.sessionID {
            openSessions.remoteTabs.openSession(id, agent: session.agent, host: request.host, directory: directory)
        } else {
            results[session.handle] = RemoteCopy.cannotOpenTracked(session.handle)
            return false
        }
        return true
    }

    /// Show tab: the tab this session is open in, focused.
    func showTab(_ session: RemoteTrackedSession) {
        if let tab = openSessions.tabs.first(where: { $0.host == request.host && $0.remote?.handle == session.handle }) {
            openSessions.activate(tab)
        }
    }

    /// Dismiss, on a row with a left-running note: the flag is cleared and
    /// the note goes; the session keeps running either way.
    func dismissNote(_ session: RemoteTrackedSession) {
        if let launcher = launcher() {
            openSessions.remoteTabs.operations.run(host: request.host, .write) { await launcher.keep(session.handle) }
        }
        dismissedNotes.insert(session.handle)
    }
}

/// The folder sheet's check, owned and gated like every remote completion:
/// a dismissed sheet cancels it, and an answer for a sheet that has gone
/// starts nothing.
@MainActor
final class RemoteFolderSheetModel: ObservableObject {
    enum Check: Equatable {
        case idle, checking
        case resolved(String)
        case problem(String)
        /// The host did not answer: Start without checking, or Test
        /// connection.
        case unreachable(String)
    }

    let request: RemoteFolderRequest
    @Published var path = ""
    @Published private(set) var check: Check = .idle

    private let openSessions: OpenSessionsModel
    private let launcher: () -> RemoteSessionHost?
    private let start: (String) -> Void
    private let startTest: () -> ConnectionTest?
    private let tmuxProblemNow: () -> String?
    private var checking: UUID?

    init(request: RemoteFolderRequest, openSessions: OpenSessionsModel, launcher: @escaping () -> RemoteSessionHost?,
         startTest: @escaping () -> ConnectionTest? = { nil }, tmuxProblem: @escaping () -> String? = { nil },
         start: @escaping (String) -> Void) {
        self.request = request
        self.openSessions = openSessions
        self.launcher = launcher
        self.startTest = startTest
        self.tmuxProblemNow = tmuxProblem
        self.start = start
    }

    var host: String { request.host.rawValue }
    var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The tmux rule: the host's last test proved no session can start
    /// there. Start (and Start without checking) do nothing, and the sheet
    /// says this line.
    var tmuxProblem: String? { tmuxProblemNow() }

    func edited() { if check != .checking { check = .idle } }

    /// Test connection (D6): the host's own test, in its sheet over this
    /// one. This sheet keeps its text meanwhile.
    func testConnection() -> ConnectionTest? { startTest() }

    /// The test's sheet closed: back here, the typed path as it was; a test
    /// that passed checks the folder again, as advice only: nothing starts
    /// until Start (the user reviews the path first).
    func testClosed(passed: Bool) {
        guard passed, !trimmedPath.isEmpty else { return }
        checkFolder(thenStart: false)
    }

    /// Whether a test ran to the end and connected.
    static func passed(_ test: ConnectionTest) -> Bool { test.phase == .finished && test.summary?.failure == nil }

    /// Start (or Return, or a recent folder): the folder is checked, and a
    /// session starts there once it is found.
    func confirm() {
        guard tmuxProblem == nil else { return }
        checkFolder(thenStart: true)
    }

    private func checkFolder(thenStart: Bool) {
        let typed = trimmedPath
        guard !typed.isEmpty, check != .checking, let launcher = launcher() else { return }
        check = .checking
        if let checking { openSessions.remoteTabs.operations.cancel(id: checking) }
        let ticket = openSessions.remoteTabs.gate.ticket(host: request.host, sheet: request.id)
        checking = openSessions.remoteTabs.operations.run(host: request.host, .query) { [weak self] in
            let result = await launcher.checkFolder(typed)
            guard let self, self.openSessions.remoteTabs.gate.admit(.folderCheckResult, ticket) else { return }
            guard typed == self.trimmedPath else { self.check = .idle; return }
            switch result {
            case .exists(let resolved):
                self.check = .resolved(resolved)
                if thenStart, self.tmuxProblem == nil { self.start(resolved) }
            case .missing:
                self.check = .problem(RemoteCopy.noFolder(typed, host: self.host))
            case .cannotEnter(let line):
                self.check = .problem("Temple can't enter \(typed) on \(self.host): \(RemoteCopy.trimmed(line)).")
            case .transport(let line):
                self.check = .unreachable("Temple couldn't check this folder on \(self.host): \(RemoteCopy.trimmed(line)).")
            }
        }
    }

    func startAnyway() {
        let typed = trimmedPath
        guard !typed.isEmpty, tmuxProblem == nil else { return }
        start(typed)
    }

    func dismissed() {
        if let checking { openSessions.remoteTabs.operations.cancel(id: checking) }
        checking = nil
    }
}
