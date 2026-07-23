import SwiftUI

/// The window content: native split (sidebar + main), plus the ⌘K palette
/// overlay, keyboard handling, and live theme.
public struct RootView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        // A window-level ZStack so the ⌘K palette centers over the WHOLE window
        // (Spotlight-style), not just the detail pane.
        ZStack {
            NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            } detail: {
                MainContentView()
            }
            .navigationSplitViewStyle(.balanced)
            .background(KeyCatcher())
            // See OverlayActiveKey: hover fills below a panel must stand down
            // (an environment value, unlike allowsHitTesting, doesn't make
            // SwiftUI rewrap the split view and break its titlebar inset).
            .environment(\.overlayActive, overlayPresented)
            // The project control belongs at the FAR end of the title bar, not
            // among the tabs: the tabs are the sessions inside this project, so a
            // project control sitting among them reads as one of them.
            .preferredColorScheme(model.settings.theme.colorScheme)

            if model.commandPalettePresented {
                paletteOverlay
            }
            if model.historyPresented {
                historyOverlay
            }
            if model.newSessionPickerPresented {
                newSessionPickerOverlay
            }
            if model.projectSwitcherPresented {
                projectSwitcherOverlay
            }
            if model.shortcutsPresented {
                shortcutsOverlay
            }
        }
        .tint(Palette.accent)              // neutral accent everywhere (no blue)
        // AppKit hands initial key focus to the first text field it finds —
        // the sidebar search — and can re-seat it while the window settles,
        // so a single async clear leaves a gap where fast launch typing
        // lands in the field. Sweep the first second instead, dropping any
        // strays that got in; focus only reaches search via ⌘F or a click.
        .onAppear {
            // Verify the agent CLIs (runs `claude --version` &c). Started from the UI,
            // not from AppModel.init, so building a model in a test doesn't shell out.
            // Launches before it lands fall back to the shell's own answer — see
            // `ToolchainModel.launchPath`.
            model.toolchain.detect()

            let launchToken = model.focusSearchToken
            let sweep = LaunchFocusSweep()
            // A click is deliberate focus — the sweep must stand down for
            // good, or it would clear a field the user just chose (and any
            // text typed into it) up to a second into the app's life.
            sweep.monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { event in
                MainActor.assumeIsolated { sweep.cancel() }
                return event
            }
            for delay in [0.0, 0.1, 0.25, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    defer { if delay == 1.0 { sweep.cancel() } }  // last tick retires the monitor
                    // ⌘F or an open palette means the focus is wanted.
                    guard !sweep.cancelled,
                          model.focusSearchToken == launchToken,
                          !model.commandPalettePresented,
                          !model.historyPresented,
                          !model.newSessionPickerPresented else { return }
                    let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
                    if window?.firstResponder is NSTextView {  // field editor == a focused text field
                        window?.makeFirstResponder(nil)
                        if !model.searchText.isEmpty { model.searchText = "" }
                    }
                }
            }
        }
        // Guard against interrupting a busy agent on ⌘W / chip ✕ (supersedes the
        // no-prompt close in UX.md).
        .alert(pendingCloseTitle, isPresented: pendingCloseBinding) {
            Button("Cancel", role: .cancel) { model.openSessions.cancelPendingClose() }
            // Return confirms (the user explicitly asked to close); Esc cancels.
            // No .destructive role: its red pressed-state flashes on activation,
            // which reads as a glitch against the monochrome chrome.
            Button("Close") { model.openSessions.confirmPendingClose() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Its agent is still working — closing will interrupt it.")
        }
    }

    /// Any floating panel (⌘K / ⌘Y / ⌘P / ⌘/) currently over the window.
    private var overlayPresented: Bool {
        model.commandPalettePresented
            || model.historyPresented
            || model.newSessionPickerPresented
            || model.projectSwitcherPresented
            || model.shortcutsPresented
    }

    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: { model.openSessions.pendingCloseTabID != nil },
            set: { if !$0 { model.openSessions.cancelPendingClose() } })
    }

    private var pendingCloseTitle: String {
        guard let tab = model.openSessions.pendingCloseTab else { return "Close session?" }
        let name: String
        if let sid = tab.sessionID, let custom = model.overlay.customName(for: sid) {
            name = custom
        } else {
            name = tab.title
        }
        return "Close “\(name)”?"
    }

    /// ⌘P switcher: centred like the app switcher, not top-anchored like ⌘K —
    /// it is a momentary HUD you hold, not a surface you type into.
    private var projectSwitcherOverlay: some View {
        ZStack {
            OverlayBackdrop { model.cancelProjectSwitcher() }
                .ignoresSafeArea()
            PanelHost {
                ProjectSwitcherHUD()
                    .environmentObject(model)
            }
            .fixedSize()
        }
        .transition(.opacity)
    }

    /// ⌘/ reference card, same overlay pattern as the palette.
    private var shortcutsOverlay: some View {
        ZStack {
            OverlayBackdrop { model.shortcutsPresented = false }
                .ignoresSafeArea()
            PanelHost { ShortcutsView() }
                .fixedSize()
        }
        .transition(.opacity)
    }

    /// Full-window backdrop; the palette's TOP edge is anchored (Spotlight-
    /// style, ~35% down) so the card grows downward as results change instead
    /// of re-centering and bouncing its top edge.
    private var paletteOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                OverlayBackdrop { model.commandPalettePresented = false }
                    .ignoresSafeArea()
                PanelHost {
                    CommandPaletteView()
                        .environmentObject(model)
                        .tint(Palette.accent)
                }
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * 0.35)
            }
        }
        .transition(.opacity)
    }

    /// ⌘Y history sits exactly where ⌘K does — the two are siblings (same
    /// width, same top anchor, same capped list), differing in content, not
    /// chrome, so switching between them never feels like a mode change.
    private var historyOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                OverlayBackdrop { model.historyPresented = false }
                    .ignoresSafeArea()
                PanelHost {
                    HistoryView()
                        .environmentObject(model)
                        .tint(Palette.accent)
                }
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * 0.35)
            }
        }
        .transition(.opacity)
    }

    /// ⌘N / ⌘⇧N — the project picker for a new session; ⌘K's chrome exactly.
    private var newSessionPickerOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                OverlayBackdrop { model.newSessionPickerPresented = false }
                    .ignoresSafeArea()
                PanelHost {
                    NewSessionPickerView()
                        .environmentObject(model)
                        .tint(Palette.accent)
                }
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.top, geo.size.height * 0.35)
            }
        }
        .transition(.opacity)
    }
}

/// State for the launch focus sweep: one flag and the click monitor that
/// retires it (a class so the monitor callback and the delayed ticks share
/// mutations).
@MainActor
private final class LaunchFocusSweep {
    var cancelled = false
    var monitor: Any?

    func cancel() {
        cancelled = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The floating panels are drawn by the window's ROOT SwiftUI layer, but the
/// split view's columns are AppKit subviews — and AppKit routes clicks and
/// hover to subviews first, so a purely drawn panel is visible yet
/// untouchable: every event lands on the launcher beneath it (only the
/// palette's NSView-backed text field ever responded). Both overlay layers
/// therefore need REAL NSViews: a backdrop that swallows events (click =
/// dismiss), and a nested hosting view that carries the panel itself.
private struct OverlayBackdrop: NSViewRepresentable {
    let dismiss: () -> Void

    final class BackdropView: NSView {
        var dismiss: () -> Void = {}
        override func mouseDown(with event: NSEvent) { dismiss() }
    }

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.dismiss = dismiss
    }
}

/// See OverlayBackdrop. `clipsToBounds = false` keeps the panel's soft
/// shadow, which extends past the hosting view's intrinsic bounds.
private struct PanelHost<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content())
        view.sizingOptions = .intrinsicContentSize
        view.clipsToBounds = false
        // A floating panel wants no safe-area participation — and on macOS 26
        // the default (tracking the window's safe areas) sets up a feedback
        // loop: every constraint pass re-invalidates this hosting view's safe
        // area, which requests another pass, until AppKit's loop detector
        // ("more Update Constraints passes than views") kills the app. The
        // shortcuts card crashed on ⌘/ from exactly this, via
        // NSHostingView.invalidateSafeAreaInsets in the crash backtrace.
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content()
    }
}

/// Installs an app-local key monitor for Temple's shortcuts (UX "Keyboard
/// shortcuts"). Centralized here so menu/window defaults never fight the tab
/// keybindings (⌘W closes the *tab*, not the window).
private struct KeyCatcher: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        context.coordinator.model = model
        context.coordinator.install()
        return InitialFocusDenier()
    }

    /// AppKit seats initial keyboard focus on the first text field in the
    /// key-view loop — the sidebar search. The launch sweep (RootView.onAppear)
    /// then clears it, which used to be invisible; macOS 26 pops a completions
    /// dropdown the instant a field is focused, so the transient seat now
    /// flashes UI. Refuse the initial seat outright — the sweep stays as the
    /// backstop for AppKit re-seating focus while the window settles.
    final class InitialFocusDenier: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = nil
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var model: AppModel?
        private var monitor: Any?
        /// The ⌘P switcher lands when ⌘ comes back up (the ⌘⇥ gesture), and a
        /// modifier release is a flagsChanged event, not a keyDown.
        private var flagsMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model else { return event }
                    return self.handle(event, model) ? nil : event
                }
            }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model, model.projectSwitcherPresented else { return event }
                    if !event.modifierFlags.contains(.command) { model.commandReleasedForSwitcher() }
                    return event
                }
            }
            // A ⌘ released while another app is frontmost never reaches our monitor,
            // and the switcher would still be up when Temple came back.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.cancelProjectSwitcher() }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            flagsMonitor = nil
            resignObserver = nil
        }

        @MainActor
        private func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
            // A confirmation dialog owns the keyboard — pass everything through
            // so Return/Esc reach the alert instead of our shortcuts.
            if model.openSessions.pendingCloseTabID != nil { return false }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            let ctrl = flags.contains(.control)
            let shift = flags.contains(.shift)
            let chars = event.charactersIgnoringModifiers ?? ""

            // While the switcher is up it OWNS the keyboard, exactly like ⌘⇥:
            // ⌘P walks it, arrows walk it, Return lands, Esc leaves you where you
            // were — and nothing else fires. Without this, ⌘W would close a tab and
            // ⌘K would open a palette behind the HUD.
            if model.projectSwitcherPresented {
                switch event.keyCode {
                case 35:  // p
                    if cmd { model.advanceProjectSwitcher(by: shift ? -1 : 1) }
                case 53: model.cancelProjectSwitcher()                    // esc
                case 36, 76: model.commitProjectSwitcher()                // return
                case 123: model.advanceProjectSwitcher(by: -1)            // ←
                case 124: model.advanceProjectSwitcher(by: 1)             // →
                default: break
                }
                return true
            }

            // ⌃⇥ / ⌃⇧⇥ — next / previous tab (keyCode 48 = tab).
            if ctrl && event.keyCode == 48 {
                shift ? model.openSessions.selectPreviousTab() : model.openSessions.selectNextTab()
                return true
            }

            // ⌘⇧[ / ⌘⇧] — previous / next project. Matched on keyCode because
            // with shift held AppKit reports these as "{" / "}".
            if cmd && shift {
                switch event.keyCode {
                case 33: model.openSessions.selectPreviousProject(); return true   // [
                case 30: model.openSessions.selectNextProject(); return true       // ]
                default: break
                }
            }


            // Esc always dismisses overlays, wherever focus is (the palette's
            // own .onKeyPress only fires while its field is focused).
            if event.keyCode == 53,
               model.commandPalettePresented || model.historyPresented
                || model.newSessionPickerPresented || model.shortcutsPresented {
                model.commandPalettePresented = false
                model.historyPresented = false
                model.newSessionPickerPresented = false
                model.shortcutsPresented = false
                return true
            }

            // Sidebar browse (UX "Select vs. open"): arrow keys move the highlight,
            // Enter opens it — but ONLY while no terminal is focused, so a live
            // agent still owns its arrow keys.
            let browsing = model.openSessions.activeTab == nil
                && !model.commandPalettePresented
                && !model.historyPresented
                && !model.newSessionPickerPresented
                && !model.shortcutsPresented
            if browsing && !cmd && !ctrl {
                switch event.keyCode {
                case 125: model.moveHighlight(by: 1); return true    // ↓
                case 126: model.moveHighlight(by: -1); return true   // ↑
                case 36, 76: model.openHighlighted(); return true    // return / enter
                default: break
                }
            }

            guard cmd else { return false }

            switch chars {
            case "T":
                guard shift else { return false }
                model.openSessions.reopenLastClosedTab(); return true
            case "t":
                if model.openSessions.newSessionDefaultAgent() == nil { model.openSessions.showHome() }
                return true
            case "w":
                model.openSessions.requestCloseActiveTab(); return true
            case "n":
                model.toggleNewSessionPicker(); return true
            case "N":   // ⇧ (or caps lock — treat as plain ⌘N then)
                model.toggleNewSessionPicker(alternateAgent: shift); return true
            case "H":   // ⌘⇧H — home; plain ⌘H stays the system Hide
                guard shift else { return false }
                model.openSessions.showHome(); return true
            case "f":
                if model.sidebarVisibility == .detailOnly { model.sidebarVisibility = .all }
                model.focusSearchToken += 1; return true
            case "k":
                model.toggleCommandPalette(); return true
            case "y":
                model.toggleHistory(); return true
            case "p":
                model.advanceProjectSwitcher(by: shift ? -1 : 1); return true
            case "/":
                model.toggleShortcuts(); return true
            case "b":  // VS Code / ChatGPT convention (supersedes UX.md's ⌘\)
                withAnimation { model.sidebarVisibility = model.sidebarVisibility == .all ? .detailOnly : .all }
                return true
            case ",":
                model.openSessions.openSettings(); return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let n = Int(chars) { model.openSessions.selectTab(index: n) }
                return true
            default:
                return false
            }
        }
    }
}
