import Foundation

/// One host engine's full state, published whole: every member's resolution
/// and, for each member whose row still lacks something a transcript can
/// supply, the facts the engine currently authorizes for it. A snapshot is
/// state, never an event: a newer one replaces an older one entirely, so a
/// consumer that only ever sees the latest loses nothing.
public struct EngineSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let resolutions: [String: MemberResolution]
    public let facts: [String: AuthorizedFacts]
    public init(generation: UInt64, resolutions: [String: MemberResolution],
                facts: [String: AuthorizedFacts] = [:]) {
        self.generation = generation
        self.resolutions = resolutions
        self.facts = facts
    }
}

/// Transcript facts the engine stands behind for one membership, at one point
/// of its work. The consumer persists them only while the latest snapshot
/// still carries the same `authorization` for the id: a snapshot without
/// them, or with another authorization, revokes them — and any write still
/// pending or retrying for them is dropped, never applied late.
public struct AuthorizedFacts: Equatable, Sendable {
    /// Moves on every invalidation the engine knows of: a stop/start (run
    /// epoch), anything that made its work on the member stale (operation
    /// revision: coverage reset, reconnect, shared-fact change, explicit
    /// refresh, candidate replacement, a transcript event, a membership
    /// change) and the membership itself (incarnation, checked again in SQL).
    public struct Authorization: Hashable, Sendable {
        public let runEpoch: UInt64
        public let opRevision: UInt64
        public let incarnation: String
        public init(runEpoch: UInt64, opRevision: UInt64, incarnation: String) {
            self.runEpoch = runEpoch; self.opRevision = opRevision; self.incarnation = incarnation
        }
    }

    public let authorization: Authorization
    public var incarnation: String { authorization.incarnation }
    /// The verified transcript; becomes the row's hint.
    public let locator: TranscriptLocator
    public let agent: Agent
    /// The file version the facts describe.
    public let signature: TranscriptSignature
    /// The source coverage the facts were read under.
    public let coverage: UInt64
    /// The shared-input revision the summary's titles were read at (nil: none used).
    public let sharedRevision: UInt64?
    /// Parsed facts; nil when only the hint (verified locator and agent) is
    /// authorized — a complete row whose recorded path moved.
    public let summary: TranscriptSummary?

    public init(authorization: Authorization, locator: TranscriptLocator, agent: Agent,
                signature: TranscriptSignature, coverage: UInt64, sharedRevision: UInt64?,
                summary: TranscriptSummary?) {
        self.authorization = authorization; self.locator = locator; self.agent = agent
        self.signature = signature; self.coverage = coverage; self.sharedRevision = sharedRevision
        self.summary = summary
    }

    /// The core fields these facts can fill (`SessionCore(filling:)`).
    public var suppliedFields: Set<SessionCoreField> {
        guard let summary else { return [] }
        var fields: Set<SessionCoreField> = [.agent, .lastActiveAt]
        if summary.cwd != nil { fields.insert(.directory) }
        if summary.titleFact != nil { fields.insert(.title) }
        return fields
    }

    /// Whether persisting these facts could still change this row: a NULL
    /// field they supply, or a hint (path or agent) the row does not have.
    public func wouldChange(_ row: SessionState) -> Bool {
        if row.transcriptPath != locator.path || row.agent == nil { return true }
        return !suppliedFields.isDisjoint(with: row.missingCoreFields)
    }
}

public extension SessionState {
    /// The core fields a transcript could still fill (NULL in the row).
    var missingCoreFields: Set<SessionCoreField> {
        var missing: Set<SessionCoreField> = []
        if agent == nil { missing.insert(.agent) }
        if directory == nil { missing.insert(.directory) }
        if title == nil { missing.insert(.title) }
        if lastActiveAt == nil { missing.insert(.lastActiveAt) }
        return missing
    }
}
