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
            .preferredColorScheme(model.settings.theme.colorScheme)

            if model.commandPalettePresented {
                paletteOverlay
            }
        }
        .tint(Palette.accent)              // neutral accent everywhere (no blue)
        // Guard against interrupting a busy agent on ⌘W / chip ✕ (supersedes the
        // no-prompt close in UX.md).
        .alert(pendingCloseTitle, isPresented: pendingCloseBinding) {
            Button("Cancel", role: .cancel) { model.openSessions.cancelPendingClose() }
            Button("Close", role: .destructive) { model.openSessions.confirmPendingClose() }
        } message: {
            Text("Its agent is still working — closing will interrupt it.")
        }
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

    /// Full-window dimmer with the palette centered on BOTH axes over the entire
    /// window (Item H).
    private var paletteOverlay: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { model.commandPalettePresented = false }
            CommandPaletteView()
                .environmentObject(model)
                .tint(Palette.accent)
        }
        .transition(.opacity)
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
        return NSView()
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

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model else { return event }
                    return self.handle(event, model) ? nil : event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        @MainActor
        private func handle(_ event: NSEvent, _ model: AppModel) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            let ctrl = flags.contains(.control)
            let shift = flags.contains(.shift)
            let chars = event.charactersIgnoringModifiers ?? ""

            // ⌃⇥ / ⌃⇧⇥ — next / previous tab (keyCode 48 = tab).
            if ctrl && event.keyCode == 48 {
                shift ? model.openSessions.selectPreviousTab() : model.openSessions.selectNextTab()
                return true
            }

            // Esc always dismisses the ⌘K palette, wherever focus is (its own
            // .onKeyPress only fires while the palette field is focused).
            if event.keyCode == 53, model.commandPalettePresented {
                model.commandPalettePresented = false
                return true
            }

            // Sidebar browse (UX "Select vs. open"): arrow keys move the highlight,
            // Enter opens it — but ONLY while no terminal is focused, so a live
            // agent still owns its arrow keys.
            let browsing = model.openSessions.activeTab == nil
                && !model.commandPalettePresented
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
            case "t":
                if model.openSessions.newSessionDefaultAgent() == nil { model.openSessions.showHome() }
                return true
            case "w":
                model.openSessions.requestCloseActiveTab(); return true
            case "n":
                model.openSessions.showHome(); return true
            case "f":
                if model.sidebarVisibility == .detailOnly { model.sidebarVisibility = .all }
                model.focusSearchToken += 1; return true
            case "k":
                model.commandPalettePresented.toggle(); return true
            case "\\":
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
