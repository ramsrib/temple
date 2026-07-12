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
            for scrollView in ScrollViewFinder.scrollViews(near: nsView) {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
            }
        }
    }
}
