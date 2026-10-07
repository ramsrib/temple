import SwiftUI
import AppKit
import TempleCore

/// The empty-state / ⌘⇧H launcher (ADR-008/012, U4): a quiet, typographic home —
/// wordmark + tagline, a "Get started" action list (agent choice = which "New …"
/// row you pick), and a "Recent projects" list. Monochrome, list-driven; no
/// cards, segmented controls, or prominent buttons. Spawn-terminal MVP — a row
/// click opens a fresh terminal (no prompt input).
struct LauncherView: View {
    @EnvironmentObject var model: AppModel
    /// The recent list is ordered by activity, which AppModel does not
    /// publish after the rank freeze (B9): it redraws itself when it changes.
    @StateObject private var recency = RecencyRefresh()

    private static let recentLimit = 5

    private var recentProjects: [SessionRowProject] { Self.recentProjects(model) }

    /// Recent member projects, ordered by Temple row activity.
    static func recentProjects(_ model: AppModel) -> [SessionRowProject] {
        Array(model.visibleRowProjects.prefix(recentLimit))
    }

    /// One recent row as drawn, as far as activity can change it.
    struct RecentLine: Hashable {
        let key: ProjectKey
        let time: String
    }

    /// What the recent list shows that activity can change: which projects,
    /// in which order, and each one's time.
    static func recentPresentation(_ model: AppModel) -> [RecentLine] {
        recentProjects(model).map { RecentLine(key: $0.key, time: RelativeTime.string(from: $0.lastActivity)) }
    }

    /// The gap between the title band and the masthead when the launcher
    /// is taller than its pane (scrolled to the top), and the least gap
    /// when it is centred.
    static let topGap: CGFloat = 32
    private static let bottomGap: CGFloat = 40

    var body: some View {
        // Scrolls when the content is taller than the pane: with five recent
        // projects, toolchain warnings or "Switch project", a short window's
        // pane cannot hold it, and the rows past the bottom must still be
        // reachable. The pane is measured from outside the scroll view, by
        // what it offers (as History does), so the page is at least the
        // pane's height: centred when it fits, top-aligned with the band
        // gap when it does not. The scroll view is bounded by the pane, so
        // nothing here can grow the pane, or the divider drawn at its top,
        // into the title band (TitleBandHeightTests).
        GeometryReader { pane in
            ScrollView(.vertical) {
                page
                    .frame(maxWidth: .infinity, minHeight: pane.size.height)
                    // A drag on the launcher's empty area moves the window
                    // (Item B); a mouse drag never scrolls a scroll view, so
                    // the page's own background can take it. Title-band
                    // double-clicks are TitleBandDoubleClick's, in every state.
                    .background(WindowActionStrip())
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 30) {
            masthead
            toolchainWarnings
            getStarted
            if !recentProjects.isEmpty {
                recent.background(LayoutMarker(id: Self.recentMarker))
            }
        }
        .onAppear {
            recency.watch(model.overlay) { [weak model] in
                AnyHashable(model.map(Self.recentPresentation) ?? [])
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.top, Self.topGap)
        .padding(.bottom, Self.bottomGap)
    }

    // MARK: Toolchain

    /// Says out loud what Temple found wrong with the agent CLIs on this machine.
    /// A launch that dies because the `claude` first on your PATH can't start is
    /// indistinguishable from Temple being broken — unless something tells you.
    /// - Important: **No `.fixedSize` here, ever.** It is the natural way to let a
    ///   `Text` wrap inside an `HStack`, and it silently breaks the *sidebar*: the
    ///   ideal-height measurement it forces propagates up and makes SwiftUI rewrap
    ///   the `NavigationSplitView`, which drops the sidebar's titlebar inset and
    ///   leaves its rows scrolling over the traffic lights. Bisected from exactly
    ///   this banner. `allowsHitTesting` has the same effect (see RootView) — the
    ///   split view's inset is fragile, and the detail pane can break it from here.
    ///   Wrap text with an expanding frame instead, as below.
    @ViewBuilder
    private var toolchainWarnings: some View {
        let warnings = model.toolchain.warnings(defaultAgent: model.settings.defaultAgent)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(warnings) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: warning.isFatal
                              ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(warning.isFatal ? Color.red : .orange)
                        Text(warning.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Lands on this agent's section (the top for a shell problem).
                        Button("Settings") { model.openSessions.openSettings(focusing: warning.agent) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline, lineWidth: 1)
            )
        }
    }

    // MARK: Masthead

    private var masthead: some View {
        HStack(spacing: 16) {
            TempleMark(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Temple")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Where agents answer the call.")
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .background(LayoutMarker(id: Self.mastheadMarker))
    }

    /// Where the masthead and the Recent list are, for tests that check
    /// them against the title band in a real window (TitleBandHeightTests).
    static let mastheadMarker = NSUserInterfaceItemIdentifier("launcher.masthead")
    static let recentMarker = NSUserInterfaceItemIdentifier("launcher.recent")

    // MARK: Get started

    private var getStarted: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionRule("Get started")

            LauncherRow(icon: .agent(.claude), title: "New Claude session", shortcut: "⌘T") {
                newSession(.claude)
            }
            LauncherRow(icon: .agent(.codex), title: "New Codex session") {
                newSession(.codex)
            }
            LauncherRow(icon: .symbol("folder.badge.plus"), title: "New session in folder…") {
                openFolder()
            }
            LauncherRow(icon: .symbol("command"), title: "Command palette", shortcut: "⌘K") {
                model.toggleCommandPalette()
            }
            LauncherRow(icon: .symbol("clock.arrow.circlepath"), title: "Session history", shortcut: "⌘Y") {
                model.showHistory()
            }
            // History's Archived scope (ADR-031). Always here, so the list is
            // the same list every launch (a row that comes and goes is a row
            // you can't learn), and the scope's empty state does the teaching.
            LauncherRow(icon: .symbol("archivebox"), title: "Archived sessions", shortcut: "⌘⇧Y") {
                model.showArchived()
            }
            // Only when there is somewhere to switch TO: with fewer than two
            // projects open the switcher has nothing to show, and a row that does
            // nothing when clicked is worse than no row.
            if model.switchableProjectKeys.count > 1 {
                LauncherRow(icon: .symbol("folder"), title: "Switch project", shortcut: "⌘P") {
                    model.advanceProjectSwitcher(by: 1, heldCommand: false)
                }
            }
            LauncherRow(icon: .symbol("keyboard"), title: "Keyboard shortcuts", shortcut: "⌘/") {
                model.toggleShortcuts()
            }
            LauncherRow(icon: .symbol("gearshape"), title: "Settings", shortcut: "⌘,") {
                model.openSessions.openSettings()
            }
        }
    }

    // MARK: Recent projects

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The list follows the sidebar — one order, two surfaces — so once
            // the user has arranged that order, "Recent" would be a lie.
            SectionRule(model.hasManualProjectOrder ? "Projects" : "Recent projects")

            ForEach(recentProjects) { project in
                LauncherRow(icon: .symbol("folder"),
                            title: project.name,
                            trailing: RelativeTime.string(from: project.lastActivity),
                            trailingOnHover: true) {
                    model.openSessions.newSession(agent: model.settings.defaultAgent, project: project.key)
                }
            }
        }
    }

    // MARK: Actions

    /// Start `agent` in the last-used project; if none is known, ask for a folder.
    private func newSession(_ agent: Agent) {
        if let key = model.launcherDefaultProjectKey {
            model.openSessions.newSession(agent: agent, project: key)
        } else {
            chooseProjectFolder { project in
                model.openSessions.newSession(agent: agent, project: project)
            }
        }
    }

    private func openFolder() {
        chooseProjectFolder { project in
            model.openSessions.newSessionDefaultAgent(project: project)
        }
    }
}

// MARK: - Row & section building blocks

/// One home-list row: leading icon + label, optional right-aligned shortcut /
/// metadata, hover highlight. The whole row is the hit target.
private struct LauncherRow: View {
    enum Icon {
        case symbol(String)
        case agent(Agent)
    }

    let icon: Icon
    let title: String
    var shortcut: String? = nil
    var trailing: String? = nil
    /// Item D: when true, `trailing` (e.g. a project's relative time) is hidden
    /// until the row is hovered — matching the sidebar's on-hover timestamps.
    var trailingOnHover: Bool = false
    let action: () -> Void

    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    /// Mouse tracking fires by rect through a floating panel; never render
    /// (or reveal trailing text for) a hover that happens under one.
    private var hovering: Bool { rawHovering && !overlayActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                iconView
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .opacity(trailingOnHover && !hovering ? 0 : 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Palette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { rawHovering = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        case .agent(let agent):
            AgentBadge(agent: agent, size: 15)
        }
    }
}

/// An empty AppKit view with an identifier, laid out as the background of
/// the view it marks, so a test can read that view's frame in the window.
/// Invisible to clicks: the page's drag view and the rows keep them.
private struct LayoutMarker: NSViewRepresentable {
    let id: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> NSView {
        let view = MarkerView()
        view.identifier = id
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
