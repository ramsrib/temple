import SwiftUI

/// The window content: native split (sidebar + main), plus the launcher sheet,
/// ⌘K palette overlay, keyboard handling, and live theme.
public struct RootView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            MainContentView()
        }
        .navigationSplitViewStyle(.balanced)
        .background(KeyCatcher())
        .preferredColorScheme(model.settings.theme.colorScheme)
        .sheet(isPresented: $model.launcherPresented) {
            LauncherView(isSheet: true)
                .environmentObject(model)
                .frame(width: 520, height: 380)
        }
        .overlay(alignment: .top) {
            if model.commandPalettePresented {
                paletteOverlay
            }
        }
    }

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { model.commandPalettePresented = false }
            CommandPaletteView()
                .environmentObject(model)
                .padding(.top, 90)
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

            // Sidebar browse (UX "Select vs. open"): arrow keys move the highlight,
            // Enter opens it — but ONLY while no terminal is focused, so a live
            // agent still owns its arrow keys.
            let browsing = model.openSessions.activeTab == nil
                && !model.commandPalettePresented && !model.launcherPresented
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
                if model.openSessions.newSessionDefaultAgent() == nil { model.presentLauncher() }
                return true
            case "w":
                model.openSessions.closeActiveTab(); return true
            case "n":
                model.presentLauncher(); return true
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
