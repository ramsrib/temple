import Foundation

/// One session, looked up by an id a person typed (Open a session by id,
/// docs/designs/open-existing-sessions.md section 5), answered per agent.
/// Built from the seam's own `locate` and `read`; nothing here is used by
/// the engine, and no absence rule changes for it: "not found" is said only
/// of an agent whose store was listed to the end, and a file is "found" only
/// once a read confirmed it is this session.
public struct SessionLookup: Sendable, Equatable {
    public let agents: [Agent: AgentLookup]
    public init(agents: [Agent: AgentLookup]) { self.agents = agents }

    public subscript(agent: Agent) -> AgentLookup { agents[agent] ?? .cannotTell(.storeUnknown) }

    /// The agents that have the session, in `Agent.allCases` order.
    public var found: [Agent] { Agent.allCases.filter { if case .found = self[$0] { true } else { false } } }
    /// Every agent's store was listed to the end, and none has the session.
    public var notFoundAnywhere: Bool { Agent.allCases.allSatisfy { self[$0] == .notFound } }
}

public enum AgentLookup: Sendable, Equatable {
    /// A file this agent wrote, read and confirmed to be the session.
    /// `directory`: the folder its transcript records, when it records one.
    case found(TranscriptLocator, directory: String?)
    /// The agent's store was listed to the end with no file for the id.
    case notFound
    /// Whether the agent has it could not be settled.
    case cannotTell(LookupUncertainty)
}

public enum LookupUncertainty: Sendable, Equatable {
    /// Temple doesn't know where this agent keeps its sessions there.
    case storeUnknown
    /// The agent's sessions folder isn't there.
    case noStore
    /// The listing of the agent's sessions failed.
    case listingFailed
    /// A file for the id couldn't be read: the host's or the OS's words.
    case unreadable(String)
    /// A file named for the id records another session.
    case notThisSession
    /// The file kept changing while it was read.
    case changing
}

public extension HostSessionSource {
    /// The seam's default: one refreshed locate for the id, every agent,
    /// then a confirming read of each candidate in the engine's order. An
    /// agent missing from `complete` was not listed to the end, so without
    /// a confirmed file it is "can't tell", never "not found". A source
    /// that knows more about why a listing fell short answers itself.
    func lookup(id: String) async throws -> SessionLookup {
        let located = try await locate([LocateRequest(id: id, refresh: true)])
        let candidates = located.candidates[id] ?? []
        var agents: [Agent: AgentLookup] = [:]
        for agent in Agent.allCases {
            agents[agent] = try await SessionLookup.resolve(
                id: id, agent: agent, candidates: candidates.filter { $0.agent == agent },
                listed: located.complete.contains(agent) ? nil : .listingFailed, source: self)
        }
        return SessionLookup(agents: agents)
    }
}

extension SessionLookup {
    /// One agent's answer: the first candidate a read confirms is the
    /// session; else "not found" when the listing finished (`listed` nil)
    /// and nothing for the id was there at all; else the first reason it
    /// couldn't be settled. A transport failure throws, never "not found".
    public static func resolve(id: String, agent: Agent, candidates: [TranscriptCandidate],
                               listed: LookupUncertainty?, source: any HostSessionSource) async throws -> AgentLookup {
        var uncertainty: LookupUncertainty?
        for candidate in candidates where candidate.stat != .missing {
            do {
                let read = try await source.read(candidate.locator, agent: agent, expecting: id, facts: true)
                switch read.identity {
                case .verified: return .found(candidate.locator, directory: read.summary?.cwd)
                case .mismatch: uncertainty = uncertainty ?? .notThisSession
                case .incomplete: uncertainty = uncertainty ?? .unreadable("the file doesn't say which session it is yet")
                }
            } catch TranscriptReadError.transport(let line) {
                throw LocateError.transport(line)
            } catch TranscriptReadError.missing {
                continue
            } catch TranscriptReadError.changedDuringRead {
                uncertainty = uncertainty ?? .changing
            } catch TranscriptReadError.unreadable(let why) {
                uncertainty = uncertainty ?? .unreadable(why)
            }
        }
        if let listed { return .cannotTell(uncertainty ?? listed) }
        if let uncertainty { return .cannotTell(uncertainty) }
        return .notFound
    }
}
