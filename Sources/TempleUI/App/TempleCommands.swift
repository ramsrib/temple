import SwiftUI
import TempleCore

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

    private var alternateAgent: Agent {
        Agent.allCases.first { $0 != model.settings.defaultAgent } ?? model.settings.defaultAgent
    }

    public var body: some Commands {
        // File: session lifecycle replaces New Window — Temple is a
        // single-window app (multi-window is roadmap), so the default
        // WindowGroup item would spawn a second, unsupported window.
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                if model.openSessions.newSessionDefaultAgent() == nil {
                    model.openSessions.showHome()
                }
            }
            .keyboardShortcut("t")

            Button("New Session in Project…") { model.toggleNewSessionPicker() }
                .keyboardShortcut("n")

            Button("New \(alternateAgent.displayName) Session in Project…") {
                model.toggleNewSessionPicker(alternateAgent: true)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Reopen Closed Tab") { model.openSessions.reopenLastClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // File: Close Tab replaces the window Close/Save group.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { model.openSessions.requestCloseActiveTab() }
                .keyboardShortcut("w")
        }

        // App menu: Settings… (no Settings scene exists, so SwiftUI won't
        // add one on its own).
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSessions.openSettings() }
                .keyboardShortcut(",")
        }

        // View: our sidebar toggle replaces the default (⌃⌘S) so the menu
        // advertises the same ⌘B the app actually binds.
        // Icons throughout: the system's Enter Full Screen item carries one
        // on macOS 26, which makes the menu reserve an icon column — lone
        // text items then read as misaligned.
        CommandGroup(replacing: .sidebar) {
            Button {
                withAnimation {
                    model.sidebarVisibility = model.sidebarVisibility == .all ? .detailOnly : .all
                }
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
            Button { model.toggleHistory() } label: {
                Label("Session History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y")
            Button { model.openSessions.showHome() } label: {
                Label("Home", systemImage: "house")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button { model.shortcutsPresented.toggle() } label: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }
            .keyboardShortcut("/")
        }

        CommandMenu("Project") {
            Button("Switch Project…") { model.advanceProjectSwitcher(by: 1, heldCommand: false) }
                .keyboardShortcut("p")
            Divider()
            Button("Next Project") { model.openSessions.selectNextProject() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Project") { model.openSessions.selectPreviousProject() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
