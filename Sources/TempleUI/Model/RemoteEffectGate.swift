import Foundation
import TempleCore

/// Every asynchronous completion in the remote path that touches a tab, a
/// row, a sheet or tab persistence (docs/designs/remote-ssh.md, phase 1a
/// notes). Each goes through `RemoteEffectGate.admit` right before its
/// effect, after its last await. Durable work is not a completion here: run
/// rows, flags, and Discard's dismissal and row disposition happen whatever
/// the gate says (owned by `RemoteOperations`).
///
/// This list is maintained by hand; `RemoteGateWalkTests` proves that each
/// case is gated, not that the list is complete against the source. Four
/// asynchronous mechanisms are deliberately outside it, each a lifecycle of
/// its own:
///
/// - **The title persistence task** (`schedulePersistForTitleChurn`) saves
///   the whole tab set, local and remote alike, and is already cancelled by
///   `prepareForQuit` and refuses while quitting; it applies no remote
///   evidence.
/// - **The launcher's live-run cache** (`RemoteHostLauncher.refreshLiveSessions`)
///   updates only that launcher's own cache, read synchronously by a row's
///   menu; a retired launcher's cache is unreachable once its entry goes.
/// - **The Test connection's callbacks** (`ConnectionTest`) belong to the
///   Test sheet: the sheet's close cancels the test, and its result is a
///   memory-only summary (`RemoteHostsModel.recordSummary`, which drops a
///   test that is no longer the host's current one).
/// - **The local launch result channel** is this Mac's, not a host's.
/// - **The core join of a claimed Codex id** (phase 1b), at adoption and in
///   the launch's reconciliation, is durable work, like the claim it
///   follows: it happens whatever the tab is doing, and only the quit
///   defers it (to the next launch's reconciliation, which finds the claim
///   unjoined). What the tab shows of it is `.identityResult`.
///
/// The settle timer is not exempt: for a tab on a host it is `.settle`.
public enum RemoteCompletion: String, CaseIterable, Sendable {
    /// An open's answer: spawn the tab's client, show the decision, or the refusal.
    case openResult
    /// A record poll found the pane's `ok`: the folder, row and tab.
    case pollDirectory
    /// The exit's final collection found the pane's `ok`: the same.
    case exitCollectDirectory
    /// The exit found the pane could not enter its folder: the header.
    case exitFailedToStart
    /// The exit check's verdict: Disconnected, Unknown, a resume, an early
    /// failure kept, or the tab closed.
    case exitVerdict
    /// What an agent that ended at once printed: the header's lines.
    case exitDiagnostics
    /// A storage failure reported by a collection: one notice.
    case storageNotice
    /// The working prompt's Stop: the tab closes, or keeps its header.
    case explicitStopOutcome
    /// "Sessions on <host>" stopped a session with a connected tab.
    case trackedStopTabOutcome
    /// A close's stop was not confirmed: one notice.
    case closeStopNotice
    /// A row menu's Stop was not confirmed: one notice.
    case rowStopNotice
    /// Discard could not be written: one notice. (The dismissal and the
    /// row's disposition are durable work, never gated.)
    case discardNotice
    /// The activity settle timer (working → idle) on a tab on a host.
    case settle
    /// The startup-evidence deadline: "Still connecting to <host>…".
    case startupDeadline
    /// Staging after the spawn was refused: the tab's client goes (and an
    /// attach says why in a notice). The run's record is durable work.
    case stageFailure
    /// The launch-time contact: the sidebar's left-running line.
    case contactNotice
    /// "Sessions on <host>" received its list.
    case sheetLoad
    /// "Sessions on <host>" received a stop's outcome.
    case sheetStopOutcome
    /// The folder sheet received its check (and may start a session).
    case folderCheckResult
    // Codex identity (phase 1b)
    /// A new or pending Codex open's answer: spawn, the ended question, or
    /// the session it turned out to be.
    case pendingOpenResult
    /// An identity check's (or a yes's) outcome reached the tab: it becomes
    /// the session, or says why it couldn't.
    case identityResult
    /// The suggestions to ask about reached the tab.
    case suggestionsLoaded
    /// The user's yes could not be claimed: the tab says why.
    case confirmResult
    /// Closing a pending Codex tab: the stop's outcome, and the question
    /// when Codex ended unidentified.
    case pendingStopOutcome
    /// The launch's pending Codex chips, restored from the runs.
    case pendingRestore
    /// Discard of a pending Codex session could not be written: one notice.
    case pendingDiscardNotice
    /// A decline, or a claim's storage, could not be written: one notice.
    case identityNotice
}

/// The right to apply one completion's effect, taken before its await:
/// what the tab, host and sheet were when the work began.
public struct RemoteTicket {
    weak var tab: SessionTab?
    let host: HostID
    let launcher: ObjectIdentifier?
    let openToken: UUID?
    let handle: String?
    let attachment: Int?
    let sheet: UUID?
}

/// One gate for every completion: it checks, after the last await, that
/// the app is not quitting, the work was not cancelled, the host's launcher
/// is the one the work began with, and, for a tab, that it is still open
/// with the same open token, handle and attachment (and, when one was read,
/// that the run has no newer attachment); for a sheet, that it is still
/// the one on screen. It counts what it admits and suppresses, so a test
/// can walk every completion.
@MainActor
public final class RemoteEffectGate {
    var isQuitting: () -> Bool = { false }
    var launcher: (HostID) -> AnyObject? = { _ in nil }
    var isMember: (SessionTab) -> Bool = { _ in false }
    var sheetIsActive: (UUID) -> Bool = { _ in false }

    public private(set) var admitted: [RemoteCompletion: Int] = [:]
    public private(set) var suppressed: [RemoteCompletion: Int] = [:]

    public init() {}

    func ticket(for tab: SessionTab) -> RemoteTicket {
        RemoteTicket(tab: tab, host: tab.host, launcher: launcher(tab.host).map(ObjectIdentifier.init),
                     openToken: tab.remote?.openToken, handle: tab.remote?.handle, attachment: tab.remote?.attachment,
                     sheet: nil)
    }

    func ticket(host: HostID, sheet: UUID? = nil) -> RemoteTicket {
        RemoteTicket(tab: nil, host: host, launcher: launcher(host).map(ObjectIdentifier.init), openToken: nil,
                     handle: nil, attachment: nil, sheet: sheet)
    }

    /// Completions that apply run evidence to a tab: each must read the
    /// run's persisted attachment after its last await and pass it, so
    /// another Temple instance attaching to the run (or a newer open here)
    /// suppresses it.
    static let requiresRunEvidence: Set<RemoteCompletion> = [
        .pollDirectory, .exitCollectDirectory, .exitFailedToStart, .exitDiagnostics, .exitVerdict,
    ]

    /// Whether `completion`'s effect may happen now. `runAttachment`: the
    /// run's attachment as just read; mandatory (a missing one suppresses)
    /// for the completions that apply run evidence.
    func admit(_ completion: RemoteCompletion, _ ticket: RemoteTicket, runAttachment: Int?? = nil) -> Bool {
        let evidenceOK = !Self.requiresRunEvidence.contains(completion) || runAttachment != nil
        let ok = evidenceOK && valid(ticket, runAttachment: runAttachment)
        if ok { admitted[completion, default: 0] += 1 } else { suppressed[completion, default: 0] += 1 }
        return ok
    }

    private func valid(_ ticket: RemoteTicket, runAttachment: Int??) -> Bool {
        guard !isQuitting(), !Task.isCancelled else { return false }
        guard launcher(ticket.host).map(ObjectIdentifier.init) == ticket.launcher, ticket.launcher != nil else { return false }
        if let sheet = ticket.sheet, !sheetIsActive(sheet) { return false }
        guard ticket.openToken != nil || ticket.handle != nil else { return true }
        guard let tab = ticket.tab, isMember(tab), let state = tab.remote, state.openToken == ticket.openToken else { return false }
        if let handle = ticket.handle, state.handle != handle { return false }
        if let attachment = ticket.attachment, state.attachment != attachment { return false }
        if let observed = runAttachment, observed != ticket.attachment { return false }
        return true
    }
}
