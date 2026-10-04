import Foundation

public enum HostCapability: Hashable, Sendable {
    case liveChanges, revealInFinder, catalog
}

/// Transcript operations for one host. Failures never prove absence.
///
/// Two generations live here until the engine cutover: the semantic
/// `resolve`/`release` the current engine drives, and the primitives the
/// next one will — `locate` (listing + stat, no identity reads), `read` (one
/// bounded read: identity, facts when asked, the post-read signature), the
/// async `directoryEvidence`, `changes`, `catalog` and `adopt`. The agent
/// formats are not a source's business: they are `TempleCore/Formats`, the
/// same for every host. A source that has not adopted a primitive throws
/// `HostSourceError.unsupported` from it.
public protocol HostSessionSource: Sendable {
    var host: HostID { get }
    var capabilities: Set<HostCapability> { get }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch
    /// Host-owned directory evidence; unknown must not be treated as missing.
    /// Synchronous, for the launch and History paths until the cutover.
    func directoryEvidence(_ path: String) -> DirectoryEvidence
    func release(_ ids: [String])
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error>
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult
    func changes() -> AsyncThrowingStream<SourceChange, Error>

    /// Listing and stat for these ids, in one round trip. Candidates carry
    /// their role (`TranscriptCandidates`); a hint whose file is gone is not
    /// a candidate. Throws `LocateError.transport` only; a listing that
    /// failed leaves its agent out of `complete` instead.
    func locate(_ requests: [LocateRequest]) async throws -> LocateResult
    /// One read of one file: identity (bounded), and when `facts` and the
    /// identity verified, facts from bounded bytes (at most one wider head)
    /// with the agent's shared inputs. Throws `TranscriptReadError`.
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead
    /// Owning-host directory evidence, by whatever transport the host uses.
    func directoryEvidence(_ path: String) async -> DirectoryEvidence
}

/// A primitive this source has not adopted yet.
public enum HostSourceError: Error, Equatable {
    case unsupported(String)
}

public struct LocateRequest: Sendable, Equatable {
    public let id: String
    public let agent: Agent?
    public let hint: TranscriptLocator?
    /// An explicit open: the listing is refreshed rather than trusted.
    public let refresh: Bool
    public init(id: String, agent: Agent? = nil, hint: TranscriptLocator? = nil, refresh: Bool = false) {
        self.id = id; self.agent = agent; self.hint = hint; self.refresh = refresh
    }
}

/// What a stat says about a file. `identity` is the host's file identity
/// (an inode); 0 means the host has none, and then a same-size rewrite is
/// seen only as a new `modifiedAt`.
public struct TranscriptSignature: Hashable, Sendable {
    public let modifiedAt: Date
    public let size: Int
    public let identity: UInt64
    public init(modifiedAt: Date, size: Int, identity: UInt64) {
        self.modifiedAt = modifiedAt; self.size = size; self.identity = identity
    }
}

public enum CandidateStat: Hashable, Sendable {
    case present(TranscriptSignature)
    case missing
    case unreadable
}

public struct TranscriptCandidate: Hashable, Sendable {
    public let locator: TranscriptLocator
    public let agent: Agent
    public let role: CandidateRole
    public let stat: CandidateStat
    public init(locator: TranscriptLocator, agent: Agent, role: CandidateRole, stat: CandidateStat) {
        self.locator = locator; self.agent = agent; self.role = role; self.stat = stat
    }
}

public struct LocateResult: Sendable {
    /// The source's coverage generation: it moves when the source can no
    /// longer vouch for what it observed (a dropped event stream, a remount).
    public let coverage: UInt64
    /// Per requested id, in the order they are to be tried.
    public let candidates: [String: [TranscriptCandidate]]
    /// Agents whose listing completed; any other agent failed to list, and
    /// nothing about it proves absence.
    public let complete: Set<Agent>
    /// Per agent with shared inputs: bumps whenever those inputs change.
    public let sharedRevision: [Agent: UInt64]
    public init(coverage: UInt64, candidates: [String: [TranscriptCandidate]], complete: Set<Agent>, sharedRevision: [Agent: UInt64]) {
        self.coverage = coverage; self.candidates = candidates; self.complete = complete; self.sharedRevision = sharedRevision
    }
}

public struct TranscriptRead: Sendable {
    public let identity: TranscriptVerification
    /// Facts, when asked for and the identity verified; nil when the bytes
    /// state no session (identity is still reported).
    public let summary: TranscriptSummary?
    /// The file as it stood after the read.
    public let signature: TranscriptSignature
    public let bytesRead: Int
    /// The revision of the shared inputs these facts used (nil when none were).
    public let sharedRevision: UInt64?
    public init(identity: TranscriptVerification, summary: TranscriptSummary?, signature: TranscriptSignature,
                bytesRead: Int, sharedRevision: UInt64?) {
        self.identity = identity; self.summary = summary; self.signature = signature
        self.bytesRead = bytesRead; self.sharedRevision = sharedRevision
    }
}

public enum TranscriptReadError: Error, Equatable {
    case missing
    case unreadable(String)
    case transport(String)
}

public enum LocateError: Error, Equatable {
    case transport(String)
}

public struct ResolutionRequest: Sendable {
    public let id: String
    public let agent: Agent?
    public let hint: TranscriptLocator?
    public let wanted: Set<SessionCoreField>
    public let awaitingCreation: Bool
    /// Re-arms enrichment even when the transcript has not changed.
    public let explicit: Bool
    public init(id: String, agent: Agent? = nil, hint: TranscriptLocator? = nil,
                wanted: Set<SessionCoreField> = [], awaitingCreation: Bool = false, explicit: Bool = false) {
        self.id = id; self.agent = agent; self.hint = hint; self.wanted = wanted
        self.awaitingCreation = awaitingCreation; self.explicit = explicit
    }
}

public enum ResolutionResult: Sendable {
    case loaded(TranscriptLocator, TranscriptSummary?, Set<SessionCoreField>)
    /// Only a completed enumeration with no candidate can return this verdict.
    case absent
    case awaitingCreation, unreadable, incomplete, mismatch
}

public struct ResolutionBatch: Sendable {
    public let generation: UInt64
    public let results: [String: ResolutionResult]
    public init(generation: UInt64, results: [String: ResolutionResult]) {
        self.generation = generation; self.results = results
    }
}

public struct CatalogQuery: Sendable {
    public let agents: Set<Agent>
    public let newestFirst: Bool
    public let batchSize: Int
    public init(agents: Set<Agent> = [.claude, .codex], newestFirst: Bool = true, batchSize: Int = 200) {
        self.agents = agents; self.newestFirst = newestFirst; self.batchSize = max(1, batchSize)
    }
}

public enum CatalogBatch: Sendable, Equatable {
    case listed(total: Int)
    /// A store (or, with no agent, the whole host) could not be listed.
    case storeFailed(agent: Agent?, message: String)
    case sessions([TranscriptSummary], read: Int, total: Int)
}

public struct AdoptionRequest: Sendable {
    public let directory: String
    public let startedAt: Date
    public let window: TimeInterval
    public init(directory: String, startedAt: Date, window: TimeInterval = 5) {
        self.directory = directory; self.startedAt = startedAt; self.window = window
    }
}

public enum AdoptionResult: Sendable, Equatable {
    case adopted(id: String, locator: TranscriptLocator)
    case ambiguous, none, incomplete
}

public enum SourceChange: Sendable, Equatable {
    /// Members whose resolution changed (the semantic path; gone at the cutover).
    case sessions([String])
    /// Transcripts were written, created or removed. Locators are always
    /// present; ids are what the file names say (possibly none).
    case transcripts(ids: Set<String>, locators: Set<TranscriptLocator>)
    /// The source can no longer vouch for what it observed before.
    case coverageReset(coverage: UInt64)
    /// An agent's shared inputs changed (Codex: history.jsonl, session_index.jsonl).
    case sharedFacts(Agent, revision: UInt64)
}

/// Optional measurement surface; transcript operations do not depend on it.
public protocol HostSourceDiagnostics: Sendable {
    var isMonitoring: Bool { get }
    var metrics: EngineMetrics { get }
}

public enum DirectoryEvidence: Sendable, Equatable {
    case exists, missing, unknown
}

public extension HostSessionSource {
    func directoryEvidence(_ path: String) -> DirectoryEvidence { .unknown }
    func directoryEvidence(_ path: String) async -> DirectoryEvidence { .unknown }
    func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        throw HostSourceError.unsupported("locate")
    }
    func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String, facts: Bool) async throws -> TranscriptRead {
        throw HostSourceError.unsupported("read")
    }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch {
        throw HostSourceError.unsupported("resolve")
    }
    func release(_ ids: [String]) {}
}
