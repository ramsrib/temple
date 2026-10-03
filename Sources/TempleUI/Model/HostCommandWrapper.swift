import TempleTerminalAPI

/// Launch transport, separate from transcript resolution.
public protocol HostCommandWrapper: Sendable {
    func wrap(_ command: TerminalCommand) -> TerminalCommand
}

/// Local launches already carry the correct argv, directory and environment.
public struct LocalCommandWrapper: HostCommandWrapper {
    public init() {}
    public func wrap(_ command: TerminalCommand) -> TerminalCommand { command }
}
