import Darwin
import Foundation
import TempleCore
import TempleUI

/// The `temple` command line (ADR-034). `projects` and `sessions` ask the
/// running app over its socket; `history` reads the agents' stores and
/// Temple's database itself, the way the History tab does, and works with
/// Temple closed.
public enum TempleCLI {
    public enum Exit: Int32 {
        case ok = 0
        case failure = 1
        case usage = 2
    }

    /// Where output goes; tests capture it.
    public struct Console {
        public var out: (String) -> Void
        public var err: (String) -> Void
        public init(out: @escaping (String) -> Void, err: @escaping (String) -> Void) {
            self.out = out; self.err = err
        }
        public static let standard = Console(
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }

    /// How the command line reaches the app; tests replace it.
    public struct Transport {
        public var send: (ControlRequest, TimeInterval) throws -> ControlResponse
        /// Starts Temple when it is not running, or says why it cannot.
        public var ensureRunning: () throws -> Void
        public init(send: @escaping (ControlRequest, TimeInterval) throws -> ControlResponse,
                    ensureRunning: @escaping () throws -> Void) {
            self.send = send; self.ensureRunning = ensureRunning
        }
        public static let socket = Transport(
            send: { try ControlClient.send($0, timeout: $1) },
            ensureRunning: { try AppLauncher.ensureRunning() })
    }

    /// History's rows; tests replace the read.
    public typealias HistoryRead = @MainActor () async throws -> HistoryReader.Result

    @MainActor
    public static func main(_ arguments: [String], console: Console = .standard, transport: Transport = .socket,
                            history: HistoryRead? = nil,
                            workingDirectory: String = FileManager.default.currentDirectoryPath) async -> Exit {
        switch ArgumentParser.parse(Array(arguments.dropFirst())) {
        case .help(let noun):
            console.out(ArgumentParser.helpText(noun))
            return .ok
        case .usageError(let message, let noun):
            console.err("temple: \(message)")
            console.err("Run `temple \(noun.map { "\($0.rawValue) " } ?? "")--help` for usage.")
            return .usage
        case .run(let invocation):
            let runner = Runner(invocation: invocation, console: console, transport: transport,
                                history: history ?? readHistory, workingDirectory: workingDirectory)
            do {
                try await runner.run()
                return .ok
            } catch let error as CLIError {
                console.err("temple: \(error.message)")
                return .failure
            } catch {
                console.err("temple: \(error)")
                return .failure
            }
        }
    }

    /// History as the tab reads it: this Mac's stores, Temple's members and
    /// archived projects from the database, read-only.
    @MainActor
    static func readHistory() async throws -> HistoryReader.Result {
        var members: [Session] = []
        var archived: Set<ProjectKey> = []
        if FileManager.default.fileExists(atPath: TempleDB.defaultPath().path) {
            let database: TempleDB
            do {
                database = try TempleDB(readOnlyPath: TempleDB.defaultPath())
            } catch TempleDBError.newerSchema {
                throw CLIError(TempleDBError.updateRequiredMessage)
            }
            members = try database.sessionStates().map { Session(state: $0) }
            archived = Set(try database.projectStates().filter(\.archived).map { ProjectKey(host: .local, path: $0.path) })
        }
        return await HistoryReader.read(hosts: HostRegistry(), members: members, archivedProjects: archived)
    }
}

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
private struct Runner {
    let invocation: Invocation
    let console: TempleCLI.Console
    let transport: TempleCLI.Transport
    let history: TempleCLI.HistoryRead
    let workingDirectory: String

    func run() async throws {
        switch invocation.noun {
        case .projects, .sessions: try runLive()
        case .history: try await runHistory()
        }
    }

    private func folder(_ path: String) -> String {
        ControlPaths.canonical(path, relativeTo: workingDirectory)
    }

    // MARK: Live: the running app

    private func runLive() throws {
        let request: ControlRequest
        var timeout: TimeInterval = 15
        var launches = false
        switch (invocation.noun, invocation.verb) {
        case (.projects, .ls):
            request = ControlRequest(.projectsList)
        case (.projects, .get):
            request = ControlRequest(.projectsGet, directory: folder(invocation.argument!))
        case (.sessions, .ls):
            request = ControlRequest(.sessionsList, directory: invocation.project.map(folder), cli: invocation.cli)
        case (.sessions, .search):
            request = ControlRequest(.sessionsSearch, cli: invocation.cli, term: invocation.argument)
        case (.sessions, .get):
            request = ControlRequest(.sessionsGet, id: invocation.argument)
        case (.sessions, .new):
            let directory = folder(invocation.argument ?? ".")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError("\(directory) is not a folder")
            }
            request = ControlRequest(.sessionsNew, directory: directory, cli: invocation.cli)
            launches = true
        case (.sessions, .open):
            request = ControlRequest(.sessionsOpen, id: invocation.argument)
            // A session Temple has never seen is found by reading the stores.
            timeout = 120
            launches = true
        case (.sessions, .close):
            request = ControlRequest(.sessionsClose, id: invocation.argument, force: invocation.force)
        default:
            throw CLIError("\(invocation.noun.rawValue) has no verb \(invocation.verb.rawValue)")
        }
        if launches { try transport.ensureRunning() }
        let response: ControlResponse
        do {
            response = try transport.send(request, timeout)
        } catch ControlClientError.notRunning {
            throw CLIError("Temple isn't running")
        } catch ControlClientError.transport(let message) {
            throw CLIError(message)
        }
        if let error = response.error { throw CLIError(error.message) }
        print(response)
    }

    private func print(_ response: ControlResponse) {
        switch (invocation.noun, invocation.verb) {
        case (.projects, .ls):
            let projects = response.projects ?? []
            console.out(invocation.json ? Output.json(projects) : Output.projects(projects))
        case (.projects, .get):
            guard let project = response.project else { return }
            let sessions = response.sessions ?? []
            if invocation.json {
                console.out(Output.json(ProjectDetail(project: project, sessions: sessions)))
            } else {
                console.out(Output.fields([("name", project.name), ("path", project.path),
                                           ("sessions", "\(project.sessions)")]))
                if !sessions.isEmpty { console.out("\n" + Output.sessions(sessions)) }
            }
        case (.sessions, .ls), (.sessions, .search):
            let sessions = response.sessions ?? []
            console.out(invocation.json ? Output.json(sessions) : Output.sessions(sessions))
        default:
            guard let session = response.session else { return }
            if invocation.json { console.out(Output.json(session)) }
            else if invocation.verb == .get { console.out(Output.session(session)) }
            else {
                let verb = invocation.verb == .new ? "Started" : invocation.verb == .open ? "Opened" : "Closed"
                console.out("\(verb) \(session.id ?? "a pending \(session.cli.displayName) session") (\(session.title))")
            }
        }
    }

    private struct ProjectDetail: Encodable {
        let project: ControlProject
        let sessions: [ControlSession]
    }

    // MARK: History: read here

    private func runHistory() async throws {
        let result = try await history()
        for failure in result.failures {
            console.err("temple: warning: \(failure.agent.displayName) sessions could not be read: \(failure.message)")
        }
        var rows = result.rows
        if let cli = invocation.cli { rows = rows.filter { $0.agent == cli } }
        switch invocation.verb {
        case .ls:
            if let project = invocation.project {
                let wanted = folder(project)
                rows = rows.filter { !$0.projectPath.isEmpty && ControlPaths.sameFolder($0.projectPath, wanted) }
            }
            let entries = rows.map { HistoryEntry($0) }
            console.out(invocation.json ? Output.json(entries) : Output.history(entries))
        case .search:
            let entries = rows.filter { $0.matches(search: invocation.argument!) }.map { HistoryEntry($0) }
            console.out(invocation.json ? Output.json(entries) : Output.history(entries))
        case .get:
            let id = invocation.argument!
            let matches = rows.filter { $0.sessionID == id }
            guard let row = matches.first else { throw CLIError("No session has the id \(id).") }
            guard matches.count == 1 else { throw CLIError("\(matches.count) sessions have the id \(id).") }
            let entry = HistoryEntry(row, detail: true)
            console.out(invocation.json ? Output.json(entry) : Output.historyEntry(entry))
        default:
            throw CLIError("history has no verb \(invocation.verb.rawValue)")
        }
    }
}
