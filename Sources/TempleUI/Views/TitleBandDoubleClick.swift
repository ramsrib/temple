import AppKit
import os

/// A view of ours that sits in (or over) the title band and keeps its own
/// clicks: a double-click on it is not a double-click on the title bar.
/// AppKit's controls, toolbar items and the split divider are recognised
/// without it (see `TitleBand.isEmpty`).
protocol TitleBandControl: NSView {}

/// The one owner of double-clicks on the title band: on any empty part of
/// it (over the sidebar or the detail pane, any tab, any window size or
/// sidebar width) a double-click performs the system "Double-click a
/// window's title bar to…" action exactly once.
///
/// AppKit's own handling can't be relied on here. It zooms only where the
/// window's *drag region* says it may (`-[NSWindow
/// _shouldZoomInDragRegionAtLocation:]`), and that region is a private
/// cache built lazily from the view tree. Measured in a real titled window
/// with the real split view (TitleBandDoubleClickTests): with no tab open
/// the region spans only the detail pane, from the divider to the right
/// edge, so a double-click over the sidebar did nothing at any sidebar
/// width or window size; with History freshly opened it covered the
/// sidebar instead, and a double-click over the detail pane then did
/// nothing. Which parts of the band worked depended on what had last been
/// laid out, which is how a resize or a sidebar drag "broke" it.
///
/// So the second click of a double-click on empty band never reaches
/// AppKit: an app-local mouse-down monitor (installed per window by the
/// tab strip's installer) acts and swallows it. The first click passes
/// through, so window drag is AppKit's as before; chips, buttons, the
/// traffic lights, toolbar items, the search field and the split divider
/// get both clicks untouched.
@MainActor
final class TitleBandDoubleClick {
    private static var installed: [ObjectIdentifier: TitleBandDoubleClick] = [:]

    private weak var window: NSWindow?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?
    private let diagnostics: Bool

    /// Idempotent per window.
    static func install(on window: NSWindow,
                        diagnostics: Bool = TitleBandDiagnostics.isEnabled) {
        let key = ObjectIdentifier(window)
        guard installed[key] == nil else { return }
        installed[key] = TitleBandDoubleClick(window: window, diagnostics: diagnostics)
    }

    static func isInstalled(on window: NSWindow) -> Bool {
        installed[ObjectIdentifier(window)] != nil
    }

    private init(window: NSWindow, diagnostics: Bool) {
        self.window = window
        self.diagnostics = diagnostics
        if diagnostics {
            TempleUILog.titlebar.notice("title band: double-click owner installed (TEMPLE_DEBUG_TITLEBAR)")
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Monitors run on the main thread, in the event's dispatch.
            nonisolated(unsafe) let incoming = event
            let swallow = MainActor.assumeIsolated { self?.swallows(incoming) ?? false }
            return swallow ? nil : event
        }
        let key = ObjectIdentifier(window)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TitleBandDoubleClick.uninstall(key) }
        }
    }

    private static func uninstall(_ key: ObjectIdentifier) {
        guard let owner = installed.removeValue(forKey: key) else { return }
        if let monitor = owner.monitor { NSEvent.removeMonitor(monitor) }
        if let closeObserver = owner.closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Whether this mouse-down is ours (acted on, and kept from AppKit).
    private func swallows(_ event: NSEvent) -> Bool {
        guard event.clickCount >= 2, let window, event.window === window else { return false }
        let point = event.locationInWindow
        guard TitleBand.contains(point, in: window) else { return false }
        let hit = TitleBand.hit(at: point, in: window)
        let report = diagnostics ? TitleBandDiagnostics.Report(window: window, point: point, hit: hit) : nil

        let owned = TitleBand.isEmpty(hit) && window.attachedSheet == nil
            && !window.styleMask.contains(.fullScreen)
        let outcome: String
        if !owned {
            outcome = "passed through (not empty band)"
        } else if event.clickCount == 2 {
            outcome = TitleBand.performSystemDoubleClickAction(on: window)
        } else {
            // A triple click is still the same gesture: AppKit must not
            // get a second go at it.
            outcome = "swallowed (click \(event.clickCount))"
        }
        report?.log(outcome: outcome)
        return owned
    }
}

/// Geometry and classification of the title band, shared by the owner and
/// its tests.
@MainActor
enum TitleBand {
    /// The band: the strip of the window above its content layout rect.
    static func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
        let frame = window.frame
        return point.y >= window.contentLayoutRect.maxY && point.y <= frame.height
            && point.x >= 0 && point.x <= frame.width
    }

    /// The view a click at `point` (window coordinates) is delivered to.
    static func hit(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let frameView = window.contentView?.superview else { return nil }
        return frameView.hitTest(frameView.convert(point, from: nil))
    }

    /// Whether a click that reaches `hit` is a click on empty title bar.
    /// Anything that handles clicks of its own is not: an AppKit control
    /// (the traffic lights are buttons), text, a toolbar item, one of our
    /// band controls, or the split view itself (its divider runs up through
    /// the band, and a double-click there resets the sidebar width). What
    /// is left must be something AppKit would move the window from.
    static func isEmpty(_ hit: NSView?) -> Bool {
        guard let hit, !(hit is NSSplitView), hit.mouseDownCanMoveWindow else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSControl || current is NSText || current is TitleBandControl
                || current.className.contains("ToolbarItemViewer") {
                return false
            }
            view = current.superview
        }
        return true
    }

    /// System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar
    /// to…", read live. Unset is zoom, as AppKit does (measured: it calls
    /// `performZoom:`); the pre-Ventura `AppleMiniaturizeOnDoubleClick` still
    /// counts when the newer key is absent. Returns what it did, for the
    /// diagnostic log.
    @discardableResult
    static func performSystemDoubleClickAction(on window: NSWindow,
                                               defaults: UserDefaults = .standard) -> String {
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize":
            window.performMiniaturize(nil)
            return "minimize"
        case "None":
            return "none (system setting)"
        case "Fill":
            // The Window menu's Fill. No public API performs it; without it,
            // zoom is the nearest thing the setting could mean.
            let fill = Selector(("_zoomFill:"))
            if window.responds(to: fill) {
                window.perform(fill, with: nil)
                return "fill"
            }
            window.performZoom(nil)
            return "zoom (fill unavailable)"
        default:
            window.performZoom(nil)
            return "zoom"
        }
    }
}

/// Dev-only: `TEMPLE_DEBUG_TITLEBAR=1` logs every double-click on the title
/// band at notice (`com.sriramb.temple.app`, category `titlebar`): what it
/// hit, where, the window's state, the sidebar width, and what was done.
/// Inert otherwise. Read with
/// `log stream --level info --predicate 'subsystem == "com.sriramb.temple.app" && category == "titlebar"'`.
@MainActor
enum TitleBandDiagnostics {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TEMPLE_DEBUG_TITLEBAR"] == "1"
    }

    @MainActor
    struct Report {
        let chain: String
        let point: NSPoint
        let windowFrame: NSRect
        let zoomed: Bool
        let sidebarWidth: String
        let appKitWouldZoom: String

        init(window: NSWindow, point: NSPoint, hit: NSView?) {
            chain = TitleBandDiagnostics.chain(from: hit)
            self.point = point
            windowFrame = window.frame
            zoomed = window.isZoomed
            sidebarWidth = TitleBandDiagnostics.sidebarWidth(in: window)
            appKitWouldZoom = TitleBandDiagnostics.appKitWouldZoom(window, at: point)
        }

        func log(outcome: String) {
            TempleUILog.titlebar.notice("""
                title band double-click at \(NSStringFromPoint(point), privacy: .public) \
                window \(NSStringFromRect(windowFrame), privacy: .public) zoomed=\(zoomed, privacy: .public) \
                sidebar=\(sidebarWidth, privacy: .public) appKitDragRegionZoom=\(appKitWouldZoom, privacy: .public) \
                hit=\(chain, privacy: .public) -> \(outcome, privacy: .public)
                """)
        }
    }

    /// The hit view and its ancestors, innermost first, SwiftUI's generic
    /// names shortened to their outer type.
    static func chain(from hit: NSView?) -> String {
        guard let hit else { return "nil" }
        var names: [String] = []
        var view: NSView? = hit
        while let current = view, names.count < 8 {
            var name = current.className
            if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
            if name.count > 60 { name = String(name.prefix(60)) + "…" }
            names.append(name)
            view = current.superview
        }
        return names.joined(separator: " < ")
    }

    static func sidebarWidth(in window: NSWindow) -> String {
        guard let split = window.contentView.flatMap(firstSplitView(in:)),
              let sidebar = split.arrangedSubviews.first else { return "?" }
        return split.isSubviewCollapsed(sidebar) ? "collapsed" : String(format: "%.0f", sidebar.frame.width)
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let split = next as? NSSplitView, split.arrangedSubviews.count >= 2 { return split }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }

    /// What AppKit's own gate says about this point, for comparison: its
    /// title-bar double-click only zooms where this is true. Private, and
    /// read only here, behind the debug switch.
    static func appKitWouldZoom(_ window: NSWindow, at point: NSPoint) -> String {
        typealias Gate = @convention(c) (AnyObject, Selector, NSPoint) -> Bool
        let selector = Selector(("_shouldZoomInDragRegionAtLocation:"))
        guard window.responds(to: selector),
              let imp = class_getMethodImplementation(type(of: window), selector) else { return "?" }
        return unsafeBitCast(imp, to: Gate.self)(window, selector, point) ? "yes" : "no"
    }
}
