import Foundation

/// A coherent publication of member resolutions and recorded transcript facts.
public struct EngineSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let resolutions: [String: MemberResolution]
    public let summaries: [String: TranscriptSummary]
    public init(generation: UInt64, resolutions: [String: MemberResolution],
                summaries: [String: TranscriptSummary]) {
        self.generation = generation
        self.resolutions = resolutions
        self.summaries = summaries
    }
}
