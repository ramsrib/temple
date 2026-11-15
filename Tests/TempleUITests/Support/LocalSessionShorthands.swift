import Foundation
import TempleCore
import TempleTestSupport
@testable import TempleUI

// Tests' shorthand for this Mac's sessions (see TempleTestSupport's). The
// app names every session by its id on a host (ADR-041); a test about a
// session on another host says so, and these never stand in for it.

extension SessionOverlayStore {
    func isPinned(_ id: String) -> Bool { isPinned(.local(id)) }
    func isTempleSession(_ id: String) -> Bool { isTempleSession(.local(id)) }
    func isArchived(_ id: String) -> Bool { isArchived(.local(id)) }
    func togglePin(_ id: String) { togglePin(.local(id)) }
    func setArchived(_ archived: Bool, sessionID id: String) { setArchived(archived, session: .local(id)) }
    func rename(_ id: String, to name: String) { rename(.local(id), to: name) }
    func customName(for id: String) -> String? { customName(for: .local(id)) }
    func color(for id: String) -> String? { color(for: .local(id)) }
    func setColor(_ name: String?, for id: String) { setColor(name, for: .local(id)) }
    func generatedTitle(for id: String) -> String? { generatedTitle(for: .local(id)) }
    func recordGeneratedTitle(_ title: String, for id: String, host: HostID = .local) {
        recordGeneratedTitle(title, for: SessionKey(id: id, host: host))
    }
    func touch(_ id: String, host: HostID, at: Date? = nil) { touch(SessionKey(id: id, host: host), at: at) }
    func flushPendingTouch(_ id: String) { flushPendingTouch(.local(id)) }
    func storedRow(_ id: String) -> SessionState? { storedRow(.local(id)) }
    func recordOpened(_ id: String, host: HostID, at date: Date = Date()) { recordOpened(SessionKey(id: id, host: host), at: date) }
    func observeLaunchDirectory(_ id: String, host: HostID, _ directory: String) {
        observeLaunchDirectory(SessionKey(id: id, host: host), directory)
    }
    @discardableResult
    func join(_ id: String, via: JoinedVia, agent: Agent? = nil, locator: TranscriptLocator? = nil,
              core: SessionCore = SessionCore(), carrying marks: CarriedMarks? = nil) -> JoinResult {
        join(SessionKey(id: id, host: core.host), via: via, agent: agent, locator: locator, core: core, carrying: marks)
    }
    func restoreSessions(_ ids: [String], unmasking extra: [ProjectKey] = []) -> RestoreRecord? {
        restoreSessions(ids.map(SessionKey.local), unmasking: extra)
    }
    /// A this-Mac row by id.
    func row(_ id: String) -> SessionState? { rows[.local(id)] }
}

extension OpenSessionsModel {
    func openTab(forSessionID id: String) -> SessionTab? { openTab(for: .local(id)) }
    func sessionTab(withSessionID id: String) -> SessionTab? { sessionTab(for: .local(id)) }
    var openSessionIDsInTabOrder: [String] { openSessionKeysInTabOrder.map(\.id) }
    func forgetClosedTabs(sessionID: String) { forgetClosedTabs(session: .local(sessionID)) }
}

extension AppModel {
    func openSession(id: String) { openSession(.local(id)) }
    func archiveSession(_ id: String, undoManager: UndoManager?) { archiveSession(.local(id), undoManager: undoManager) }
    func archiveSessions(_ ids: [String], undoManager: UndoManager?,
                         changed: @escaping @MainActor (Bool) -> Void = { _ in }) {
        archiveSessions(ids.map(SessionKey.local), undoManager: undoManager, changed: changed)
    }
    func restoreSession(_ id: String, undoManager: UndoManager?) { restoreSession(.local(id), undoManager: undoManager) }
    func transcriptURL(for id: String) -> URL? { transcriptURL(for: .local(id)) }
    func showInSidebar(_ id: String) { showInSidebar(.local(id)) }
}
