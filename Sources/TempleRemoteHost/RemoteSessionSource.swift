import Foundation
import TempleCore

/// A host's entry in the registry before Temple reads anything there.
///
/// Phase 0 registers every enabled host (whether or not it was tested) and
/// runs nothing on it from here: this source never execs. Its answers are
/// the v1 ones for what it cannot know (docs/designs/remote-ssh.md section
/// 6): no catalog, no live changes, a locate that lists nothing and proves
/// nothing (`complete` is empty), reads that report a transport failure,
/// folder evidence that is always unknown, and absence never proven. So a
/// remote row is never dimmed, never tagged, never auto-archived.
public struct RemoteSessionSource: HostSessionSource {
    public let host: HostID
    public var capabilities: Set<HostCapability> { [] }

    public init(host: HostID) {
        precondition(!host.isLocal)
        self.host = host
    }

    public func catalog(_ query: CatalogQuery) -> AsyncThrowingStream<CatalogBatch, Error> {
        let name = host.rawValue
        return AsyncThrowingStream { continuation in
            continuation.yield(.storeFailed(agent: nil, message: "Temple doesn't list sessions on \(name)."))
            continuation.finish()
        }
    }

    public func adopt(_ request: AdoptionRequest) async throws -> AdoptionResult { .incomplete }

    /// Nothing ever changes from here; the stream ends with its consumer.
    public func changes() -> AsyncThrowingStream<SourceChange, Error> {
        AsyncThrowingStream { _ in }
    }

    public func locate(_ requests: [LocateRequest]) async throws -> LocateResult {
        LocateResult(coverage: 0, candidates: [:], complete: [], sharedRevision: [:])
    }

    public func read(_ locator: TranscriptLocator, agent: Agent, expecting id: String,
                     facts: Bool) async throws -> TranscriptRead {
        throw TranscriptReadError.transport("Temple doesn't read transcripts on \(host.rawValue) yet.")
    }

    public func directoryEvidence(_ path: String) async -> DirectoryEvidence { .unknown }

    public func proveAbsent(ids: Set<String>, agent: Agent) async -> AbsenceProof { .unproven }
}
