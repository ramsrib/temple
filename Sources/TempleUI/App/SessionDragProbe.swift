import AppKit
import TempleCore

/// Dev-only (`TEMPLE_SNAPSHOT_DIR` + `TEMPLE_SNAPSHOT_PRESENT=drag-session`):
/// whether a press-and-drag on a sidebar session row starts the row's drag,
/// in the real app. A unit test of `moveSession` says nothing about whether
/// AppKit ever hands the gesture to the row's `.onDrag` (owner, round 3:
/// "i couldn't drag the sessions").
///
/// The mouse events are delivered IN-PROCESS: built here and queued with
/// `NSApp.postEvent`, so they reach this window as a real press would once
/// routed to it. Never CGEvent, never the system event stream: nothing
/// outside this process sees them (AGENTS.md). Queued, not sent, because a
/// control that tracks the mouse on press waits in its own loop for the
/// drags and the release; sent one by one, the first would never return.
///
/// `TEMPLE_PROBE_DRAG="x1,y1,x2,y2"` (window points from the top-left) says
/// where to press and where to drag to. The verdict is whether the row's drag
/// began (`AppModel.draggedSession` was set): the drag session AppKit then
/// runs on synthetic events proves nothing either way. It logs to stderr and
/// captures the window before and after.
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
        WindowSnapshot.captureNow()
        let height = window.frame.height
        let from = NSPoint(x: points[0], y: height - points[1])
        let to = NSPoint(x: points[2], y: height - points[3])
        var began: SessionKey?
        let poll = Timer(timeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                if began == nil, let dragged = model.draggedSession {
                    began = dragged
                    log("row drag BEGAN for \(dragged.id)")
                }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        let start = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ at: NSPoint, _ offset: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: start + offset,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        var queue: [NSEvent] = []
        if let down = event(.leftMouseDown, from, 0) { queue.append(down) }
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let at = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let drag = event(.leftMouseDragged, at, 0.02 * Double(step)) { queue.append(drag) }
        }
        if let up = event(.leftMouseUp, to, 0.02 * Double(steps + 1)) { queue.append(up) }
        log("pressing at \(from) in a \(Int(window.frame.width))×\(Int(height)) window, dragging to \(to)")
        for item in queue { NSApp.postEvent(item, atStart: false) }
        // A run-loop timer in the common modes, not the main queue: a
        // control or a drag session tracking the mouse runs its own loop,
        // in which the main queue does not drain.
        let verdict = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                poll.invalidate()
                log(began == nil ? "row drag did NOT begin (by 1.5 s)" : "verdict: began")
                WindowSnapshot.captureNow()
            }
        }
        RunLoop.main.add(verdict, forMode: .common)
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("[drag-probe] \(line)\n".utf8))
    }
}
