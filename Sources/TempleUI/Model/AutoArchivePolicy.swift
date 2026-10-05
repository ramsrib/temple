import Foundation
import TempleCore

/// What the archive sweep would write (ADR-030): a pure plan over the rows,
/// the latest merged snapshot's verdicts, the folder evidence gathered for
/// it and the open tabs. It decides; the overlay writes, under each row's
/// membership.
///
/// A row is a candidate only when nobody is using it: not pinned, not
/// archived, no tab open or restored, idle for `idleAfter`, and not kept by
/// a person (a keep lasts until the session's next activity). A candidate
/// is archived on proof alone, taken when the sweep decides:
/// - its transcript, when the engine's `.confirmedAbsent` for this very
///   membership (the snapshot's host and incarnation for the id must be the
///   row's: an old membership's verdict says nothing about a rejoin) — only
///   a hint — is borne out by the owning host's `proveAbsent`, taken just
///   now, for every agent that could hold the row;
/// - or its folder, when the owning host says it is `.missing`.
/// Every other verdict, an unproven hint, `.unknown` and `.exists` prove
/// nothing. When both hold, the transcript is the reason.
struct AutoArchivePolicy {
    /// Claude's retention cleanup removes only transcripts idle 30 days or
    /// more; the week is for the other causes (an id that never got a file,
    /// a deletion, a folder removed). Nothing touched this week leaves on
    /// its own.
    static let idleAfter: TimeInterval = 7 * 86_400

    /// Rows nobody is using, with the membership a write would name.
    static func candidates(rows: Dictionary<String, SessionState>.Values, openSessionIDs: Set<String>,
                           now: Date) -> [(state: SessionState, ref: MembershipRef)] {
        rows.compactMap { state in
            guard let incarnation = state.incarnation,
                  !state.pinned, !state.archived,
                  !openSessionIDs.contains(state.id),
                  state.keptAt == nil, state.archiveReason == nil,
                  now.timeIntervalSince(Session(state: state).sortDate) >= idleAfter
            else { return nil }
            return (state, MembershipRef(id: state.id, host: state.host, incarnation: incarnation))
        }
    }

    /// The engine's hint for this candidate: an absence it reported for this
    /// very membership. A hint makes the row worth a proof, nothing more.
    static func transcriptGone(_ ref: MembershipRef, in snapshot: EngineSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.resolutions[ref.id] == .confirmedAbsent && snapshot.memberships[ref.id] == ref
    }

    /// One proof per host and agent.
    struct ProofKey: Hashable {
        let host: HostID
        let agent: Agent
    }

    /// Every agent whose store could hold the row: its own, or all of them
    /// when the row never recorded one.
    static func agents(for state: SessionState) -> [Agent] { state.agent.map { [$0] } ?? Agent.allCases }

    /// The proofs a sweep asks for: per host and agent, the hinted
    /// candidates that agent could hold, each with the membership it was
    /// asked for. One call each, however many rows.
    static func proofRequests(rows: Dictionary<String, SessionState>.Values, snapshot: EngineSnapshot?,
                              openSessionIDs: Set<String>, now: Date) -> [ProofKey: [String: MembershipRef]] {
        var requests: [ProofKey: [String: MembershipRef]] = [:]
        for candidate in candidates(rows: rows, openSessionIDs: openSessionIDs, now: now)
        where transcriptGone(candidate.ref, in: snapshot) {
            for agent in agents(for: candidate.state) {
                requests[ProofKey(host: candidate.ref.host, agent: agent), default: [:]][candidate.ref.id] = candidate.ref
            }
        }
        return requests
    }

    /// The folders worth asking about: every candidate's, hinted or not (a
    /// hint the proof does not bear out leaves the folder to decide). One
    /// question per folder, however many rows.
    static func foldersToCheck(rows: Dictionary<String, SessionState>.Values, snapshot: EngineSnapshot?,
                               openSessionIDs: Set<String>, now: Date) -> Set<ProjectKey> {
        Set(candidates(rows: rows, openSessionIDs: openSessionIDs, now: now).compactMap { candidate in
            Session(state: candidate.state).project
        })
    }

    /// The transcript is gone: hinted, and proven just now by every agent
    /// that could hold it — for this very membership: a proof asked for
    /// an earlier one (a leave and rejoin while it ran) proves nothing about
    /// this one.
    static func transcriptProven(_ candidate: (state: SessionState, ref: MembershipRef), snapshot: EngineSnapshot?,
                                 proofs: [ProofKey: AbsenceProof], requested: [ProofKey: [String: MembershipRef]]) -> Bool {
        guard transcriptGone(candidate.ref, in: snapshot) else { return false }
        return agents(for: candidate.state).allSatisfy { agent in
            let key = ProofKey(host: candidate.ref.host, agent: agent)
            return requested[key]?[candidate.ref.id] == candidate.ref && proofs[key]?.proves(candidate.ref.id) == true
        }
    }

    /// `host`: only that host's rows (each host's archives are written as
    /// soon as its own proofs are in).
    static func plan(rows: Dictionary<String, SessionState>.Values, snapshot: EngineSnapshot?,
                     proofs: [ProofKey: AbsenceProof], requested: [ProofKey: [String: MembershipRef]],
                     folders: [ProjectKey: DirectoryEvidence], openSessionIDs: Set<String>, now: Date,
                     host: HostID? = nil) -> [AutoArchiveEntry] {
        candidates(rows: rows, openSessionIDs: openSessionIDs, now: now).compactMap { candidate in
            if let host, candidate.ref.host != host { return nil }
            if transcriptProven(candidate, snapshot: snapshot, proofs: proofs, requested: requested) {
                return AutoArchiveEntry(ref: candidate.ref, reason: .transcriptMissing)
            }
            if let project = Session(state: candidate.state).project, folders[project] == .missing {
                return AutoArchiveEntry(ref: candidate.ref, reason: .folderMissing, directory: project.path)
            }
            return nil
        }
        // Stable for logs and tests; the dictionary's order is not.
        .sorted { $0.ref.id < $1.ref.id }
    }
}
