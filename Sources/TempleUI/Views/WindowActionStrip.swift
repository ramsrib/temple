import SwiftUI
import AppKit

/// Lets a single-click drag on the launcher's empty area move the window,
/// as the title bar does.
///
/// Used as a `.background(…)` behind the launcher, so a click on a row or a
/// link is handled by that control and never reaches this layer. Double-clicks
/// are not handled here: the title band's belong to TitleBandDoubleClick, the
/// one owner of that gesture, and below the band a double-click on empty page
/// is not a title-bar gesture. (This shim used to zoom on one too, from when
/// the launcher's band could collapse; inside the band that zoomed a second
/// time after AppKit did.)
struct WindowActionStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableStripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableStripView: NSView {
        /// The pending mouse-down; a drag consumes it (via `performDrag`), a
        /// plain click discards it. Deferring the drag to `mouseDragged` keeps a
        /// single click from being swallowed by a drag loop.
        private var mouseDownEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            // Inside the title bar the window drags on its own.
            if let window, event.locationInWindow.y >= window.contentLayoutRect.maxY {
                mouseDownEvent = nil
                return
            }
            mouseDownEvent = event.clickCount == 1 ? event : nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, let window else { return }
            mouseDownEvent = nil
            window.performDrag(with: down)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
        }
    }
}
