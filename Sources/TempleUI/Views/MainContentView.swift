import SwiftUI

/// The right pane: the active tab's terminal (or Settings), or the launcher when
/// nothing is open (UX §Main content). The per-project tab strip now lives in
/// the native unified toolbar / title-bar band (Item A), attached below.
struct MainContentView: View {
    @EnvironmentObject var model: AppModel

    private var hasTabBar: Bool { !model.openSessions.visibleTabs.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { tabStripToolbar }
    }

    /// The tab chips in the native title-bar band. Only present when the active
    /// project has open tabs — otherwise the band is empty native chrome (c).
    @ToolbarContentBuilder
    private var tabStripToolbar: some ToolbarContent {
        if hasTabBar {
            ToolbarItem(placement: .navigation) {
                TabBarStrip()
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
