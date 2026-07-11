import SwiftUI
import AppKit

/// Takes the scrollers off the enclosing scroll view.
///
/// With "Show scroll bars: Always" set in System Settings, AppKit hands a List
/// the *legacy* scroller: a permanently visible ~15pt bar with a track, running
/// the full height beside every row. Setting `scrollerStyle = .overlay` does not
/// survive — AppKit re-applies the system style on the next layout — so the
/// scrollers are removed outright. The sidebar is a short list whose extent you
/// can see, not a document you navigate by scroll position.
struct SidebarScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The scroll view exists only once the List has been laid out.
        DispatchQueue.main.async {
            for scrollView in scrollViews(near: nsView) {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
            }
        }
    }

    /// A `.background` view sits OUTSIDE the List's NSScrollView — it is neither
    /// inside it nor an ancestor of it — so `enclosingScrollView` is nil and
    /// walking up the superview chain never reaches it. Climb to the enclosing
    /// container and search back down instead.
    private func scrollViews(near view: NSView) -> [NSScrollView] {
        var container: NSView? = view.superview
        for _ in 0..<4 {
            guard let current = container else { break }
            let found = descendantScrollViews(of: current)
            if !found.isEmpty { return found }
            container = current.superview
        }
        return []
    }

    private func descendantScrollViews(of view: NSView) -> [NSScrollView] {
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
