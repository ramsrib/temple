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

    /// The candidates a resolution may try, in `assign`'s order. Without a
    /// selection, all of them. With one, the selection chain — the selected
    /// file, then the alternates in the CLI's fallback order — ends at its
    /// first file not proven missing: that file decides, and when it is
    /// unreadable, incomplete or another session's, no older rollout loads
    /// in its place. The same rule picks a catalog's file (`catalogPick`).
    /// A hint is outside the chain and always permitted.
    public static func permitted<Candidate>(_ candidates: [Candidate], role: (Candidate) -> CandidateRole,
                                            missing: (Candidate) -> Bool) -> [Candidate] {
        guard candidates.contains(where: { role($0) == .selected }) else { return candidates }
        var chainOpen = true
        return candidates.filter { candidate in
            guard role(candidate) != .hinted else { return true }
            guard chainOpen else { return false }
            if !missing(candidate) { chainOpen = false }
            return true
        }
    }
}

// MARK: - Catalog selection

public extension TranscriptCandidates {
    /// One thread of one agent in a host's listing, as a catalog reads it.
    struct CatalogThread: Hashable, Sendable {
        public let threadID: String
        /// The files to try, in member resolution's order (`assign`): the
        /// selected file first when the agent has a selection, then the
        /// alternates.
        public let paths: [String]
        /// The agent selects among the thread's files (Codex). Then a file
        /// is passed over only when it is proven missing; otherwise every
        /// file is an alternate, tried until one reads (Claude).
        public let hasSelection: Bool
        public init(threadID: String, paths: [String], hasSelection: Bool) {
            self.threadID = threadID; self.paths = paths; self.hasSelection = hasSelection
        }
    }

    /// What reading one of a thread's files came to.
    enum CatalogAttempt<Value> {
        case read(Value)
        /// The file is gone (proven, not merely unreadable).
        case missing
        /// The file exists and did not yield a summary of this thread:
        /// unreadable, incomplete, unparseable, or another session's.
        case failed
    }

    /// A catalog's threads, before anything is parsed: the listed files the
    /// agent's names claim, grouped per thread with the same selection
    /// function and tie-breaker as member resolution. A file whose name is
    /// not one the agent writes is no thread's: resolution never lists it,
    /// and neither does the catalog. Sorted by thread id.
    static func catalogThreads(format: any TranscriptFormat, listed: [String]) -> [CatalogThread] {
        var byThread: [String: [String]] = [:]
        for path in Set(listed) {
            guard let name = format.name(path: path) else { continue }
            byThread[name.threadID, default: []].append(path)
        }
        return byThread.keys.sorted().map { id in
            let assigned = assign(id: id, format: format, listed: byThread[id]!.sorted(), hint: nil)
            return CatalogThread(threadID: id, paths: assigned.map(\.path),
                                 hasSelection: assigned.first?.role == .selected)
        }
    }

    /// The thread's one summary, or nil. With a selection, the first file
    /// not proven missing decides: when it is unreadable, incomplete or
    /// another session's, nothing is emitted — an older rollout is read
    /// only past files proven missing (`permitted`). Without one, the first
    /// file that reads.
    static func catalogPick<Value>(_ thread: CatalogThread, attempt: (String) -> CatalogAttempt<Value>) -> Value? {
        for path in thread.paths {
            switch attempt(path) {
            case .read(let value): return value
            case .missing: continue
            case .failed: if thread.hasSelection { return nil }
            }
        }
        return nil
    }
}
