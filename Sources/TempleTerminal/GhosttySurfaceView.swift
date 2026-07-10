import AppKit
import Foundation
import GhosttyKit
import TempleTerminalAPI

/// A host `NSView` for a single libghostty surface.
///
/// libghostty is render-owning (ADR-003): we hand it this `NSView` and it drives
/// its own Metal render loop into the view's layer. This class does **not** draw;
/// it plumbs keyboard, mouse, resize, focus, and scrollback into the surface and
/// fans surface events (title/bell/notification/child-exit/close) back out via
/// closures the `GhosttyTerminalSurface` wires to the public delegate.
///
/// Modeled on Ghostty's `SurfaceView_AppKit` (MIT) and cmux (MIT).
@MainActor
public final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    /// The libghostty surface handle. `nil` until `startSurface` succeeds.
    public private(set) var surface: ghostty_surface_t?

    // Event fan-out — set by the owning GhosttyTerminalSurface.
    var onTitle: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onNotification: ((String, String) -> Void)?
    /// Reports the child exit code (once).
    var onChildExited: ((Int32) -> Void)?
    /// libghostty asks the host to close the surface (e.g. process gone).
    var onCloseRequest: ((_ processAlive: Bool) -> Void)?

    private weak var app: GhosttyApp?
    private var terminalAppearance: TerminalAppearance
    private var contentSize: CGSize = .zero
    private var childHasExited = false

    // IME state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?

    public init(app: GhosttyApp, appearance: TerminalAppearance) {
        self.app = app
        self.terminalAppearance = appearance
        super.init(frame: .zero)
        // ghostty attaches its Metal layer to this view.
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: Surface lifecycle

    /// Create the libghostty surface + spawn the process.
    ///
    /// ADR-003 validation, expressed as production preconditions: libghostty must
    /// hand back a drivable native surface for the `NSView` we provide. If it
    /// cannot, we fail loudly rather than silently degrade.
    func startSurface(command: String?, workingDirectory: String?, env: [String: String]) throws {
        precondition(surface == nil, "startSurface called twice")
        guard let app = app?.app else {
            throw GhosttyError.runtimeNotReady
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        // Per-surface userdata: unretained pointer to self, used by libghostty's
        // clipboard + close-surface callbacks to find this view.
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = Float(terminalAppearance.fontSize)

        var envVars: [ghostty_env_var_s] = []
        var envStorage: [UnsafeMutablePointer<CChar>] = []
        defer { for p in envStorage { free(p) } }
        for (k, v) in env {
            guard let kp = strdup(k), let vp = strdup(v) else { continue }
            envStorage.append(kp); envStorage.append(vp)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(kp), value: UnsafePointer(vp)))
        }

        let created: ghostty_surface_t? = withOptionalCString(command) { cCommand in
            cfg.command = cCommand
            return withOptionalCString(workingDirectory) { cwd in
                cfg.working_directory = cwd
                if envVars.isEmpty {
                    return ghostty_surface_new(app, &cfg)
                }
                return envVars.withUnsafeMutableBufferPointer { buf in
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }

        // ADR-003 gate: a null surface means libghostty could not give us a
        // drivable native surface — the whole architecture rests on this.
        guard let created else {
            GhosttyApp.logger.critical("ghostty_surface_new returned nil — ADR-003 violated")
            throw GhosttyError.surfaceCreationFailed
        }
        self.surface = created
        self.app?.register(self, for: created)

        // Prime size + scale from the current geometry, and resolve the
        // config's light:/dark: theme pair for the current app appearance.
        contentSize = bounds.size
        if bounds.size != .zero { pushSize(bounds.size) }
        pushContentScale()
        apply(terminalAppearance)
        GhosttyApp.logger.info("ghostty surface created and process spawned")
    }

    func closeSurface() {
        guard let surface else { return }
        app?.unregister(surface: surface)
        ghostty_surface_free(surface)
        self.surface = nil
    }

    deinit {
        // deinit is nonisolated; free directly (registry holds a weak ref).
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: Appearance

    func apply(_ appearance: TerminalAppearance) {
        self.terminalAppearance = appearance
        guard let surface else { return }
        ghostty_surface_set_color_scheme(
            surface,
            appearance.colorScheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        contentSize = newSize
        pushSize(newSize)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        pushContentScale()
        pushSize(contentSize)
    }

    private func pushSize(_ size: CGSize) {
        guard let surface, size.width > 0, size.height > 0 else { return }
        let scaled = convertToBacking(CGRect(origin: .zero, size: size)).size
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    private func pushContentScale() {
        guard let surface else { return }
        let fb = convertToBacking(CGRect(origin: .zero, size: CGSize(width: 1, height: 1))).size
        ghostty_surface_set_content_scale(surface, Double(fb.width), Double(fb.height))
    }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: Event callbacks (from GhosttyApp action dispatch)

    func handleTitle(_ title: String) { onTitle?(title) }
    func handleBell() { onBell?() }
    func handleNotification(title: String, body: String) { onNotification?(title, body) }

    func handleChildExited(code: Int32) {
        guard !childHasExited else { return }
        childHasExited = true
        onChildExited?(code)
    }

    func handleCloseRequest(processAlive: Bool) {
        onCloseRequest?(processAlive)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { super.keyDown(with: event); return }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Route through the input system so IME / dead keys produce composed text
        // (delivered to insertText / setMarkedText).
        interpretKeyEvents([event])

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                sendKey(surface, event: event, action: action, text: text, composing: false)
            }
        } else {
            sendKey(
                surface, event: event, action: action,
                text: event.ghosttyCharacters,
                composing: markedText.length > 0 || markedBefore)
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        sendKey(surface, event: event, action: GHOSTTY_ACTION_RELEASE, text: nil, composing: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // Modifier press/release: derive action from whether the flag is now set.
        let mod: UInt
        switch event.keyCode {
        case 0x38, 0x3C: mod = NSEvent.ModifierFlags.shift.rawValue
        case 0x3B, 0x3E: mod = NSEvent.ModifierFlags.control.rawValue
        case 0x3A, 0x3D: mod = NSEvent.ModifierFlags.option.rawValue
        case 0x37, 0x36: mod = NSEvent.ModifierFlags.command.rawValue
        default: mod = 0
        }
        let action: ghostty_input_action_e =
            (event.modifierFlags.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKey(surface, event: event, action: action, text: nil, composing: false)
    }

    private func sendKey(
        _ surface: ghostty_surface_t,
        event: NSEvent,
        action: ghostty_input_action_e,
        text: String?,
        composing: Bool
    ) {
        var key = event.ghosttyKeyEvent(action)
        key.composing = composing
        if let text, !text.isEmpty {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }
    public override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }
    public override func rightMouseDown(with event: NSEvent) {
        guard let surface else { super.rightMouseDown(with: event); return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
    }
    public override func rightMouseUp(with event: NSEvent) {
        guard let surface else { super.rightMouseUp(with: event); return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
    }
    public override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }
    public override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }
    public override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
    public override func mouseDragged(with event: NSEvent) { reportMousePos(event) }
    public override func rightMouseDragged(with event: NSEvent) { reportMousePos(event) }
    public override func otherMouseDragged(with event: NSEvent) { reportMousePos(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            x *= 2; y *= 2
            scrollMods = 1 // bit 0 = precision
        }
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    private func reportMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // ghostty origin is top-left; AppKit is bottom-left.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods(event))
    }

    private func updateTracking() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        NSEvent.ghosttyMods(event.modifierFlags)
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
        }
        // Committed text: clear preedit + accumulate for the keyDown to send.
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            ghostty_surface_text(surface, text, UInt(text.utf8.count))
        }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as String: markedText = NSMutableAttributedString(string: s)
        case let s as NSAttributedString: markedText = NSMutableAttributedString(attributedString: s)
        default: markedText = NSMutableAttributedString()
        }
        guard let surface else { return }
        let s = markedText.string
        ghostty_surface_preedit(surface, s, UInt(s.utf8.count))
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }
    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let viewRect = convert(bounds, to: nil)
        return window.convertToScreen(viewRect)
    }
    public override func doCommand(by selector: Selector) {
        // Let the terminal encode these; do not perform AppKit editing selectors.
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value else { return body(nil) }
    return value.withCString(body)
}

public enum GhosttyError: Error {
    case runtimeNotReady
    case surfaceCreationFailed
}
