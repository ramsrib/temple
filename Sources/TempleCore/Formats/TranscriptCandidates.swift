import Foundation

/// One rule for which of a member's files to try, shared by every host.
public enum TranscriptCandidates {
    public struct Assignment: Hashable, Sendable {
        public let path: String
        public let role: CandidateRole
        public init(path: String, role: CandidateRole) { self.path = path; self.role = role }
    }

    /// Roles for the files that could hold `id`, in the order they are tried:
    /// the selected file, then the hint, then alternates.
    ///
    /// - `listed`: paths the host's listing named for this id.
    /// - `hint`: the row's recorded transcript path, if any. A hint named for
    ///   the same thread joins the thread's files only when `hintPresent` (a
    ///   new revert can be recorded before a listing sees it); it is never a
    ///   separate `hinted` candidate while the agent has a selection, so an
    ///   older canonical rollout cannot override a revert. Any other hint —
    ///   another file name, another thread's, every Claude hint — is `hinted`.
    public static func assign(id: String, format: any TranscriptFormat, listed: [String],
                              hint: String?, hintPresent: Bool = true) -> [Assignment] {
        var names: [(path: String, name: TranscriptName)] = []
        var seen = Set<String>()
        for path in listed where seen.insert(path).inserted {
            if let name = format.name(path: path), name.threadID == id { names.append((path, name)) }
        }
        let hintName = hint.flatMap { format.name(path: $0) }
        if let hint, hintPresent, let hintName, hintName.threadID == id, !seen.contains(hint) {
            names.append((hint, hintName))
            seen.insert(hint)
        }
        let selected = format.select(names)
        var result: [Assignment] = []
        if let selected { result.append(Assignment(path: selected, role: .selected)) }
        var hinted: String?
        if let hint, hint != selected {
            let sameThread = hintName?.threadID == id
            if !(sameThread && selected != nil) {
                hinted = hint
                result.append(Assignment(path: hint, role: .hinted))
            }
        }
        let alternates = names.filter { $0.path != selected && $0.path != hinted }
            .sorted { lhs, rhs in
                if selected != nil {
                    // Codex: the order the CLI would fall back through.
                    let l = lhs.name.selectionKey ?? "", r = rhs.name.selectionKey ?? ""
                    return l == r ? lhs.path > rhs.path : l > r
                }
                return lhs.path < rhs.path
            }
        result += alternates.map { Assignment(path: $0.path, role: .alternate) }
        return result
    }

    /// The candidates a resolution may try: alternates only when there is no
    /// selected file, or the selected file is proven missing. An unreadable,
    /// incomplete or mismatched selected file never lets an older rollout load.
    public static func permitted(_ assignments: [Assignment], selectedMissing: Bool) -> [Assignment] {
        let hasSelected = assignments.contains { $0.role == .selected }
        return assignments.filter { $0.role != .alternate || !hasSelected || selectedMissing }
    }
}
