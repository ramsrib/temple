import SwiftUI

/// The right pane: the active tab's terminal (or Settings), or the launcher when
/// nothing is open (UX §Main content). The per-project tab strip lives in the
/// native title-bar band as a titlebar ACCESSORY, not a toolbar item — an item
/// wider than the band overflows all-or-nothing into the `»` menu. The installer
/// is this pane's background so the strip's leading edge tracks the sidebar
/// divider live (see TitlebarTabStrip.swift).
struct MainContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TitlebarTabStripInstaller())
            // Separates the tab band from the content below it. As this pane's
            // overlay it spans exactly the detail area — the sidebar keeps its
            // own seamless join with the title bar.
            .overlay(alignment: .top) {
                if !model.openSessions.visibleTabs.isEmpty {
                    Divider()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let active = model.openSessions.activeTab {
            switch active.kind {
            case .settings:
                SettingsView()
            case .session:
                terminal(for: active)
            }
        } else {
            LauncherView()
        }
    }

    @ViewBuilder
    private func terminal(for tab: SessionTab) -> some View {
        if tab.surface != nil {
            // `SessionTab` is an ObservableObject: the banner below keys off
            // `tab.activity`, which flips *after* the view first renders (the agent
            // dies a moment after spawning). Reading it from here would never
            // re-render — the subview has to subscribe.
            SessionTerminalView(tab: tab)
                .id(tab.id)
        } else {
            // Active tab without a surface (restored chip just clicked) — spawn it.
            Color.clear.onAppear { model.openSessions.activate(tabID: tab.id) }
        }
    }
}

/// A session's terminal, with a header that appears if the agent failed to launch.
private struct SessionTerminalView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: SessionTab

    var body: some View {
        VStack(spacing: 0) {
            if case .exited(let status) = tab.activity {
                launchFailure(status: status)
            }
            if let surface = tab.surface {
                TerminalSurfaceHost(surface: surface)
            }
        }
    }

    /// An agent that died seconds after spawning didn't finish — it failed to start
    /// (`OpenSessionsModel` keeps the tab precisely so its output survives). The
    /// terminal below shows the CLI's own words about *why*; this says what Temple
    /// actually ran, which is the one thing the terminal can't tell you and the only
    /// half of the story Temple is responsible for.
    private func launchFailure(status: Int32) -> some View {
        let argv = tab.command?.argv ?? []
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                // The status is only worth showing when it carries information. The
                // surface reports 0 for a process that plainly crashed (libghostty
                // spawns through `login`, whose own exit status is what comes back),
                // and "failed to start (status 0)" reads as a contradiction that
                // makes a user distrust the whole message.
                Text(status == 0
                     ? "\(tab.agent.displayName) exited immediately — it failed to start."
                     : "\(tab.agent.displayName) exited immediately (status \(status)) — it failed to start.")
                    .font(.system(size: 12, weight: .medium))
                if !argv.isEmpty {
                    Text(argv.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Text("Check the command and arguments in Settings; the terminal below has the error.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Settings") { model.openSessions.openSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}
