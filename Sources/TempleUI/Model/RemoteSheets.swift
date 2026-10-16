import Foundation
import TempleCore

/// "Sessions on <host>": its list and its actions. The list's checks can
/// write run outcomes (a session its pinned server says is gone is Ended),
/// so they run as owned operations; every answer passes the gate for this
/// sheet, so nothing reaches a sheet that has gone, a host that changed or
/// a quitting app.
@MainActor
final class RemoteSessionsSheetModel: ObservableObject {
    let request: RemoteSessionsRequest
    @Published private(set) var listing: (sessions: [RemoteTrackedSession], checked: Bool)?
    @Published private(set) var stopping: Set<String> = []
    @Published private(set) var kept: Set<String> = []
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
            switch result {
            case .stopped:
                self.load()
            case .leftRunning(let reason, let detail):
                self.results[session.handle] = reason == .anotherClientAttached
                    ? RemoteCopy.leftRunningLine(self.host, reason: reason)
                    : RemoteCopy.couldNotStop(self.host, agent: session.agent, reason: detail ?? "the host didn't confirm the stop")
            case .unrecorded(let detail):
                self.results[session.handle] = RemoteCopy.unrecorded(self.host, detail: detail)
            }
        }
    }

    func keep(_ session: RemoteTrackedSession) {
        if let launcher = launcher() {
            openSessions.remoteTabs.operations.run(host: request.host, .write) { await launcher.keep(session.handle) }
        }
        kept.insert(session.handle)
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
        /// The host did not answer: Start anyway or Test connection.
        case unreachable(String)
    }

    let request: RemoteFolderRequest
    @Published var path = ""
    @Published private(set) var check: Check = .idle

    private let openSessions: OpenSessionsModel
    private let launcher: () -> RemoteSessionHost?
    private let start: (String) -> Void
    private var checking: UUID?

    init(request: RemoteFolderRequest, openSessions: OpenSessionsModel, launcher: @escaping () -> RemoteSessionHost?,
         start: @escaping (String) -> Void) {
        self.request = request
        self.openSessions = openSessions
        self.launcher = launcher
        self.start = start
    }

    var host: String { request.host.rawValue }
    var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    func edited() { if check != .checking { check = .idle } }

    func confirm() {
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
                self.start(resolved)
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
        guard !typed.isEmpty else { return }
        start(typed)
    }

    func dismissed() {
        if let checking { openSessions.remoteTabs.operations.cancel(id: checking) }
        checking = nil
    }
}
