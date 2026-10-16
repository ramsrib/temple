import Foundation
import TempleCore

/// Every asynchronous completion in the remote path that touches a tab, a
/// row, a sheet or tab persistence (docs/designs/remote-ssh.md, phase 1a
/// notes). Each goes through `RemoteEffectGate.admit` right before its
/// effect, after its last await. Durable writes of outcomes (run rows,
/// flags) are not completions here: they happen whatever the gate says.
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
    /// Discard was written: the row goes (or is archived).
    case discardOutcome
    /// The launch-time contact: the sidebar's left-running line.
    case contactNotice
    /// "Sessions on <host>" received its list.
    case sheetLoad
    /// "Sessions on <host>" received a stop's outcome.
    case sheetStopOutcome
    /// The folder sheet received its check (and may start a session).
    case folderCheckResult
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

    /// Whether `completion`'s effect may happen now. `runAttachment`: the
    /// run's attachment as just read, when the completion read it.
    func admit(_ completion: RemoteCompletion, _ ticket: RemoteTicket, runAttachment: Int?? = nil) -> Bool {
        let ok = valid(ticket, runAttachment: runAttachment)
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
