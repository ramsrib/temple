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
        if let surface = tab.surface {
            TerminalSurfaceHost(surface: surface)
                .id(tab.id)
        } else {
            // Active tab without a surface (restored chip just clicked) — spawn it.
            Color.clear.onAppear { model.openSessions.activate(tabID: tab.id) }
        }
    }
}
