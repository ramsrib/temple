import SwiftUI
import AppKit

/// A trackless 8pt scroller — the overlay look, permanently.
///
/// With "Show scroll bars: Always" set in System Settings, AppKit hands every
/// scroll view the legacy scroller: ~15pt wide, on a full-height track.
/// Forcing `scrollerStyle = .overlay` does not survive (AppKit re-applies the
/// system style on the next layout — see SidebarScrollers), but the scroller
/// INSTANCE is ours to replace: this subclass keeps drawing thin no matter
/// which style AppKit re-applies to it.
final class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 8 }

    // No track — the knob floats, like an overlay scroller's.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 2, dy: 1)
        guard !knob.isEmpty else { return }
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2).fill()
    }
}

/// Swaps the enclosing scroll view's scrollers for ThinScroller. Mount as a
/// `.background` of the scrollable view.
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The scroll view exists only once the content has been laid out.
        DispatchQueue.main.async {
            for scrollView in ScrollViewFinder.scrollViews(near: nsView)
            where !(scrollView.verticalScroller is ThinScroller) {
                scrollView.verticalScroller = ThinScroller()
                scrollView.horizontalScroller = ThinScroller()
            }
        }
    }
}

extension View {
    /// Thin, trackless scrollbars for this scrollable view (ThinScroller).
    func thinScrollers() -> some View { background(ThinScrollers()) }
}

/// A `.background` view sits OUTSIDE its scrollable sibling's NSScrollView —
/// neither inside it nor an ancestor of it — so `enclosingScrollView` is nil
/// and walking up never reaches it. Climb to the enclosing container and
/// search back down instead. (Shared with SidebarScrollers.)
enum ScrollViewFinder {
    static func scrollViews(near view: NSView) -> [NSScrollView] {
        var container: NSView? = view.superview
        for _ in 0..<4 {
            guard let current = container else { break }
            let found = descendantScrollViews(of: current)
            if !found.isEmpty { return found }
            container = current.superview
        }
        return []
    }

    static func descendantScrollViews(of view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                found.append(scrollView)
            } else {
                found.append(contentsOf: descendantScrollViews(of: subview))
            }
        }
        return found
    }
}
