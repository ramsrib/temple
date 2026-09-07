// uiclick — post real mouse/keyboard events from a shell, for driving Temple in
// a visual check when nothing else can (AppleScript cannot drag; Codex's
// computer-use needs a per-app approval). Pairs with the app's snapshot hook
// (WindowSnapshot.swift): launch with TEMPLE_SNAPSHOT_DIR, drive with this,
// `kill -USR1` for a PNG. See AGENTS.md → "Running the app".
//
//   swiftc -O -o /tmp/uiclick Scripts/uiclick.swift
//   /tmp/uiclick click 87 167             # screen points, top-left origin
//   /tmp/uiclick drag 83 743 88 423 40    # 40 steps; add `hold` to pause 1.5s before release
//   /tmp/uiclick key 16 cmd shift         # ⌘⇧Y (virtual key codes)
//
// Runs under the terminal's Accessibility grant: launch it from a shell whose
// terminal app has Accessibility enabled, or every event is silently dropped.
import CoreGraphics
import Foundation

// uiclick move X Y | click X Y | rclick X Y | dblclick X Y | drag X1 Y1 X2 Y2 [steps] [hold] [esc]
//         | scroll X Y LINES | scrollpx X Y PX | key CODE [cmd] [shift] [ctrl] [alt]
// Coordinates are screen points, top-left origin (CG space).
let args = Array(CommandLine.arguments.dropFirst())
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(args[i])!, y: Double(args[i + 1])!) }
func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.setIntegerValueField(.mouseEventClickState, value: clicks)
    e.post(tap: .cghidEventTap)
}
func sleepMs(_ ms: UInt32) { usleep(ms * 1000) }

switch args.first {
case "move":
    post(.mouseMoved, pt(1))
case "click", "dblclick":
    let p = pt(1); let n: Int64 = args[0] == "dblclick" ? 2 : 1
    post(.mouseMoved, p); sleepMs(80)
    for c in 1...n { post(.leftMouseDown, p, clicks: c); sleepMs(40); post(.leftMouseUp, p, clicks: c); sleepMs(60) }
case "rclick":
    let p = pt(1)
    post(.mouseMoved, p); sleepMs(80)
    post(.rightMouseDown, p, .right); sleepMs(60); post(.rightMouseUp, p, .right)
case "drag":
    let a = pt(1), b = pt(3); let steps = args.count > 5 ? Int(args[5])! : 30
    post(.mouseMoved, a); sleepMs(120)
    post(.leftMouseDown, a); sleepMs(250)                 // hold: lets a drag session start
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        sleepMs(16)
    }
    sleepMs(300)                                           // settle: lets the drop target update
    if args.contains("hold") { sleepMs(1500) }             // time for a snapshot mid-drag
    if args.contains("esc") {                              // cancel the drag before releasing
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)!
            e.post(tap: .cghidEventTap); sleepMs(40)
        }
        sleepMs(300)
    }
    post(.leftMouseUp, b)
case "scroll":   // scroll X Y DY  (DY>0 scrolls content down, i.e. wheel toward the user)
    let p = pt(1); post(.mouseMoved, p); sleepMs(80)
    let dy = Int32(args[3])!
    for _ in 0..<abs(dy) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy > 0 ? -1 : 1, wheel2: 0, wheel3: 0)!
        e.location = p; e.post(tap: .cghidEventTap); sleepMs(12)
    }
case "scrollpx":   // scrollpx X Y PX  (PX>0 scrolls content down)
    let p = pt(1); post(.mouseMoved, p); sleepMs(80)
    let px = Int32(args[3])!; let step: Int32 = px > 0 ? -10 : 10
    for _ in 0..<(abs(px) / 10) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0)!
        e.location = p; e.post(tap: .cghidEventTap); sleepMs(8)
    }
case "key":
    let code = CGKeyCode(UInt16(args[1])!)
    var flags: CGEventFlags = []
    if args.contains("cmd") { flags.insert(.maskCommand) }
    if args.contains("shift") { flags.insert(.maskShift) }
    if args.contains("ctrl") { flags.insert(.maskControl) }
    if args.contains("alt") { flags.insert(.maskAlternate) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap); sleepMs(40)
    }
default:
    print("usage: uiclick move|click|rclick|dblclick X Y | drag X1 Y1 X2 Y2 [steps] [hold] [esc] | key CODE [cmd] [shift] [ctrl] [alt]")
}
