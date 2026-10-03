import Foundation

/// A coherent publication of member resolutions and recorded transcript facts.
public struct EngineSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let resolutions: [String: MemberResolution]
    public let summaries: [String: TranscriptSummary]
    /// Transitional index grouped on the engine queue, reused by the UI adapter.
    /// Includes shared Codex titles; these values must never be used for fills.
    public let legacyIndex: SessionIndex

    public init(generation: UInt64, resolutions: [String: MemberResolution],
                summaries: [String: TranscriptSummary], legacyIndex: SessionIndex = SessionIndex(projects: [])) {
        self.generation = generation
        self.resolutions = resolutions
        self.summaries = summaries
        self.legacyIndex = legacyIndex
    }
}
