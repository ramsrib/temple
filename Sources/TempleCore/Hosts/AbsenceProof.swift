import Foundation

/// An event a host heard in an agent's listing scope while it was proving
/// absence (`HostSessionSource.proveAbsent`). Only what kind of entry it was
/// about, and its path: the change flags a host's watcher reports are not
/// trustworthy enough to tell an append from a creation (FSEvents keeps
/// reporting "created" and "renamed" on every later write to a file).
public struct ScopeEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A regular file.
        case file
        case directory
        case link
        /// The watcher did not say what kind of entry.
        case unknown
        /// Events were lost, the store root itself changed, or observation
        /// stopped or restarted: nothing heard can be vouched for.
        case lost
    }
    public let path: String
    public let kind: Kind
    public init(path: String, kind: Kind) { self.path = path; self.kind = kind }
}

/// A proof, taken at decision time, that sessions have no transcript of one
/// agent on one host (ADR-030). The archive sweep acts on it; nothing else
/// a host or engine keeps is load-bearing for that decision.
public struct AbsenceProof: Sendable, Equatable {
    /// The listing ran, completed, and met nothing it cannot see past
    /// (ADR-032's rule).
    public let exhaustive: Bool
    /// The host was observing, and nothing it heard from before the listing
    /// to its delivery barrier could change the answer. What it heard, not
    /// everything that happened: ADR-030 names the accepted gap.
    public let quiescent: Bool
    /// The asked ids with no file named for them (meaningful only with both
    /// of the above).
    public let missing: Set<String>

    public init(exhaustive: Bool, quiescent: Bool, missing: Set<String>) {
        self.exhaustive = exhaustive; self.quiescent = quiescent; self.missing = missing
    }

    public static let unproven = AbsenceProof(exhaustive: false, quiescent: false, missing: [])

    /// Whether this proves `id` has no transcript.
    public func proves(_ id: String) -> Bool { exhaustive && quiescent && missing.contains(id) }

    /// Hidden names that cannot hold a transcript (ADR-032).
    public static let allowedHiddenNames: Set<String> = [".DS_Store"]

    /// The decision, from what the host saw:
    ///
    /// | input                                                   | result |
    /// |---------------------------------------------------------|--------|
    /// | listing failed (nil)                                    | not exhaustive, nothing missing |
    /// | listing not exhaustive                                  | not exhaustive |
    /// | not observing, at the start or the end                  | not quiescent |
    /// | a `lost` event                                          | not quiescent |
    /// | an event on a directory, a link, or of unknown kind     | not quiescent |
    /// | an event on a hidden name (not `.DS_Store`)             | not quiescent |
    /// | an event on any entry named for an asked id             | not quiescent |
    /// | an event on a regular file named for no asked id        | ignored — a write, a creation or a removal of such a file cannot make an asked id's file appear or change what the listing covers |
    /// | an asked id with no listed file named for it            | missing |
    ///
    /// Names are compared in the agent's candidate spelling (`candidateKey`).
    public static func decide(ids: Set<String>, format: any TranscriptFormat, listed: [String]?, exhaustive: Bool,
                              events: [ScopeEvent], observing: Bool) -> AbsenceProof {
        let asked = Set(ids.map(format.candidateKey))
        func namedForAsked(_ path: String) -> Bool {
            guard let name = format.name(path: path) else { return false }
            return asked.contains(format.candidateKey(name.threadID))
        }
        func disturbs(_ event: ScopeEvent) -> Bool {
            switch event.kind {
            case .lost, .directory, .link, .unknown: return true
            case .file:
                let name = (event.path as NSString).lastPathComponent
                if name.hasPrefix("."), !allowedHiddenNames.contains(name) { return true }
                return namedForAsked(event.path)
            }
        }
        let quiescent = observing && !events.contains(where: disturbs)
        guard let listed else { return AbsenceProof(exhaustive: false, quiescent: quiescent, missing: []) }
        let found = Set(listed.compactMap { format.name(path: $0).map { format.candidateKey($0.threadID) } })
        return AbsenceProof(exhaustive: exhaustive, quiescent: quiescent,
                            missing: ids.filter { !found.contains(format.candidateKey($0)) })
    }
}
