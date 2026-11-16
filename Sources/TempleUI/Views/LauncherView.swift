import SwiftUI
import AppKit
import TempleCore

/// The empty-state / ⌘⇧H home page (ADR-008/012, docs/designs/ux-pass-2026-11.md
/// section 4): a quiet, typographic page with the two things you come to it
/// for. **Start**: a new session, saying where it will start, and one row for
/// anywhere else (the ⌘N picker). **Continue**: your most recent sessions
/// that are not open, to resume. The other screens (⌘K, History, shortcuts,
/// Settings) are a line of key hints at the foot, taught but not competing:
/// a list of thirteen rows, six of them signposts and one per host, buried
/// the two that start work.
struct LauncherView: View {
    @EnvironmentObject var model: AppModel
    /// The Continue list is ordered by activity, which AppModel does not
    /// publish (B9): it redraws itself when it changes.
    @StateObject private var recency = RecencyRefresh()

    private static let recentLimit = 5

    private var recentSessions: [Session] { Self.recentSessions(model) }

    /// The sessions to continue: resumable, not open in a tab, most recent
    /// activity first.
    static func recentSessions(_ model: AppModel) -> [Session] {
        Array(model.visibleRows
            .filter { $0.canResume && model.openSessions.openTab(for: $0.id) == nil }
            .sorted { $0.sortDate == $1.sortDate ? $0.id < $1.id : $0.sortDate > $1.sortDate }
            .prefix(recentLimit))
    }

    /// One Continue row as drawn, as far as activity can change it.
    struct RecentLine: Hashable {
        let key: SessionKey
        let time: String
    }

    /// What the Continue list shows that activity can change: which
    /// sessions, in which order, and each one's age.
    static func recentPresentation(_ model: AppModel) -> [RecentLine] {
        recentSessions(model).map { RecentLine(key: $0.id, time: RelativeTime.compact(from: $0.sortDate)) }
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
        // gap when it does not. Nothing here can grow the pane, or the
        // divider drawn at its top, into the title band, and nothing on the
        // page draws there when scrolled (TitleBandHeightTests).
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
            .thinScrollers()
            // SwiftUI runs the scroll view up under the transparent title
            // band (full-size content view), insetting only its content, so
            // a scrolled page drew over the chips. Clipped to the pane, as
            // History is: the band never shows the launcher.
            .clipped()
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 30) {
            masthead
            toolchainWarnings
            start
            if !recentSessions.isEmpty {
                recent.background(LayoutMarker(id: Self.recentMarker))
            }
            keyHints
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

    // MARK: Start

    private var start: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionRule("Start")

            // As the + menu orders them: the default agent first with ⌘T,
            // the other with ⌥⌘T. Both by the agent's name ("Claude Code",
            // never the bare "Claude", which is the assistant and its apps).
            // Each says where it starts: the active project, else the
            // last-used one; with neither it asks for a folder. The hints
            // only where they are true: ⌘T and ⌥⌘T need an active project.
            let project = model.launcherDefaultProjectKey
            ForEach(launcherAgents, id: \.self) { agent in
                LauncherRow(icon: .agent(agent),
                            title: "New \(agent.displayName) session" + (project == nil ? "…" : ""),
                            detail: project.map { "in " + $0.name },
                            detailTag: project.flatMap(ProjectNameLabel.hostTag),
                            shortcut: model.openSessions.activeProjectKey == nil ? nil
                                : agent == model.settings.defaultAgent ? "⌘T" : "⌥⌘T") {
                    newSession(agent)
                }
            }
            // Every other project, a folder, and every host's folders: the
            // ⌘N picker lists them all, so one row stands for them, however
            // many hosts there are.
            if project != nil {
                LauncherRow(icon: .symbol("folder.badge.plus"),
                            title: model.remoteLaunchHosts.isEmpty
                                ? "New session in another project…"
                                : "New session in another project or on another host…",
                            shortcut: "⌘N") {
                    model.toggleNewSessionPicker()
                }
            }
        }
    }

    // MARK: Continue

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionRule("Continue")
            ForEach(recentSessions) { session in
                ContinueRow(session: session, title: model.displayTitle(session)) {
                    model.openSessions.openSession(session)
                }
            }
        }
    }

    // MARK: Key hints

    /// The rest of Temple, one key each: a line to learn the keys from, not
    /// a list to scan past.
    private var keyHints: some View {
        HStack(spacing: 18) {
            KeyHint(key: "⌘K", label: "Search Sessions") { model.toggleCommandPalette() }
            KeyHint(key: "⌘Y", label: "History") { model.showHistory() }
            KeyHint(key: "⌘/", label: "Keyboard Shortcuts") { model.toggleShortcuts() }
            KeyHint(key: "⌘,", label: "Settings") { model.openSessions.openSettings() }
        }
        .padding(.leading, 8)
    }

    // MARK: Actions

    /// Start `agent` in the last-used project; if none is known, ask for a folder.
    private var launcherAgents: [Agent] {
        [model.settings.defaultAgent] + Agent.allCases.filter { $0 != model.settings.defaultAgent }
    }

    private func newSession(_ agent: Agent) {
        if let key = model.launcherDefaultProjectKey {
            model.openSessions.newSession(agent: agent, project: key)
        } else {
            chooseProjectFolder { project in
                model.openSessions.newSession(agent: agent, project: project)
            }
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
    /// Where the row acts, after the title in a quieter tone ("in storefront"),
    /// and the machine's tag when it is another machine.
    var detail: String? = nil
    var detailTag: String? = nil
    var shortcut: String? = nil
    var trailing: String? = nil
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
                // One text, so "in storefront" sits a word space after the
                // title rather than a column gap.
                (Text(title).foregroundStyle(.primary)
                    + Text(detail.map { " " + $0 } ?? "").foregroundStyle(.secondary))
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detailTag {
                    Text(detailTag)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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

/// A session to resume: its agent, its title, then where it ran (project,
/// and the machine when it is another one) and how long ago.
private struct ContinueRow: View {
    let session: Session
    let title: String
    let action: () -> Void

    @State private var rawHovering = false
    @Environment(\.overlayActive) private var overlayActive
    private var hovering: Bool { rawHovering && !overlayActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let agent = session.agent {
                        AgentBadge(agent: agent, size: 15)
                    } else {
                        Image(systemName: "terminal").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let project = session.project {
                    // Plain frames, no layout priority: this page is the
                    // detail pane, where a measuring modifier can cost the
                    // sidebar its titlebar inset (AGENTS.md).
                    HStack(spacing: 5) {
                        Text(project.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150, alignment: .trailing)
                        if let tag = ProjectNameLabel.hostTag(project) {
                            Text(tag)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 120, alignment: .leading)
                        }
                    }
                }
                Text(RelativeTime.compact(from: session.sortDate))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Palette.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { rawHovering = $0 }
        .help("Resume this session")
    }
}

/// One key hint at the page's foot: the chord, then what it opens. A
/// button, so it works by click as well as by key.
private struct KeyHint: View {
    let key: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(key).foregroundStyle(.tertiary)
                Text(label).foregroundStyle(hovering ? .primary : .secondary)
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
