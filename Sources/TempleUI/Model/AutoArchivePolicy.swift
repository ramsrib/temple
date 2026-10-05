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
/// is archived on proof alone: its transcript is `.confirmedAbsent` (a
/// completed enumeration) for this very membership (the snapshot's host and
/// incarnation for the id must be the row's: an old membership's verdict
/// says nothing about a rejoin), or its owning host says its folder is
/// `.missing`. Every other verdict, `.unknown` and `.exists` prove nothing.
/// When both hold, the transcript is the reason.
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

    /// The folders worth asking about: a candidate's, unless its transcript
    /// already decides it. One question per folder, however many rows.
    /// The transcript verdict holds for this candidate: an absence the
    /// engine proved for this very membership.
    static func transcriptGone(_ ref: MembershipRef, in snapshot: EngineSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.resolutions[ref.id] == .confirmedAbsent && snapshot.memberships[ref.id] == ref
    }

    static func foldersToCheck(rows: Dictionary<String, SessionState>.Values, snapshot: EngineSnapshot?,
                               openSessionIDs: Set<String>, now: Date) -> Set<ProjectKey> {
        Set(candidates(rows: rows, openSessionIDs: openSessionIDs, now: now).compactMap { candidate in
            transcriptGone(candidate.ref, in: snapshot) ? nil : Session(state: candidate.state).project
        })
    }

    static func plan(rows: Dictionary<String, SessionState>.Values, snapshot: EngineSnapshot?,
                     folders: [ProjectKey: DirectoryEvidence], openSessionIDs: Set<String>,
                     now: Date) -> [AutoArchiveEntry] {
        candidates(rows: rows, openSessionIDs: openSessionIDs, now: now).compactMap { candidate in
            if transcriptGone(candidate.ref, in: snapshot) {
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
