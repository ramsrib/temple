import AppKit
import TempleCore

/// Dev-only (`TEMPLE_SNAPSHOT_DIR` + `TEMPLE_SNAPSHOT_PRESENT=drag-session`):
/// a press, drag and release on a sidebar session row, in the real app, and
/// what came of it: whether the sidebar's order changed, and whether a tab
/// opened or switched (a drag must not; a click must).
///
/// The events are delivered IN-PROCESS: built here and posted to this app's
/// own queue a frame apart, so they reach this window as a real gesture
/// would once routed to it. Never CGEvent, never the system event stream:
/// nothing outside this process sees them (AGENTS.md). The reorder is an
/// in-app gesture (no system drag session), so the whole gesture runs on
/// these events, release included.
///
/// `TEMPLE_PROBE_DRAG="x1,y1,x2,y2"` (window points from the top-left) is
/// where to press and where to release; equal points make it a click.
/// `TEMPLE_PROBE_ESCAPE=1` presses Escape before the release. It logs to
/// stderr and captures the window before, mid-drag and after.
@MainActor
enum SessionDragProbe {
    static let mode = "drag-session"

    static func run(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        let points = (env["TEMPLE_PROBE_DRAG"] ?? "").split(separator: ",").compactMap { Double($0) }
        guard points.count == 4, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            log("no TEMPLE_PROBE_DRAG=x1,y1,x2,y2 or no window")
            return
        }
        let escape = env["TEMPLE_PROBE_ESCAPE"] == "1"
        let height = window.frame.height
        let from = NSPoint(x: points[0], y: height - points[1])
        let to = NSPoint(x: points[2], y: height - points[3])
        let orderBefore = order(model)
        let tabBefore = model.openSessions.activeTabID
        let tabsBefore = model.openSessions.tabs.count
        WindowSnapshot.captureNow()

        func mouse(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        var steps: [() -> Void] = []
        steps.append { if let e = mouse(.leftMouseDown, from) { NSApp.postEvent(e, atStart: false) } }
        let moves = from == to ? 0 : 16
        for step in 0..<moves {
            let t = Double(step + 1) / Double(moves)
            let at = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            steps.append { if let e = mouse(.leftMouseDragged, at) { NSApp.postEvent(e, atStart: false) } }
        }
        if moves > 0 { steps.append { WindowSnapshot.captureNow() } }     // mid-drag: the lift and the gap
        if escape {
            steps.append {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                                            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) {
                    // Sent, not posted: a snapshot run's app is never
                    // active, and a queued key for an inactive app is
                    // dropped before the local monitors see it.
                    NSApp.sendEvent(e)
                }
            }
        }
        steps.append { if let e = mouse(.leftMouseUp, to) { NSApp.postEvent(e, atStart: false) } }
        log("\(moves == 0 ? "clicking" : "dragging") from \(from) to \(to) in a \(Int(window.frame.width))×\(Int(height)) window\(escape ? ", Escape before release" : "")")
        // A frame apart: a gesture sees movement over time, as from a hand.
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 0.016 * Double(index)) { step() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 0.016 * Double(steps.count) + 0.8) {
            let orderAfter = order(model)
            let changed = orderAfter.filter { orderBefore[$0.key] != $0.value }
            log(changed.isEmpty ? "sidebar order: unchanged"
                : changed.map { "sidebar order changed in \($0.key.name): \(orderBefore[$0.key]?.map(\.prefix8) ?? []) -> \($0.value.map(\.prefix8))" }
                    .joined(separator: "; "))
            log("tabs: \(tabsBefore) -> \(model.openSessions.tabs.count); active tab \(tabBefore == model.openSessions.activeTabID ? "unchanged" : "CHANGED")")
            log("session sort: \(model.sidebarOptions.sessionSort)")
            WindowSnapshot.captureNow()
        }
    }

    private static func order(_ model: AppModel) -> [ProjectKey: [String]] {
        Dictionary(uniqueKeysWithValues: model.displayProjects.map { ($0.key, $0.sessions.map(\.sessionID)) })
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("[drag-probe] \(line)\n".utf8))
    }
}

private extension String {
    var prefix8: String { String(prefix(8)) }
}
