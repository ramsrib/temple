import SwiftUI
import AppKit

/// Restores the native title-bar mouse gestures that a `.hiddenTitleBar` window
/// otherwise loses on our custom header strip: a **double-click** performs the
/// system "double-click a window's title bar to…" action (Maximize/Minimize/
/// None, read live from `AppleActionOnDoubleClick`), and a **single-click drag**
/// moves the window.
///
/// Used as a `.background(…)` behind the strip's controls, so a click on a chip,
/// the `+`, or the search field is handled by that control and never reaches
/// this layer — only clicks in the empty drag area do.
struct WindowActionStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableStripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableStripView: NSView {
        /// The pending mouse-down; a drag consumes it (via `performDrag`), a
        /// plain click discards it. Deferring the drag to `mouseDragged` keeps a
        /// single click — and the first click of a double-click — from being
        /// swallowed by a drag loop.
        private var mouseDownEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let window {
                mouseDownEvent = nil
                Self.performSystemDoubleClickAction(on: window)
            } else {
                mouseDownEvent = event
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, let window else { return }
            mouseDownEvent = nil
            window.performDrag(with: down)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
        }

        /// Mirror System Settings → Desktop & Dock → "Double-click a window's
        /// title bar to…". Unset defaults to zoom (the macOS default).
        private static func performSystemDoubleClickAction(on window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)   // "Maximize" or unset
            }
        }
    }
}
