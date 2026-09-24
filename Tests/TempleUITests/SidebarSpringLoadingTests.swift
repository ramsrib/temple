import AppKit
import SwiftUI
import XCTest
@testable import TempleUI

/// AppKit ships sidebar split-view items spring-loaded, which is how the
/// collapsed sidebar was opening by itself (a drag hovering its edge). The
/// disabler must find SwiftUI's split view controller through the delegate and
/// clear the flag — and report that it did, so a walk that misses the split
/// view cannot pass quietly.
@MainActor
final class SidebarSpringLoadingTests: XCTestCase {
    private struct Split: View {
        var withDisabler = false
        @State private var visibility: NavigationSplitViewVisibility = .detailOnly
        var body: some View {
            NavigationSplitView(columnVisibility: $visibility) {
                Text("sidebar").navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            } detail: {
                Text("detail")
            }
            .navigationSplitViewStyle(.balanced)
            // The production mount point (RootView): a background of the split view.
            .background(withDisabler ? SidebarSpringLoadingDisabler() : nil)
        }
    }

    private func hostSplitView(withDisabler: Bool = false) throws -> (NSWindow, NSSplitViewController) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Split(withDisabler: withDisabler))
        window.layoutIfNeeded()
        // SwiftUI builds the AppKit split view during layout; pump the run loop
        // until it exists, bounded so a slow machine fails with a message, not
        // a crash.
        let deadline = Date().addingTimeInterval(5)
        var controller: NSSplitViewController?
        while controller == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            controller = SidebarSpringLoadingDisabler.controlledSplitView(under: window.contentView!)?
                .delegate as? NSSplitViewController
        }
        return (window, try XCTUnwrap(controller, "NavigationSplitView should host an NSSplitViewController"))
    }

    func testSwiftUIsSidebarItemShipsSpringLoaded() throws {
        let (_, controller) = try hostSplitView()
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        // The premise of the fix. If AppKit ever stops doing this the disabler
        // is dead code, and this is the test that says so.
        XCTAssertTrue(sidebar.isSpringLoaded)
    }

    func testDisablerClearsTheFlagAndReportsIt() throws {
        let (window, controller) = try hostSplitView()
        let changed = SidebarSpringLoadingDisabler.disableSpringLoading(under: window.contentView!)
        XCTAssertEqual(changed, 1)
        for item in controller.splitViewItems {
            XCTAssertFalse(item.isSpringLoaded, "\(item.behavior) item still spring-loaded")
        }
        // Idempotent: a second pass finds nothing left to change.
        XCTAssertEqual(SidebarSpringLoadingDisabler.disableSpringLoading(under: window.contentView!), 0)
    }

    /// Through the representable as RootView mounts it — not the static
    /// function — so a broken makeNSView / viewDidMoveToWindow wiring fails here.
    func testMountedAsABackgroundItClearsTheFlagByItself() throws {
        let (_, controller) = try hostSplitView(withDisabler: true)
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        XCTAssertFalse(sidebar.isSpringLoaded)
    }

    func testDisablerReappliesWhenTheSplitViewResizes() throws {
        let (window, controller) = try hostSplitView()
        let disabler = SidebarSpringLoadingDisabler.DisablerView()
        window.contentView?.addSubview(disabler)   // viewDidMoveToWindow applies once
        let sidebar = try XCTUnwrap(controller.splitViewItems.first { $0.behavior == .sidebar })
        XCTAssertFalse(sidebar.isSpringLoaded)
        // A rebuilt or re-configured item comes back spring-loaded; the next
        // column resize must clear it again without anyone asking.
        sidebar.isSpringLoaded = true
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification,
                                        object: controller.splitView)
        XCTAssertFalse(sidebar.isSpringLoaded)
        // Cleanup must unregister, not merely go quiet: still attached (so
        // the window filter cannot be what swallows the notification), a
        // stopped view leaves the flag alone. Otherwise every remount would
        // stack a live observer.
        disabler.stopObserving()
        sidebar.isSpringLoaded = true
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification,
                                        object: controller.splitView)
        XCTAssertTrue(sidebar.isSpringLoaded)
    }
}
