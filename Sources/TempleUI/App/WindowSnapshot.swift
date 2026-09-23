import AppKit

/// Dev-only screenshots that need no Screen Recording grant.
///
/// `screencapture` is gated by TCC on the *terminal* hosting the shell — and a
/// shell inside Temple itself, or in a terminal never granted Screen Recording,
/// gets "could not create image" for every attempt (see AGENTS.md). This renders
/// the window from inside the process instead, which TCC does not police.
///
///     TEMPLE_SNAPSHOT_DIR=/some/dir dist/Temple.app/Contents/MacOS/Temple &
///     kill -USR1 <pid>          # → /some/dir/snapshot-<n>.png
///
/// Inert unless the env var is set. The result is a real pixel capture of the
/// window's screen rect: sidebar, terminal, floating panels and context menus
/// come out as the user sees them; other apps' windows are left out.
@MainActor
enum WindowSnapshot {
    private static var source: DispatchSourceSignal?
    private static var counter = 0

    /// `CGWindowListCreateImage` is deprecated in favour of ScreenCaptureKit —
    /// which needs the very grant this hook exists to do without. Resolved at
    /// run time so a dev-only file does not add a warning to every build.
    private typealias CreateImage = @convention(c)
        (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),   // RTLD_DEFAULT
                                 "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private static func captureWindow(_ number: CGWindowID) -> CGImage? {
        createImage?(.null, CGWindowListOption.optionIncludingWindow.rawValue, number,
                     CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?
            .takeRetainedValue()
    }

    static func installIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TEMPLE_SNAPSHOT_DIR"],
              !dir.isEmpty else { return }
        let directory = URL(fileURLWithPath: dir)

        // TEMPLE_SNAPSHOT_APPEARANCE=dark|light is honoured by
        // `AppModel.effectiveTheme`, not here: setting `NSApp.appearance`
        // directly was undone by the next `applyAppearance()` and contradicted
        // by RootView's `preferredColorScheme`, both of which read the theme.

        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { write(to: directory) }
        }
        source.resume()
        self.source = source

        // USR2 toggles the sidebar (⌘B) — the one gesture a frame-by-frame
        // check of the collapse needs and nothing outside the process can post
        // without global input injection (see the no-injection rule). Same
        // gate as the snapshots: inert unless TEMPLE_SNAPSHOT_DIR is set.
        signal(SIGUSR2, SIG_IGN)
        let toggle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        toggle.setEventHandler {
            NotificationCenter.default.post(name: .templeDebugToggleSidebar, object: nil)
        }
        toggle.resume()
        self.toggleSource = toggle

        // INFO folds/unfolds the first project in the rail, for the same
        // reason: the collapse animation is what needs watching.
        signal(SIGINFO, SIG_IGN)
        let fold = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
        fold.setEventHandler {
            NotificationCenter.default.post(name: .templeDebugToggleFirstProject, object: nil)
        }
        fold.resume()
        self.foldSource = fold
    }
    private static var toggleSource: DispatchSourceSignal?
    private static var foldSource: DispatchSourceSignal?

    /// The frontmost visible window's screen rectangle, chrome included (the
    /// titlebar and traffic lights are exactly what the sidebar-inset checks in
    /// AGENTS.md need to see), plus whatever of OURS is over it — context menus
    /// and floating panels are separate windows of this process, so they land in
    /// the shot too. Other apps' windows do not (that is what the gate protects).
    // The API is deprecated in favour of ScreenCaptureKit, which needs the very
    // grant this hook exists to do without.
    private static func write(to directory: URL) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let screen = NSScreen.screens.first else { return }
        // A real pixel capture of our OWN windows — the one case the Screen
        // Recording gate does not cover. Neither `cacheDisplay` nor rendering the
        // layer tree reaches the split view's sidebar (it lives under an
        // NSVisualEffectView whose vibrant subtree draws nothing offscreen), and
        // both leave the Metal terminal blank; this gets everything as shown.
        var rect = window.frame
        rect.origin.y = screen.frame.maxY - rect.maxY   // Cocoa → CG (top-left origin)
        // Only THIS process's windows. Capturing the rect with `.optionOnScreenOnly`
        // composites every on-screen window into it — which, on a machine where
        // Temple does hold the Screen Recording grant, would put another app's
        // pixels into a file this hook promises never to include. The array
        // variant of the API that would do the filtering is gone on current
        // macOS, so: capture each of our windows alone and composite them here,
        // back to front, at their on-screen offsets.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ours = ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                     as? [[String: Any]]) ?? [])
            .filter { (($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value) == pid }
        let scale = window.backingScaleFactor
        guard !ours.isEmpty,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = rect.size
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        for info in ours.reversed() {   // the list is front to back
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.intersects(rect),
                  let image = Self.captureWindow(number)
            else { continue }
            // kCGWindowBounds is top-left-origin screen space; the context draws
            // bottom-up, so flip within the canvas.
            let x = bounds.minX - rect.minX
            let y = rect.height - (bounds.minY - rect.minY) - bounds.height
            cg.draw(image, in: CGRect(x: x, y: y, width: bounds.width, height: bounds.height))
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        counter += 1
        let file = directory.appendingPathComponent(String(format: "snapshot-%02d.png", counter))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: file)
    }
}

import Combine

extension WindowSnapshot {
    /// True when the dev hooks are armed (TEMPLE_SNAPSHOT_DIR set).
    static let hooksEnabled: Bool = {
        !(ProcessInfo.processInfo.environment["TEMPLE_SNAPSHOT_DIR"] ?? "").isEmpty
    }()

    /// The publisher a view subscribes to for a dev hook: the real
    /// notification when hooks are armed (and `enabled`), an empty publisher
    /// otherwise — so production view trees carry no live subscriptions for
    /// signals nothing will post.
    static func debugPublisher(for name: Notification.Name, enabled: Bool = true) -> AnyPublisher<Notification, Never> {
        guard hooksEnabled, enabled else { return Empty().eraseToAnyPublisher() }
        return NotificationCenter.default.publisher(for: name).eraseToAnyPublisher()
    }
}

extension Notification.Name {
    /// Posted by the dev-only USR2 hook; RootView answers it with ⌘B's action.
    static let templeDebugToggleSidebar = Notification.Name("temple.debug.toggleSidebar")
    /// Posted by the dev-only INFO hook; the first project's disclosure toggles.
    static let templeDebugToggleFirstProject = Notification.Name("temple.debug.toggleFirstProject")
}
