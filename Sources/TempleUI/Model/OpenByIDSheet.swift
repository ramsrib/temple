import Foundation
import TempleCore

/// Open a session by id (docs/designs/open-existing-sessions.md section 5):
/// which host, and the id to look up there.
public struct OpenByIDRequest: Identifiable, Equatable {
    public let id = UUID()
    public let host: HostID
    public let sessionID: String
    public init(host: HostID, sessionID: String = "") { self.host = host; self.sessionID = sessionID }
}

/// What the sheet's folder check found.
enum OpenByIDFolder: Equatable {
    case exists(String)
    case missing
    case problem(String)
    case transport(String)
}

/// The sheet: host and id, then Open. Temple finds the agent and the
/// folder itself; the agent choice appears only when the id is both a
/// Claude and a Codex session there, and the folder field only when the
/// transcript records none. Every answer leads somewhere: a member on
/// another host opens there, and "not found" is said only after a complete
/// search, never for a host that couldn't be reached.
@MainActor
final class OpenByIDSheetModel: ObservableObject {
    enum Check: Equatable {
        case idle, checking
        /// The id is Temple's on another host: opening it there is offered.
        case elsewhere(HostID)
        /// Both agents have it: choose one, then Open.
        case chooseAgent
        /// The transcript records no folder: type one, then Open.
        case needsFolder
        case problem(String)
        /// The host didn't answer.
        case unreachable(String)
    }

    struct Dependencies {
        /// This Mac first, then every enabled host.
        var hosts: () -> [HostID]
        var lookup: (HostID, String) async throws -> SessionLookup
        var checkFolder: (HostID, String) async -> OpenByIDFolder
        /// The row Temple has for the id, if any.
        var member: (String) -> Session?
        /// A live tab for the id on that host.
        var hasLiveTab: (String, HostID) -> Bool
        var openMember: (Session) -> Void
        var resume: (ResumeRequest) -> Bool
        /// The host's configuration now; an answer for another is dropped.
        var configuration: (HostID) -> Int?
        /// The sheet is still up and Temple isn't quitting: only then does
        /// an answer open anything (the remote gate's rule for sheets).
        var canAct: () -> Bool = { true }
        var recentFolders: (HostID) -> [String]
    }

    @Published var host: HostID { didSet { if host != oldValue { edited() } } }
    @Published var sessionID: String { didSet { if sessionID != oldValue { edited() } } }
    @Published var agent: Agent?
    @Published var folder = ""
    @Published private(set) var check: Check = .idle
    @Published private(set) var showsAgent = false
    @Published private(set) var showsFolder = false

    let dependencies: Dependencies
    let close: () -> Void
    private var task: Task<Void, Never>?

    init(request: OpenByIDRequest, dependencies: Dependencies, close: @escaping () -> Void) {
        host = request.host
        sessionID = request.sessionID
        self.dependencies = dependencies
        self.close = close
    }

    var hosts: [HostID] { dependencies.hosts() }
    var trimmedID: String { Self.normalized(sessionID) }
    var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }
    var recentFolders: [String] { dependencies.recentFolders(host) }

    /// Ids are compared as the agents write them: a UUID in lower case.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed) != nil ? trimmed.lowercased() : trimmed
    }

    /// A whole session id (what ⌘K offers the sheet for).
    static func isSessionID(_ text: String) -> Bool {
        UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var canOpen: Bool {
        guard !trimmedID.isEmpty, check != .checking else { return false }
        if showsAgent, agent == nil { return false }
        if showsFolder, trimmedFolder.isEmpty { return false }
        return true
    }

    /// The host or the id changed: what was found was for the old ones.
    func edited() {
        task?.cancel()
        task = nil
        check = .idle
        showsAgent = false
        showsFolder = false
        agent = nil
    }

    func dismissed() {
        task?.cancel()
        task = nil
    }

    /// Open, or Return: the check, then the handoff (section 5).
    func confirm() {
        guard canOpen, dependencies.canAct() else { return }
        let id = trimmedID, host = host
        guard Self.isSessionID(id) else {
            check = .problem("That isn't a session id. One looks like 3f2a1c7e-5b6d-4c3a-9e1f-2a7b8c9d0e1f.")
            return
        }
        // 1. Already here.
        if let member = dependencies.member(id) {
            if member.host != host {
                check = .elsewhere(member.host)
                return
            }
            if dependencies.hasLiveTab(id, host) || member.canResume {
                dependencies.openMember(member)
                close()
                return
            }
        }
        // 2 to 4: look it up, settle the agent and the folder, open.
        let chosenAgent = showsAgent ? agent : nil
        let typedFolder = showsFolder ? trimmedFolder : nil
        let token = dependencies.configuration(host)
        check = .checking
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, host: host, chosenAgent: chosenAgent, typedFolder: typedFolder, token: token)
        }
    }

    /// Opens the member that already has this id, on its own host.
    func openElsewhere() {
        guard dependencies.canAct(), case .elsewhere = check, let member = dependencies.member(trimmedID) else { return }
        dependencies.openMember(member)
        close()
    }

    /// An answer for a question no longer asked (the host's settings
    /// changed, or the sheet was edited or closed) opens nothing; a sheet
    /// still waiting on it goes back to Open, never stays "Looking…".
    private func dropped() {
        guard !Task.isCancelled, check == .checking else { return }
        check = .idle
    }

    private func stillAsked(id: String, host: HostID, token: Int?) -> Bool {
        !Task.isCancelled && dependencies.canAct() && trimmedID == id && self.host == host && dependencies.configuration(host) == token
            && (host.isLocal || token != nil)
    }

    private func run(id: String, host: HostID, chosenAgent: Agent?, typedFolder: String?, token: Int?) async {
        let name = host.displayName
        let lookup: SessionLookup
        do {
            lookup = try await dependencies.lookup(host, id)
        } catch {
            guard stillAsked(id: id, host: host, token: token) else { return dropped() }
            let line: String
            if case LocateError.transport(let words) = error { line = words } else { line = error.localizedDescription }
            check = .unreachable("Temple couldn't reach \(name): \(RemoteCopy.trimmed(line)).")
            return
        }
        guard stillAsked(id: id, host: host, token: token) else { return dropped() }

        let found = lookup.found
        let agent: Agent
        switch found.count {
        case 0:
            check = .problem(Self.notFoundLine(lookup, id: id, host: name))
            return
        case 1:
            if let chosenAgent, chosenAgent != found[0] {
                // Never the other agent's session in its place. Gone is said
                // only of a store listed to the end.
                if case .cannotTell(let why) = lookup[chosenAgent] {
                    check = .problem("Temple couldn't check for the \(chosenAgent.displayName) session on \(name) this time: \(Self.uncertainty(why, agent: chosenAgent.displayName, host: name)) Open to try again.")
                    return
                }
                showsAgent = false
                self.agent = nil
                check = .problem("The \(chosenAgent.displayName) session isn't on \(name) any more; only a \(found[0].displayName) one is. Open again to open that.")
                return
            }
            agent = found[0]
        default:
            guard let chosenAgent, found.contains(chosenAgent) else {
                showsAgent = true
                check = .chooseAgent
                return
            }
            agent = chosenAgent
        }
        guard case .found(let locator, let recorded) = lookup[agent] else { return }

        let wanted = recorded ?? typedFolder
        guard let wanted, !wanted.isEmpty else {
            showsFolder = true
            check = .needsFolder
            return
        }
        let folderAnswer = await dependencies.checkFolder(host, wanted)
        guard stillAsked(id: id, host: host, token: token) else { return dropped() }
        let directory: String
        switch folderAnswer {
        case .exists(let resolved): directory = resolved
        case .missing:
            if recorded == nil {
                showsFolder = true
                check = .problem("\(wanted) isn't a folder on \(name).")
            } else {
                // Claude resumes a session only from its own folder: another
                // one would launch and fail, so none is offered.
                check = .problem("This session ran in \(wanted), which isn't on \(name) any more, so it can't be resumed.")
            }
            return
        case .problem(let line):
            check = .problem(line)
            return
        case .transport(let line):
            check = .unreachable("Temple couldn't check the folder on \(name): \(RemoteCopy.trimmed(line)).")
            return
        }

        // The fields must still say what was checked.
        guard stillAsked(id: id, host: host, token: token), !showsAgent || self.agent == chosenAgent,
              !showsFolder || trimmedFolder == typedFolder else { check = .idle; return }
        let opened = dependencies.resume(ResumeRequest(host: host, agent: agent, id: id, locator: locator,
                                                       title: agent.newSessionTitle, launchDirectory: directory))
        if opened {
            check = .idle
            close()
        } else if let member = dependencies.member(id) {
            check = member.host != host ? .elsewhere(member.host)
                : .problem("This session is already in Temple as a \(member.agent?.displayName ?? "different") session.")
        } else {
            check = .problem("Temple couldn't open this session.")
        }
    }

    /// "No session … on mac-b." only after every store was listed to the
    /// end; otherwise what couldn't be checked.
    static func notFoundLine(_ lookup: SessionLookup, id: String, host: String) -> String {
        let short = id.count > 8 ? String(id.prefix(8)) + "…" : id
        if lookup.notFoundAnywhere { return "No session \(short) on \(host)." }
        let searched = Agent.allCases.filter { lookup[$0] == .notFound }.map(\.displayName)
        let reasons = Agent.allCases.compactMap { agent -> String? in
            guard case .cannotTell(let why) = lookup[agent] else { return nil }
            return uncertainty(why, agent: agent.displayName, host: host)
        }
        let head = searched.isEmpty ? "Temple couldn't look for session \(short) on \(host)."
            : "Session \(short) isn't among \(searched.joined(separator: " or "))'s sessions on \(host)."
        return "\(head) Not checked: \(reasons.joined(separator: " "))"
    }

    static func uncertainty(_ why: LookupUncertainty, agent: String, host: String) -> String {
        switch why {
        case .storeUnknown: "Temple doesn't know where \(agent) keeps its sessions there."
        case .noStore: "\(agent)'s sessions folder isn't there."
        case .listingFailed: "listing \(agent)'s sessions failed."
        case .unreadable(let line): "a \(agent) session file couldn't be read (\(RemoteCopy.trimmed(line)))."
        case .notThisSession: "a \(agent) file named for this id is another session."
        case .changing: "a \(agent) session file kept changing while it was read."
        }
    }
}
