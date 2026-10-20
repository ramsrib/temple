import SwiftUI
import TempleCore
import TempleTerminalAPI

/// The native menu bar, shared by both app entry points.
///
/// These items are a discoverable, clickable MIRROR of Temple's commands —
/// the keyboard itself is handled by RootView's KeyCatcher monitor, which
/// sees events before menu key-equivalents and deliberately owns anything
/// conditional (⌘W closes the tab, never the window; overlays gate keys).
/// The shortcuts shown here must therefore match KeyCatcher's bindings; the
/// menu actions call the same model entry points, so whichever path fires,
/// the behavior is identical.
public struct TempleCommands: Commands {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        // File: session lifecycle replaces New Window — Temple is a
        // single-window app (multi-window is roadmap), so the default
        // WindowGroup item would spawn a second, unsupported window.
        CommandGroup(replacing: .newItem) {
            // Both agents by name: a bare "New Session" beside "New Codex
            // Session" left the default to be inferred (cold read).
            Button("New \(model.settings.defaultAgent.displayName) Session") {
                if model.openSessions.newSessionDefaultAgent() == nil {
                    model.openSessions.showHome()
                }
            }
            .keyboardShortcut("t")

            // ⌥ is "the other agent" for both new-session commands.
            Button("New \(model.alternateAgent.displayName) Session") { model.newSessionAlternateAgent() }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Button("New \(model.settings.defaultAgent.displayName) Session in Project…") { model.toggleNewSessionPicker() }
                .keyboardShortcut("n")

            Button("New \(model.alternateAgent.displayName) Session in Project…") {
                model.toggleNewSessionPicker(alternateAgent: true)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Open Project Folder…") { model.openProjectFolder() }
                .keyboardShortcut("o")

            Button("Reopen Closed Tab") { model.openSessions.reopenLastClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // File: Close Tab replaces the window Close/Save group.
        CommandGroup(replacing: .saveItem) {
            // A tab on a host: Detach, above Close Tab, no shortcut.
            if let tab = model.openSessions.activeTab, tab.kind == .session, tab.remote != nil {
                Button(RemoteCopy.detachMenuItem(tab.host.rawValue)) { model.openSessions.remoteTabs.detach(tab.id) }
            }
            Button("Close Tab") { model.openSessions.requestCloseActiveTab() }
                .keyboardShortcut("w")
        }

        // Edit: find belongs to the terminal, so these replace the system Find
        // submenu (whose ⌘F would otherwise sit beside ours). The placement is
        // the whole text-editing group, so Spelling / Substitutions /
        // Transformations / Speech go with it — none of which apply to a
        // terminal. Like every item here they mirror KeyCatcher, which does
        // the actual key handling.
        CommandGroup(replacing: .textEditing) {
            // On the History tab there is no terminal to find in, so ⌘F is
            // the page's search, retitled the way Undo retitles.
            Button(model.historyActive ? "Find in History…" : "Find in Terminal…") {
                model.findInActiveTerminal()
            }
            .keyboardShortcut("f")
            .disabled(model.activeTerminalFind == nil && !model.historyActive)
            // Enabled state can only track the terminal (the bar's open/closed
            // state is not observed here); the action itself refuses when the
            // bar is closed, matching KeyCatcher.
            Button("Find Next") { model.navigateActiveTerminalFind(.next) }
                .keyboardShortcut("g")
                .disabled(model.activeTerminalFind == nil)
            Button("Find Previous") { model.navigateActiveTerminalFind(.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.activeTerminalFind == nil)
        }

        // App menu: Settings… (no Settings scene exists, so SwiftUI won't
        // add one on its own).
        CommandGroup(replacing: .appSettings) {
            Button { model.openSessions.openSettings() } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
        }

        // View: our sidebar toggle replaces the default (⌃⌘S) so the menu
        // advertises the same ⌘B the app actually binds.
        // Icons throughout: the system's Enter Full Screen item carries one
        // on macOS 26, which makes the menu reserve an icon column — lone
        // text items then read as misaligned.
        CommandGroup(replacing: .sidebar) {
            Button {
                withAnimation { model.toggleSidebar() }
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("b")
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button { model.toggleCommandPalette() } label: {
                Label("Command Palette", systemImage: "command")
            }
            .keyboardShortcut("k")
            Button { model.showHistory() } label: {
                Label("Session History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y")
            // ⌘R refreshes the page in front, retitled the way Find is: the
            // History snapshot, or Settings' agent check.
            Button {
                if model.historyActive { model.history.refresh() } else { model.toolchain.detect() }
            } label: {
                // Names what is checked: "Check Agents Again" read as the
                // running sessions, not the installed CLIs (cold read).
                // Elsewhere it does nothing, and a greyed item naming History
                // read as History being broken: plain "Refresh" there.
                Label(settingsActive ? "Check for \(agentNames) Again"
                        : model.historyActive ? "Refresh History" : "Refresh",
                      systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(!model.historyActive && !settingsActive)
            Button { model.showArchived() } label: {
                Label("Archived Sessions", systemImage: "archivebox")
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            Button { model.openSessions.showHome() } label: {
                Label("Home", systemImage: "house")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            // The footer shows numbers or nothing, so a Claude-only user whose
            // meter has never appeared needs a route to the one refresh that
            // may raise the Keychain prompt. This is it.
            Button { model.usage.manualRefresh(retryingCredentials: true) } label: {
                Label("Refresh Usage", systemImage: "gauge.with.needle")
            }
            Button { model.toggleShortcuts() } label: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }
            .keyboardShortcut("/")
        }

        CommandMenu("Project") {
            Button("Switch Project…") { model.advanceProjectSwitcher(by: 1, heldCommand: false) }
                .keyboardShortcut("p")
            Divider()
            Button("Next Project") { model.openSessions.selectNextProject() }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Project") { model.openSessions.selectPreviousProject() }
                .keyboardShortcut("[", modifiers: [.command, .option])
        }

        // Window: tab stepping where Safari keeps it, at the keys every Mac
        // tabbed app uses for it. The ⌃⇥ switcher walks by recency instead.
        CommandGroup(before: .windowArrangement) {
            Button("Show Previous Tab") { model.openSessions.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Show Next Tab") { model.openSessions.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
        }
    }

    private var agentNames: String {
        Agent.allCases.map(\.displayName).joined(separator: " and ")
    }

    private var settingsActive: Bool {
        model.openSessions.activeTab?.kind == .settings
    }
}
