import TempleCore
import TempleTerminalAPI

public struct AgentLaunchSpec: Sendable {
    public enum Mode: Sendable, Equatable {
        case new(sessionID: String?)
        case resume(sessionID: String)
    }
    public let agent: Agent
    public let mode: Mode
    public let directory: String
    public let host: HostID
    public init(agent: Agent, mode: Mode, directory: String, host: HostID) {
        self.agent = agent; self.mode = mode; self.directory = directory; self.host = host
    }
}

/// The owning host chooses the executable, arguments and transport from intent.
@MainActor
public protocol HostLauncher: Sendable {
    func command(for spec: AgentLaunchSpec) throws -> TerminalCommand
    func canLaunch(_ agent: Agent) -> Bool
}

@MainActor
public final class LocalHostLauncher: HostLauncher {
    private let binaryPath: (Agent) -> String
    private let extraArgs: (Agent) -> [String]
    private let verdict: (Agent) -> Bool
    private let wrapper: any HostCommandWrapper
    public init(binaryPath: @escaping (Agent) -> String = { $0.binaryName },
                extraArgs: @escaping (Agent) -> [String] = { _ in [] },
                canLaunch: @escaping (Agent) -> Bool = { _ in true },
                wrapper: any HostCommandWrapper = LocalCommandWrapper()) {
        self.binaryPath = binaryPath; self.extraArgs = extraArgs
        self.verdict = canLaunch; self.wrapper = wrapper
    }
    public func command(for spec: AgentLaunchSpec) throws -> TerminalCommand {
        precondition(spec.host.isLocal)
        let arguments: [String]
        switch spec.mode {
        case .resume(let id): arguments = Array(spec.agent.resumeArgv(sessionID: id).dropFirst())
        case .new(let id): arguments = spec.agent == .claude ? id.map { ["--session-id", $0] } ?? [] : []
        }
        return wrapper.wrap(TerminalCommand(argv: [binaryPath(spec.agent)] + extraArgs(spec.agent) + arguments,
                                            cwd: spec.directory))
    }
    public func canLaunch(_ agent: Agent) -> Bool { verdict(agent) }
}
