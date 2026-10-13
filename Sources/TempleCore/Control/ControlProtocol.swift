import Foundation

/// The `temple` command line's requests to the running app (ADR-034). One
/// JSON object per connection each way, newline-terminated. Everything here
/// is a value: the app answers from its own state and acts through its own
/// actions, so nothing on the wire is trusted beyond naming what to act on.
public enum ControlProtocol {
    /// Bumped only for a change an older peer would misread. A newer request
    /// is refused rather than half understood.
    public static let version = 1
    /// The socket file's name in the state directory.
    public static let socketName = "control.sock"
    /// A request or a response larger than this is not one of ours.
    public static let maxMessageBytes = 1 << 20

    /// The answer when the command and the app speak different versions:
    /// neither side guesses at the other's shape. Each side passes its own
    /// version in its own role.
    static func mismatch(command: Int, temple: Int) -> ControlResponse {
        let advice = command > temple ? "Update Temple." : "Use the temple command that ships with this Temple."
        return .failure(.invalid, "This temple command speaks protocol \(command) and Temple speaks \(temple). \(advice)")
    }
}

/// The one field every request and response carries in every version.
struct ControlEnvelope: Decodable {
    let version: Int
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case projectsList = "projects.ls"
        case projectsGet = "projects.get"
        case sessionsList = "sessions.ls"
        case sessionsSearch = "sessions.search"
        case sessionsGet = "sessions.get"
        case sessionsNew = "sessions.new"
        case sessionsOpen = "sessions.open"
        case sessionsClose = "sessions.close"
    }

    public var version: Int
    public var command: Command
    /// A session id (`get`, `open`, `close`).
    public var id: String?
    /// A folder: the project to list or get, or where `new` starts.
    public var directory: String?
    public var cli: Agent?
    public var term: String?
    public var force: Bool?

    public init(_ command: Command, id: String? = nil, directory: String? = nil, cli: Agent? = nil,
                term: String? = nil, force: Bool? = nil) {
        self.version = ControlProtocol.version
        self.command = command
        self.id = id
        self.directory = directory
        self.cli = cli
        self.term = term
        self.force = force
    }
}

/// A session with a tab, as the app shows it now.
public struct ControlSession: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, idle, attention, exited
        /// A tab restored at launch whose agent has not started yet.
        case restored
    }

    /// The CLI's own session id; nil while a new Codex session has none yet
    /// (it is pending until Codex writes its rollout).
    public var id: String?
    public var cli: Agent
    public var project: String
    public var title: String
    public var state: State
    /// The tab on screen.
    public var focused: Bool
    /// The command that resumes it in a terminal (`get` only).
    public var resumeCommand: [String]?
    public var transcript: String?

    public init(id: String?, cli: Agent, project: String, title: String, state: State, focused: Bool,
                resumeCommand: [String]? = nil, transcript: String? = nil) {
        self.id = id; self.cli = cli; self.project = project; self.title = title
        self.state = state; self.focused = focused
        self.resumeCommand = resumeCommand; self.transcript = transcript
    }

    private enum CodingKeys: String, CodingKey {
        case id, cli, project, title, state, focused, resumeCommand, transcript
    }

    /// A pending session says `"id": null` rather than leaving the key out,
    /// so a script reading `id` sees that it has none yet.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cli, forKey: .cli)
        try container.encode(project, forKey: .project)
        try container.encode(title, forKey: .title)
        try container.encode(state, forKey: .state)
        try container.encode(focused, forKey: .focused)
        try container.encodeIfPresent(resumeCommand, forKey: .resumeCommand)
        try container.encodeIfPresent(transcript, forKey: .transcript)
    }
}

/// A project with at least one tab.
public struct ControlProject: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var sessions: Int
    /// The project on screen.
    public var focused: Bool

    public init(path: String, name: String, sessions: Int, focused: Bool) {
        self.path = path; self.name = name; self.sessions = sessions; self.focused = focused
    }
}

public struct ControlError: Codable, Equatable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        /// No session or project by that name.
        case notFound
        /// More than one session answers to that id.
        case ambiguous
        /// It exists, and the app's own guard says no (a running agent, a
        /// session that cannot resume).
        case refused
        /// The request itself is malformed or from a newer protocol.
        case invalid
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    /// The protocol the answer is in; a client checks it before reading on.
    public var version: Int
    public var error: ControlError?
    public var sessions: [ControlSession]?
    public var projects: [ControlProject]?
    public var session: ControlSession?
    public var project: ControlProject?

    public init(error: ControlError? = nil, sessions: [ControlSession]? = nil, projects: [ControlProject]? = nil,
                session: ControlSession? = nil, project: ControlProject? = nil) {
        self.version = ControlProtocol.version
        self.error = error; self.sessions = sessions; self.projects = projects
        self.session = session; self.project = project
    }

    public static func failure(_ code: ControlError.Code, _ message: String) -> ControlResponse {
        ControlResponse(error: ControlError(code, message))
    }
}
