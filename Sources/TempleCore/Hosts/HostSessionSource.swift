import Foundation

public enum HostCapability: Hashable, Sendable {
    case liveChanges, revealInFinder, catalog
}

/// Semantic transcript operations for one host. Failures never prove absence.
public protocol HostSessionSource: Sendable {
    var host: HostID { get }
    var capabilities: Set<HostCapability> { get }
    func resolve(_ requests: [ResolutionRequest]) async throws -> ResolutionBatch
    /// Host-owned directory evidence; unknown must not be treated as missing.
    func directoryEvidence(_ path: String) -> DirectoryEvidence
    func release(_ ids: [String])
    func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error>
    func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult
    func changes() -> AsyncThrowingStream<SourceChange, Error>
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
    case storeFailed(Agent, message: String)
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

public enum SourceChange: Sendable {
    case sessions([String])
    case coverageReset(UInt64)
    case sharedTitlesChanged
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
}
