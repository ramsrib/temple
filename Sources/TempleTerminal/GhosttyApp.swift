import AppKit
import Foundation
import OSLog
import GhosttyKit
import TempleTerminalAPI

/// One-per-process libghostty runtime.
///
/// Owns the global `ghostty_app_t` + its `ghostty_config_t`, pumps the tick loop
/// (driven by libghostty's `wakeup_cb`), and fans C callbacks (`action_cb`,
/// `close_surface_cb`) back out to the Swift `GhosttySurfaceView` that owns each
/// `ghostty_surface_t`.
///
/// Modeled on Ghostty's own `Ghostty.App` (macos/Sources/Ghostty, MIT) and the
/// cmux standalone embed (manaflow-ai/cmux, MIT); see docs/BUILDING-GHOSTTY.md.
///
/// libghostty is render-owning (ADR-003): a surface is handed a host `NSView`
/// and drives its own Metal render loop into it. The host only ticks and
/// forwards input; it never draws.
@MainActor
public final class GhosttyApp {
    static let logger = Logger(subsystem: "com.temple.terminal", category: "ghostty")

    /// The process-wide runtime. Created on first access; there is exactly one.
    public static let shared = GhosttyApp()

    /// Appearance used to seed the runtime's config on first access. The
    /// factory sets this before creating the first surface so the terminal is
    /// born matching the app theme (UX "Theme").
    public static var initialAppearance: TerminalAppearance = .default

    public enum Readiness {
        case loading, ready, error
    }

    public private(set) var readiness: Readiness = .loading

    /// The libghostty app handle. `nil` until ready / after shutdown.
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    /// Routes surface-targeted C callbacks back to the owning view.
    /// Keyed by the raw `ghostty_surface_t` pointer.
    private var surfaces: [OpaquePointer: Weak<GhosttySurfaceView>] = [:]

    private init() {
        // libghostty requires a one-time global init before any config/app.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            Self.logger.critical("ghostty_init failed")
            readiness = .error
            return
        }

        // Build a clean embedded configuration owned by Temple. We deliberately
        // skip the user's standalone Ghostty config (default/recursive files)
        // and CLI args — Temple's embedded terminal must match Temple's theme
        // (UX "Theme"), not the user's terminal emulator.
        guard let cfg = Self.makeConfig(appearance: Self.initialAppearance) else {
            Self.logger.critical("ghostty config creation failed")
            readiness = .error
            return
        }
        self.config = cfg

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyApp.onWakeup(ud) },
            action_cb: { app, target, action in GhosttyApp.onAction(app, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state in GhosttyApp.onReadClipboard(ud, location: loc, state: state) },
            confirm_read_clipboard_cb: { ud, str, state, req in GhosttyApp.onConfirmReadClipboard(ud, string: str, state: state, request: req) },
            write_clipboard_cb: { ud, loc, content, len, confirm in GhosttyApp.onWriteClipboard(ud, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { ud, processAlive in GhosttyApp.onCloseSurface(ud, processAlive: processAlive) }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            Self.logger.critical("ghostty_app_new failed")
            readiness = .error
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
        readiness = .ready
        Self.logger.info("libghostty runtime ready")
    }

    // MARK: Configuration (theme + font follow the app, U9/U10)

    /// Rebuild the config for a new appearance and push it to the runtime —
    /// all live surfaces re-derive their config (font size, theme pair).
    /// The light/dark palette itself is resolved per surface via
    /// `ghostty_surface_set_color_scheme`.
    public func update(appearance: TerminalAppearance) {
        guard let app, let cfg = Self.makeConfig(appearance: appearance) else { return }
        ghostty_app_update_config(app, cfg)
        ghostty_app_set_color_scheme(
            app,
            appearance.colorScheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    private static func makeConfig(appearance: TerminalAppearance) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        if let path = writeConfigFile(appearance: appearance) {
            path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        return cfg
    }

    /// libghostty only loads config from files, so persist Temple's generated
    /// config alongside its other app state.
    private static func writeConfigFile(appearance: TerminalAppearance) -> String? {
        var lines = [
            "# Generated by Temple — rewritten on every launch/theme change; do not edit.",
            // The RESOLVED theme is baked in (not a light:/dark: conditional
            // pair — libghostty's conditional resolution at surface creation
            // proved unreliable in the embed; a dark app got a light
            // terminal). Theme switches rebuild this config and push it via
            // ghostty_app_update_config.
            "theme = \(appearance.colorScheme == .dark ? "Adwaita Dark" : "Adwaita")",
            "font-size = \(Int(appearance.fontSize.rounded()))",
            "window-padding-x = 8",
            "window-padding-y = 6",
            // Temple owns process lifecycle (ADR-010); no ghostty-side prompts.
            "confirm-close-surface = false",
        ]
        if let family = appearance.fontFamily, !family.isEmpty {
            lines.append("font-family = \(family)")
        }
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Temple", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("ghostty.conf")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            logger.error("failed to write ghostty config: \(String(describing: error))")
            return nil
        }
    }

    /// Free the runtime. After this the app must not be used. Idempotent.
    public func shutdown() {
        surfaces.removeAll()
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
        readiness = .loading
    }

    // MARK: Tick loop

    /// Pump libghostty. Called on the main thread in response to `wakeup_cb`.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Surface registry

    func register(_ view: GhosttySurfaceView, for surface: ghostty_surface_t) {
        surfaces[OpaquePointer(surface)] = Weak(view)
    }

    func unregister(surface: ghostty_surface_t) {
        surfaces.removeValue(forKey: OpaquePointer(surface))
    }

    private func view(for surface: ghostty_surface_t?) -> GhosttySurfaceView? {
        guard let surface else { return nil }
        return surfaces[OpaquePointer(surface)]?.value
    }

    // MARK: C trampolines
    //
    // These are C function pointers and cannot capture context. libghostty
    // invokes `action_cb` / `close_surface_cb` synchronously from within
    // `ghostty_app_tick`, which we only ever call on the main thread, so it is
    // safe to assume main-actor isolation. `wakeup_cb` may fire from an IO
    // thread, so it only schedules a tick.

    private static func onWakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            GhosttyApp.shared.tick()
        }
    }

    private static func onAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        MainActor.assumeIsolated {
            GhosttyApp.shared.handle(target: target, action: action)
        }
    }

    private static func onCloseSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        // `userdata` is the per-surface userdata we set in the surface config:
        // an unretained pointer to the owning GhosttySurfaceView.
        guard let userdata else { return }
        MainActor.assumeIsolated {
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            view.handleCloseRequest(processAlive: processAlive)
        }
    }

    // Clipboard: minimal, functional implementations. Each callback receives the
    // per-surface userdata (an unretained pointer to the owning view).
    private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func onReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let surface = surfaceView(from: userdata)?.surface else { return false }
            guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else {
                return false
            }
            str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
    }

    private static func onConfirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // Auto-confirm the pending request with the provided string.
        MainActor.assumeIsolated {
            guard let surface = surfaceView(from: userdata)?.surface, let string else { return }
            ghostty_surface_complete_clipboard_request(surface, string, state, true)
        }
    }

    private static func onWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0, let data = content[0].data else { return }
        let value = String(cString: data)
        MainActor.assumeIsolated {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
        }
    }

    // MARK: Action dispatch

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            return handleSurface(target.target.surface, action: action)
        default:
            // App-level actions (new window/tab, quit, …) are the host UI's job;
            // Track T does not drive window management.
            return false
        }
    }

    private func handleSurface(_ surface: ghostty_surface_t?, action: ghostty_action_s) -> Bool {
        guard let view = view(for: surface) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let cstr = action.action.set_title.title {
                view.handleTitle(String(cString: cstr))
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            view.handleBell()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            view.handleNotification(title: title, body: body)
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            view.handleChildExited(code: Int32(bitPattern: action.action.child_exited.exit_code))
            return true

        default:
            return false
        }
    }
}

/// Weak wrapper for the surface registry.
final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
