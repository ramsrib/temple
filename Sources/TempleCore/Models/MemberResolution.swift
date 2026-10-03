import Foundation

public enum MemberResolution: Hashable, Sendable {
    case resolving
    case awaitingCreation
    case loaded(TranscriptLocator)
    case confirmedAbsent
    case unreadable
    case mismatch
    case incomplete
    public static func loaded(_ url: URL) -> Self { .loaded(TranscriptLocator(localURL: url)) }
}

