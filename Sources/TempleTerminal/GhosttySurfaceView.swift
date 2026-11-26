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
    /// The user pressed Return (no modifiers) — a submit signal (Item E).
    var onSubmitInput: (() -> Void)?
    /// Any input toward the terminal (every key press, committed or
    /// dropped text). Reported even before a surface exists: over-reporting
    /// only costs an early close its shortcut.
    var onInput: (() -> Void)?
    /// Files from this Mac to hand to the program (a drop, a ⌘V of a file
    /// or an image): the paths to type, or nil to type nothing. Unset, their
    /// paths here.
    var onFiles: (@MainActor ([URL]) async -> [String]?)?
    /// Reports the child exit code (once).
    var onChildExited: ((Int32) -> Void)?
    /// libghostty asks the host to close the surface (e.g. process gone).
    var onCloseRequest: ((_ processAlive: Bool) -> Void)?
    // Search (see TerminalSurface.search): libghostty reporting back.
    var onSearchStarted: ((_ needle: String?) -> Void)?
    var onSearchEnded: (() -> Void)?
    var onSearchTotal: ((Int?) -> Void)?
    var onSearchSelected: ((Int?) -> Void)?

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
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: Surface lifecycle

    /// Create the libghostty surface + spawn the process.
    ///
    /// ADR-003 validation, expressed as production preconditions: libghostty must
    /// hand back a drivable native surface for the `NSView` we provide. If it
    /// cannot, we fail loudly rather than silently degrade.
    ///
    /// Creation goes through `GhosttyApp.spawn`: immediate normally, deferred
    /// to the end of the drain when asked from inside one (a tab closed by a
    /// child-exited callback spawns its neighbour from that stack). A
    /// `ghostty_surface_new` that returns nil is thrown when creation ran
    /// now; deferred, there is no caller left to throw to, so it is reported
    /// the way any dead child is — through `onChildExited` — and the tab shows
    /// its launch-failure header.
    func startSurface(command: String?, workingDirectory: String?, env: [String: String]) throws {
        precondition(surface == nil && spawnToken == nil, "startSurface called twice")
        guard let app, app.app != nil else {
            throw GhosttyError.runtimeNotReady
        }
        let token = UUID()
        spawnToken = token
        // libghostty starts the terminal's pwd at the child's working
        // directory (termio Exec), as this view must know it to read titles.
        terminalPwd = workingDirectory
        var failedNow = false
        app.spawn { [weak self] deferred in
            guard let self, self.spawnToken == token else { return }   // closed meanwhile
            self.spawnToken = nil
            if self.createSurface(command: command, workingDirectory: workingDirectory, env: env) { return }
            if deferred { self.handleChildExited(code: -1) } else { failedNow = true }
        }
        if failedNow { throw GhosttyError.surfaceCreationFailed }
    }

    /// Set while a creation is queued in the runtime; cleared when it runs or
    /// when `closeSurface` cancels it.
    private var spawnToken: UUID?

    /// Returns whether libghostty handed back a surface.
    private func createSurface(command: String?, workingDirectory: String?, env: [String: String]) -> Bool {
        guard let runtime = self.app, let app = runtime.app else {
            GhosttyApp.logger.critical("runtime went away before the surface was created")
            return false
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        // Per-surface userdata: unretained pointer to self, used by libghostty's
        // clipboard + close-surface callbacks to find this view. `closeSurface`
        // keeps self alive until the surface is actually freed for that reason.
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
                    return runtime.newSurface(app, cfg)
                }
                return envVars.withUnsafeMutableBufferPointer { buf in
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return runtime.newSurface(app, cfg)
                }
            }
        }

        // ADR-003 gate: a null surface means libghostty could not give us a
        // drivable native surface — the whole architecture rests on this.
        guard let created else {
            GhosttyApp.logger.critical("ghostty_surface_new returned nil — ADR-003 violated")
            return false
        }
        self.surface = created
        runtime.register(self, for: created)

        // Prime size + scale from the current geometry, and resolve the
        // config's light:/dark: theme pair for the current app appearance.
        contentSize = bounds.size
        if bounds.size != .zero { pushSize(bounds.size, evenIfUnchanged: true) }
        pushContentScale()
        apply(terminalAppearance)
        syncRendererState()
        GhosttyApp.logger.info("ghostty surface created and process spawned")
        return true
    }

    /// The normal teardown: the tab is gone, free the surface. The runtime
    /// decides WHEN (see `GhosttyApp.release`) — freeing inside one of its own
    /// callbacks, then spawning, is how a freed surface's queued title landed
    /// on the next surface allocated at the same address.
    func closeSurface() {
        spawnToken = nil   // a creation still queued in the runtime is cancelled
        guard let surface else { return }
        self.surface = nil
        pushedVisible = nil
        pushedFocused = nil
        // Detach libghostty's layer before the renderer behind it goes. The
        // layer's display callback holds a raw pointer to that renderer, and
        // SwiftUI can keep this view — and so the layer — in the tree for a
        // render pass after the tab is gone; a display in that gap would call
        // into freed memory. Out of the tree, nothing displays it.
        layer = CALayer()
        guard let app else {
            ghostty_surface_free(surface)
            return
        }
        app.unregister(surface: surface)
        app.release(surface, keeping: self)
    }

    deinit {
        // Fallback only: tabs release through closeSurface(). deinit is
        // nonisolated, so it cannot ask the runtime to drain — a surface that
        // reaches here still carries the address-reuse race.
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
        if !holdsSize { pushSize(newSize) }
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
        if !holdsSize { pushSize(contentSize) }
    }

    // MARK: Animated resizes

    /// Whether the live resize under way is one AppKit animates by itself
    /// (a zoom, Fill, tiling, a double-clicked edge): nil outside a live
    /// resize, false for one that follows the pointer.
    ///
    /// A zoom is a live resize too (measured: `inLiveResize` is true for all
    /// 21 sizes of a 350 ms `performZoom`). Passing each size on reflows the
    /// grid every frame, and libghostty resizes the pty at most every 25 ms,
    /// so the program gets about ten SIGWINCHes. Claude Code and Codex
    /// clear and redraw their screens on each, and the zoom reads as the
    /// text being rewritten under the animation. Held, the surface keeps
    /// its grid (libghostty's layer is top-left gravity, so the frame stays
    /// put and crisp) and takes the final size once, when the window lands.
    /// An edge drag still reflows live: the terminal follows the pointer.
    private var animatedResize: Bool?

    /// The window is animating its frame and this view is holding its grid.
    /// Gated on `inLiveResize`, the window's own truth, so a verdict left
    /// behind by a resize whose end this view never heard holds nothing.
    private var holdsSize: Bool {
        guard inLiveResize else { return false }
        // A view that joined the window mid-resize never heard it start.
        if animatedResize == nil { beginLiveResize() }
        return animatedResize == true
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        beginLiveResize()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endLiveResize()
    }

    /// The size held through an animation goes to libghostty once, a turn
    /// later: SwiftUI lays the view out once more after the live resize
    /// ends (measured: 1799 pt wide at the end, 1800 from that layout), and
    /// a size it has already pushed by then is not pushed again. A scale
    /// change during the hold changes the pixels, so the size still goes.
    private func endLiveResize() {
        guard animatedResize == true else { animatedResize = nil; return }
        animatedResize = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.holdsSize else { return }
            self.pushSize(self.contentSize)
        }
    }

    private func beginLiveResize() {
        animatedResize = !Self.pointerDrivesResize(NSApp.currentEvent)
    }

    /// Whether a live resize starting during `event` follows the pointer: the
    /// left button is down, from a single click (an edge drag). A double
    /// click is a zoom (the title bar) or an edge expanding to the screen,
    /// and a menu item, a key or the window buttons act with no button held.
    nonisolated static func pointerDrivesResize(_ event: NSEvent?, pressedButtons: Int = NSEvent.pressedMouseButtons) -> Bool {
        guard pressedButtons & 1 != 0, let event else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged: return event.clickCount < 2
        default: return false
        }
    }

    /// Every size handed to libghostty, in points, for tests: whether a
    /// view has a surface or not, this is what it would have been told.
    var onSizePushed: ((CGSize) -> Void)?

    /// The last size handed to libghostty, in backing pixels: what it
    /// stores, so a scale change at the same size in points still counts as
    /// a change (libghostty's content-scale callback keeps its old pixels).
    private var pushedPixels: CGSize?

    /// A size already pushed is not pushed again (a layout often repeats one:
    /// SwiftUI sets the landed size of a zoom three times); starting a surface
    /// primes it regardless, since sizes recorded before it existed went nowhere.
    private func pushSize(_ size: CGSize, evenIfUnchanged: Bool = false) {
        let scaled = convertToBacking(CGRect(origin: .zero, size: size)).size
        guard evenIfUnchanged || scaled != pushedPixels else { return }
        pushedPixels = scaled
        onSizePushed?(size)
        guard let surface, size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    private func pushContentScale() {
        guard let surface else { return }
        let fb = convertToBacking(CGRect(origin: .zero, size: CGSize(width: 1, height: 1))).size
        ghostty_surface_set_content_scale(surface, Double(fb.width), Double(fb.height))
    }

    // MARK: Visibility

    /// What libghostty was last told; `nil` until a surface has been told anything.
    private var pushedVisible: Bool?
    private var pushedFocused: Bool?
    /// Whether this view holds the keyboard, as AppKit last told us.
    private var isResponder = false
    private var occlusionObserver: NSObjectProtocol?

    /// Tell the renderer whether anyone can see this surface, and whether it
    /// has focus.
    ///
    /// Only the active tab's view is in the window, but every tab's surface keeps
    /// a renderer thread, and libghostty assumes a new surface is visible *and*
    /// focused, so its display link runs at the screen's refresh rate. A tab
    /// that never took the keyboard never says otherwise. Hidden, the renderer
    /// stops drawing and stops the display link, and draws at once when shown.
    ///
    /// Focus goes through here too, because v1.3.1 restarts the display link on
    /// focus without checking visibility: a tab that takes the keyboard while
    /// its window is covered would tick again. So libghostty hears "focused"
    /// only while the view is both first responder and visible.
    ///
    /// Stock v1.3.1 still rebuilds a hidden surface's frame (shaping, link
    /// matching) on every output; `Patches/ghostty/0001` (upstream `14d9e600ac`,
    /// ADR-026) skips that too, and it keys off exactly this call. With 21
    /// surfaces redrawing 4×/s, 1 visible: ~39% of a core stock, ~5% patched.
    ///
    /// Visible = in a window, and that window is at least partly on screen
    /// (not minimized, ⌘H-hidden, or fully covered).
    private func syncRendererState() {
        guard let surface else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        let focused = isResponder && visible
        if visible != pushedVisible {
            pushedVisible = visible
            ghostty_surface_set_occlusion(surface, visible)
        }
        if focused != pushedFocused {
            pushedFocused = focused
            ghostty_surface_set_focus(surface, focused)
        }
    }

    // MARK: Focus

    /// Never while a floating panel holds the keyboard (OverlayKeyboard):
    /// a click queued before the panel's backdrop mounted, or the window
    /// becoming key again, must not hand the terminal the keys meant for it.
    public override var acceptsFirstResponder: Bool { !OverlayKeyboard.isHeld }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A focus request that has not been honoured yet, as the ticket it was
    /// made with (`OverlayKeyboard`): nil when there is none.
    private var focusTicket: OverlayKeyboard.Ticket?
    private var wantsFocus: Bool { focusTicket != nil }

    /// Take the keyboard, once it is actually possible to.
    ///
    /// Two races make the obvious `makeFirstResponder` fail, and both bite when
    /// you open a session and start typing:
    ///   1. The view may not be in a window yet — a lazily spawned surface mounts
    ///      on the next SwiftUI render, i.e. after the click that opened it.
    ///   2. AppKit finishes the click AFTER us, so the sidebar row or the project
    ///      popover that was clicked takes the responder straight back.
    /// So the claim is deferred a runloop turn, and re-tried when the view lands
    /// in a window.
    ///
    /// While a floating panel holds the keyboard the request is refused, and
    /// a request made before a panel opened or closed is void after it: the
    /// panel's dismissal decides where focus goes (OverlayKeyboard).
    func requestFocus() {
        guard let ticket = OverlayKeyboard.ticket(retry: { [weak self] in self?.requestFocus() }) else { return }
        focusTicket = ticket
        DispatchQueue.main.async { [weak self] in self?.claimFocusIfWanted() }
    }

    private func claimFocusIfWanted() {
        guard let ticket = focusTicket, let window else { return }
        focusTicket = nil
        guard OverlayKeyboard.mayClaim(ticket, in: window, by: self) else { return }
        window.makeFirstResponder(self)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Out of its window a view can't hold the keyboard, and AppKit doesn't
        // always say so (removing the first responder skips resign).
        if newWindow !== window {
            isResponder = false
            // A resize this view leaves mid-animation never tells it the end.
            endLiveResize()
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let newWindow else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncRendererState() }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncRendererState()
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in self?.claimFocusIfWanted() }
    }

    public override func becomeFirstResponder() -> Bool {
        guard !OverlayKeyboard.isHeld else {
            OverlayKeyboard.admissionRefused()
            return false
        }
        let ok = super.becomeFirstResponder()
        isResponder = true
        syncRendererState()
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        isResponder = false
        syncRendererState()
        return ok
    }

    // MARK: Event callbacks (from GhosttyApp action dispatch)

    /// The terminal's working directory as libghostty holds it: the child's
    /// launch directory, then whatever OSC 7 reported.
    var terminalPwd: String?

    func handlePwd(_ pwd: String) { terminalPwd = pwd.isEmpty ? nil : pwd }

    /// libghostty's stand-in titles: when the program sets an empty title
    /// (it resets its own; tmux sends one while the pane is untitled), or
    /// reports a pwd before any title, libghostty titles the terminal with
    /// its pwd, byte for byte. That is this Mac's launch directory (for a
    /// tab on a host, the home its ssh runs in), never anything the program
    /// said: it is reported apart (`onStandInTitle`), as a title change for
    /// activity but not one to show.
    var onStandInTitle: ((String) -> Void)?

    func handleTitle(_ title: String) {
        if Self.isStandIn(title, pwd: terminalPwd) { onStandInTitle?(title) } else { onTitle?(title) }
    }

    /// Exactly the pwd's bytes, as libghostty copies them: no trimming, no
    /// canonical equivalence (a title spelled another way is the program's).
    static func isStandIn(_ title: String, pwd: String?) -> Bool {
        guard let pwd, !pwd.isEmpty else { return false }
        return title.utf8.elementsEqual(pwd.utf8)
    }
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

    func handleSearchStarted(needle: String?) { onSearchStarted?(needle) }
    func handleSearchEnded() { onSearchEnded?() }
    func handleSearchTotal(_ total: Int?) { onSearchTotal?(total) }
    func handleSearchSelected(_ selected: Int?) { onSearchSelected?(selected) }

    // MARK: Binding actions

    /// Run a keybind action by name (`search:foo`, `navigate_search:next`,
    /// `end_search`, …) — the same strings a user could put in a Ghostty
    /// config, and how Ghostty's own macOS app drives search.
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        let ok = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        // "Performable" actions report false when there was nothing to do
        // (end_search with no search) — routine, so not a warning.
        if !ok {
            GhosttyApp.logger.debug("binding action not performed: \(action, privacy: .public)")
        }
        return ok
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        onInput?()
        guard let surface else { super.keyDown(with: event); return }

        // Item E: a plain Return (keyCode 36, no modifiers) is a submit — the
        // agent is about to work. Signal it, then fall through to normal input
        // encoding so the keystroke still reaches the PTY.
        if event.keyCode == 36,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            onSubmitInput?()
        }

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // libghostty decides which modifiers shape the text: under
        // `macos-option-as-alt` the left ⌥ is the terminal's Alt, so ⌥P must
        // compose "p" (sent as Alt-p, which the agents bind), never "π".
        // Without this step the config line does nothing.
        let translationMods = NSEvent.modifierFlags(
            ghostty_surface_key_translation_mods(surface, NSEvent.ghosttyMods(event.modifierFlags)))
        let translationEvent = event.ghosttyTranslationEvent(mods: translationMods)

        // Route through the input system so IME / dead keys produce composed text
        // (delivered to insertText / setMarkedText).
        interpretKeyEvents([translationEvent])

        // A key that ends a composition (a dead key, an IME's preedit) commits
        // text that is not the key's own: send the text bare, no key and no
        // modifiers, or a right-⌥ dead key finished with the left ⌥ arrives
        // as Alt-E instead of "é". Only arrows still act after the commit.
        // Ported from upstream's `committedTextAction`.
        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list { sendCommittedText(surface, action: action, text: text) }
            if Self.replaysAfterCommit(translationEvent) {
                sendKey(surface, event: event, action: action, text: nil, composing: false,
                        translationMods: translationEvent.modifierFlags)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                sendKey(surface, event: event, action: action, text: text, composing: false,
                        translationMods: translationEvent.modifierFlags)
            }
        } else {
            sendKey(
                surface, event: event, action: action,
                text: translationEvent.ghosttyCharacters,
                composing: markedText.length > 0 || markedBefore,
                translationMods: translationEvent.modifierFlags)
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
        composing: Bool,
        translationMods: NSEvent.ModifierFlags? = nil
    ) {
        var key = event.ghosttyKeyEvent(action, translationMods: translationMods)
        key.composing = composing
        dispatchingKey = true
        defer { dispatchingKey = false }
        if let text = NSEvent.ghosttyKeyText(text) {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// Committed composition text, alone: libghostty sends it as typed text.
    private func sendCommittedText(_ surface: ghostty_surface_t, action: ghostty_input_action_e, text: String) {
        guard let text = NSEvent.ghosttyKeyText(text) else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = 0
        key.composing = false
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = 0
        text.withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// After a commit only arrows still move the terminal's cursor; a plain
    /// ← is left alone, since AppKit already leaves the caret in place after
    /// a Korean IME commits (upstream's `shouldReplayCommittedPreeditKey`).
    static func replaysAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125, 124, 126: return true                                   // ↓ → ↑
        case 123: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])  // ←
        default: return false
        }
    }

    // MARK: Clipboard

    /// Every paste ends here: libghostty asks for the clipboard (⌘V's
    /// `paste_from_clipboard`, a middle-click, `paste_from_selection`, a
    /// confirmed unsafe paste, an OSC 52 read) and this hands it over, so
    /// this is the one place a paste is reported as input, whatever gesture
    /// started it and whether or not the mouse is captured. (An OSC 52 read
    /// is the program's own request; reporting it too only costs an early
    /// close its shortcut.)
    func deliverClipboard(_ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        onInput?()
        guard let surface else { return }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, confirmed) }
    }

    // MARK: Mouse

    /// Whether the program in the terminal has mouse reporting on, so a
    /// click, release, drag or scroll reaches its pty rather than Temple
    /// (libghostty's capture state). A test can stand in for the surface.
    lazy var mouseReachesProgram: () -> Bool = { [weak self] in
        guard let surface = self?.surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// Mouse input that reaches the pty is input (a click can answer a
    /// TUI's prompt); a focus click, a selection or a scroll Temple handles
    /// itself for scrollback is not. Under tmux (`mouse on`) every click
    /// reaches the pty. Asked before the event is handed over.
    private func reportMouseInput() {
        if mouseReachesProgram() { onInput?() }
    }

    public override func mouseDown(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }
    public override func mouseUp(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }
    public override func rightMouseDown(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { super.rightMouseDown(with: event); return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
    }
    public override func rightMouseUp(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { super.rightMouseUp(with: event); return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
    }
    public override func otherMouseDown(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }
    public override func otherMouseUp(with event: NSEvent) {
        reportMouseInput()
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }
    public override func mouseMoved(with event: NSEvent) { reportMousePos(event) }
    public override func mouseDragged(with event: NSEvent) { reportMouseInput(); reportMousePos(event) }
    public override func rightMouseDragged(with event: NSEvent) { reportMouseInput(); reportMousePos(event) }
    public override func otherMouseDragged(with event: NSEvent) { reportMouseInput(); reportMousePos(event) }

    public override func scrollWheel(with event: NSEvent) {
        reportMouseInput()
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

    // MARK: Drag & drop

    /// Dropping a file or an image onto an agent types its path into the prompt —
    /// that is how you hand Claude or Codex a screenshot or a log to look at.
    /// (Ported from Ghostty's SurfaceView, extended to cover images that arrive
    /// as pixels rather than as a file.) Files go through `onFiles` first: a
    /// tab on another machine copies them there and types that machine's paths.
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string, .png, .tiff]

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy   // .copy gets the right cursor + badge
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        switch Self.droppedContent(from: sender.draggingPasteboard) {
        case .files(let files):
            handOff(files)
        case .text(let text):
            // After any handoff still copying: drops land in the order made.
            enqueue { _ in text }
        case nil:
            return false
        }
        return true
    }

    /// What a drop hands the terminal.
    enum Dropped: Equatable {
        /// Files on this Mac (and any web links dropped with them, typed as
        /// they are): their paths are typed, shell-quoted.
        case files([URL])
        /// Typed as it is.
        case text(String)
    }

    static func droppedContent(from pasteboard: NSPasteboard) -> Dropped? {
        // Files first — an agent reads a path, so a dropped file IS its path.
        // Web links dropped with them stay in their places, typed as they are.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: \.isFileURL) {
            return .files(urls)
        }
        // An image dragged out of a browser or Preview carries pixels, not a path.
        // Nothing downstream can read pixels off a pasteboard, so spill it to a
        // file and hand over that instead.
        if let file = spillImageToFile(from: pasteboard) { return .files([file]) }
        // A web URL is quoted (its ?query&args would otherwise reach the shell).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first {
            return .text(ShellQuoting.quote(url.absoluteString))
        }
        // Plain text is left exactly as-is: it may be a command meant to be run.
        return pasteboard.string(forType: .string).map(Dropped.text)
    }

    /// The text a drop types on this Mac (no handoff).
    static func droppedText(from pasteboard: NSPasteboard) -> String? {
        switch droppedContent(from: pasteboard) {
        case .files(let urls): typed(urls.map { $0.isFileURL ? $0.path : $0.absoluteString })
        case .text(let text): text
        case nil: nil
        }
    }

    /// ⌘V of what has no text: a file copied in Finder (its path, as a drop
    /// would type it; Finder's text is only the name), or an image with no
    /// text (a screenshot taken to the clipboard, ⌘⌃⇧4), spilled to a file.
    /// Nil: an ordinary paste. Only for a paste the person made with a key
    /// (`isHandlingKey`): a program reading the clipboard (OSC 52) never
    /// starts a copy or gets a path.
    static func pastedFiles(from pasteboard: NSPasteboard) -> [URL]? {
        let text = pasteboard.string(forType: .string) ?? ""
        if let files = fileURLs(on: pasteboard), text.isEmpty || isNames(text, of: files) { return files }
        guard text.isEmpty else { return nil }
        return spillImageToFile(from: pasteboard).map { [$0] }
    }

    /// Finder's text for copied files: their names, one per line. Any
    /// other text with a file on the clipboard is text the person meant.
    static func isNames(_ text: String, of files: [URL]) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == files.count else { return false }
        // Each line names one file of its own: by its name first, then as
        // Finder shows it (an extension it hides left out, a `:` as `/`).
        // Indexed, so a large Finder selection costs one pass.
        func shown(_ name: String) -> String {
            name.replacingOccurrences(of: ":", with: "/").trimmingCharacters(in: .whitespaces)
        }
        var used = Array(repeating: false, count: files.count)
        var exact: [String: [Int]] = [:], loose: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            exact[file.lastPathComponent, default: []].append(index)
            for name in Set([shown(file.lastPathComponent), shown(file.deletingPathExtension().lastPathComponent)]) {
                loose[name, default: []].append(index)
            }
        }
        func take(_ line: String, from table: inout [String: [Int]]) -> Bool {
            while let index = table[line]?.popLast() {
                if !used[index] { used[index] = true; return true }
            }
            return false
        }
        var rest: [String] = []
        for line in lines where !take(line, from: &exact) { rest.append(line) }
        for line in rest where !take(line, from: &loose) { return false }
        return true
    }

    /// The clipboard ⌘V reads; a test hands it a private one.
    static var clipboard: () -> NSPasteboard = { .general }

    /// A key is being handed to libghostty right now: a clipboard read now
    /// is the person's ⌘V (its paste binding asks synchronously), not the
    /// program's request (OSC 52 reads arrive on the runtime's tick).
    var isHandlingKey: Bool { dispatchingKey }
    private var dispatchingKey = false

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    static func typed(_ paths: [String]) -> String {
        paths.map(ShellQuoting.quote).joined(separator: " ")
    }

    /// Drops and handed-over pastes type in the order they were made, each
    /// after the one before it has answered (a slow copy is not overtaken
    /// by a quick one, or by text dropped after it).
    private var lastHandoff: Task<Void, Never>?

    /// Asks `onFiles` for the paths to type, then types them, if the
    /// terminal is still there.
    func handOff(_ urls: [URL]) {
        enqueue { view in
            let files = urls.filter(\.isFileURL)
            let paths: [String]?
            if let onFiles = view.onFiles { paths = await onFiles(files) } else { paths = files.map(\.path) }
            guard let paths, paths.count == files.count, !paths.isEmpty else { return nil }
            var next = paths.makeIterator()
            return Self.typed(urls.map { $0.isFileURL ? next.next()! : $0.absoluteString })
        }
    }

    private func enqueue(_ text: @escaping @MainActor (GhosttySurfaceView) async -> String?) {
        let previous = lastHandoff
        lastHandoff = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let typed = await text(self), let surface = self.surface, !self.childHasExited else { return }
            // Typed as a drop's text is (a paste), without touching a
            // composition the person may have started meanwhile.
            self.onInput?()
            ghostty_surface_text(surface, typed, UInt(typed.utf8.count))
        }
    }

    /// Write image data to a temp file (`image.png`); returns its URL.
    private static func spillImageToFile(from pasteboard: NSPasteboard) -> URL? {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }

        // A folder of its own, so the file can be called what it is: a tab
        // copying it to another machine shows its name.
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Temple/\(TerminalHandoff.spilledImagesFolder)/\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("image.png")
            try png.write(to: file)
            return file
        } catch {
            GhosttyApp.logger.error("dropped image could not be written: \(String(describing: error), privacy: .public)")
            return nil
        }
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
            return
        }
        // Outside a key press (an IME commit, a drop's text): input of its own.
        onInput?()
        if let surface {
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
