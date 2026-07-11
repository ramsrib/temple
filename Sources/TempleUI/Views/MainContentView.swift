import SwiftUI

/// The right pane: the per-project tab bar over either the active tab's terminal
/// (or Settings), or the launcher when nothing is open (UX §Main content).
struct MainContentView: View {
    @EnvironmentObject var model: AppModel

    private var hasTabBar: Bool { !model.openSessions.visibleTabs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if hasTabBar {
                TabBarView()
                Divider().opacity(0.5)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
