import AppKit
import SwiftUI

/// Turns off AppKit's spring-loading on the sidebar's split-view item.
///
/// `NavigationSplitView` builds the sidebar as an `NSSplitViewItem` with sidebar
/// behavior, and AppKit ships those with `isSpringLoaded == true` (documented in
/// `NSSplitViewItem.h`): during a drag, hovering the collapsed edge — or force
/// clicking it — "temporarily" uncollapses the item. In use that read as the
/// sidebar opening by itself: a file dragged into the terminal that crossed the
/// left edge. Inferred from the screenshot that reported it (ADR-019), not
/// instrumented: the expansion bypasses the item's collapsed flag, so everything
/// downstream keeps its collapsed-state layout — the rail's buttons stay beside
/// the traffic lights, the tab strip keeps its old leading edge, and SwiftUI
/// never writes `sidebarVisibility`, so the next ⌘B visibly does nothing (it
/// assigns shown to a sidebar the model already thinks is hidden).
///
/// SwiftUI's `.springLoadingBehavior(.disabled)` does not reach the item —
/// measured on the split view and on the sidebar column, the flag stays on
/// (ADR-019) — so this reaches the controller through the split view's delegate.
///
/// Like the titlebar band claim, it re-applies rather than latches: SwiftUI can
/// rebuild the split view controller (a detail-pane layout change rewraps it —
/// see AGENTS.md), and a rebuilt item is spring-loaded again. The split view is
/// cached weakly, so a re-apply is a delegate cast and a short loop; the window
/// is walked only when the cache is empty or points outside this window.
struct SidebarSpringLoadingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> DisablerView { DisablerView() }
    func updateNSView(_ view: DisablerView, context: Context) { view.apply() }
    static func dismantleNSView(_ view: DisablerView, coordinator: ()) { view.stopObserving() }

    /// Clears `isSpringLoaded` on every sidebar item under `root`. Returns how
    /// many items it changed, so a test can tell "found and fixed" from "found
    /// nothing" — a walk that misses the split view would otherwise pass.
    @discardableResult
    static func disableSpringLoading(under root: NSView) -> Int {
        var changed = 0
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView { changed += disableSpringLoading(in: split) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return changed
    }

    @discardableResult
    static func disableSpringLoading(in split: NSSplitView) -> Int {
        guard let controller = split.delegate as? NSSplitViewController else { return 0 }
        var changed = 0
        for item in controller.splitViewItems where item.behavior == .sidebar && item.isSpringLoaded {
            item.isSpringLoaded = false
            changed += 1
        }
        if changed > 0 {
            // Once per (re)build in practice. Visible in `log stream`, which is
            // the only way to see that the walk found the real split view.
            TempleUILog.launch.debug("sidebar spring-loading disabled on \(changed, privacy: .public) item(s)")
        }
        return changed
    }

    /// The first split view under `root` whose delegate is a split view
    /// controller — SwiftUI's, in this window.
    static func controlledSplitView(under root: NSView) -> NSSplitView? {
        if let split = root as? NSSplitView, split.delegate is NSSplitViewController { return split }
        for sub in root.subviews {
            if let found = controlledSplitView(under: sub) { return found }
        }
        return nil
    }

    /// Invisible; sits as the split view's background so it shares its window.
    final class DisablerView: NSView {
        private var resizeObserver: NSObjectProtocol?
        /// The split view the last apply found. A rebuild leaves this pointing
        /// at a view that is no longer in the window (or deallocated), which
        /// is the signal to walk again.
        private weak var split: NSSplitView?

        deinit { stopObserving() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            // A rebuilt split view lays its columns out before any layout pass
            // of ours runs; its resize notification is the earliest hook, and a
            // collapse or expand fires it too. Filtered to our window so a
            // split view elsewhere (Settings, a panel) costs nothing.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let split = note.object as? NSSplitView,
                          split.window === self.window else { return }
                    if SidebarSpringLoadingDisabler.disableSpringLoading(in: split) > 0 {
                        self.split = split
                    }
                }
            }
            apply()
        }

        override func layout() {
            super.layout()
            apply()
        }

        func stopObserving() {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
        }

        func apply() {
            guard let window, let contentView = window.contentView else { return }
            if let split, split.window === window {
                SidebarSpringLoadingDisabler.disableSpringLoading(in: split)
                return
            }
            guard let found = SidebarSpringLoadingDisabler.controlledSplitView(under: contentView) else { return }
            split = found
            SidebarSpringLoadingDisabler.disableSpringLoading(in: found)
        }
    }
}
