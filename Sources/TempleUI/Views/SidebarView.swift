import SwiftUI
import UniformTypeIdentifiers
import TempleCore

/// The left rail: Pinned, project disclosure groups, footer; search unfolds
/// under the band from the title-bar magnifier. The full browse index — a
/// row here is browsable (click opens); arrow keys only highlight (select ≠
/// open).
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAllProjects = false

    var body: some View {
        VStack(spacing: 0) {
            if searchOpen {
                header
            }
            sessionList
            Divider().opacity(0.4)
            footer
        }
        .background(.ultraThinMaterial)
        // The rail's actions live in the title bar, where a Mac app keeps
        // them (Finder, Mail, Notes) — not in a row of their own over the
        // list. The magnifier unfolds the search field under the band; the
        // folder opens a project Temple has never seen (a different act from
        // a project row's `+`, which starts a session). The system sidebar
        // toggle is replaced by our own: it is the one item whose glass
        // capsule we cannot switch off, and one capsuled button beside two
        // bare ones read as a mistake. Ours is the same glyph and the same
        // action as the View menu's own Toggle Sidebar (⌘B, `TempleCommands`
        // already replaces the system menu item), so nothing is lost.
        .toolbar(removing: .sidebarToggle)
        .toolbar { toolbarItems }
    }

    /// The rail's three toolbar items, ours including the sidebar toggle,
    /// at the trailing edge of the sidebar's section of the band. On macOS
    /// 26 they opt out of the shared glass capsule: AppKit never draws it
    /// over the sidebar material, only once the items have slid into the
    /// bare band, and forming it compacts their spacing in one unanimated
    /// step — a jolt after the slide. Measured frame by frame; a capsule in
    /// both states is not on offer.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // Flexible space first: the group sits at the trailing edge of the
        // sidebar's section, by the divider, where Notes and Mail keep the
        // toggle. Without it they hugged the traffic lights.
        ToolbarItem(placement: .automatic) { Spacer() }
        // One item holding all three, not three items: separate items — and
        // a ToolbarItemGroup with the capsule off — lay out at the standard
        // ~44pt pitch and read as unrelated. Related actions on the Mac pack
        // into one control (Xcode's navigator switcher); this is that.
        if #available(macOS 26, *) {
            railActions.sharedBackgroundVisibility(.hidden)
        } else {
            railActions
        }
    }

    private var railActions: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 0) {
                Button {
                    chooseProjectFolder { path in
                        model.openSessions.newSessionDefaultAgent(projectPath: path)
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open a project folder…")
                Button {
                    // A hidden rail with search still open: the magnifier
                    // must reveal, not toggle — toggling closed the search the
                    // user was trying to reach and wiped their query.
                    if model.sidebarVisibility.isSidebarHidden || !searchOpen {
                        openSearch()
                    } else {
                        closeSearch()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search sessions")
                Button {
                    withAnimation { model.toggleSidebar() }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(model.sidebarVisibility.isSidebarHidden ? "Show Sidebar" : "Hide Sidebar")
            }
            // Toolbar-style hover pills on each button, without item padding:
            // ~36pt pitch against the ~44pt of separate items. The small
            // control size gets nearer Xcode's switcher but pins the glyphs
            // at 11pt and ignores an explicit font, so regular it is.
            .buttonStyle(.accessoryBar)
            .imageScale(.large)
        }
    }

    // MARK: Header

    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool

    /// The search field, shown under the title-bar band while search is open.
    /// It folds away when the field is empty and loses focus — nothing typed
    /// means nothing to keep.
    private var header: some View {
        searchField
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onChange(of: searchFocused) { _, focused in
                if !focused && model.searchText.isEmpty { closeSearch() }
            }
            .onChange(of: model.searchText) { _, text in
                // The palette (and the launch focus sweep) clear the query from
                // outside; the field should not stay unfolded over an empty
                // query it isn't editing.
                if text.isEmpty && !searchFocused { closeSearch() }
            }
    }

    private func openSearch() {
        let revealing = model.sidebarVisibility.isSidebarHidden
        withAnimation(.easeOut(duration: 0.15)) {
            searchOpen = true
            // The magnifier survives in the band when the sidebar is
            // collapsed; a search you cannot see is not open. Bring the
            // rail back with the field.
            if revealing { model.sidebarVisibility = .all }
        }
        // Take focus from a live terminal the same way every other field
        // does (FieldFocus): a plain focus assignment leaves the terminal
        // as first responder, and typing keeps reaching the agent. The
        // focus itself lands a turn later, once the field exists — or, when
        // the column is still sliding in, after it has: a claim on a field
        // inside a hidden split pane does not take, and an unfocused empty
        // field never triggers its own fold.
        if revealing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard searchOpen else { return }
                FieldFocus.claim { searchFocused = true }
            }
        } else {
            FieldFocus.claim { searchFocused = true }
        }
    }

    private func closeSearch() {
        model.searchText = ""
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.15)) { searchOpen = false }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onExitCommand { closeSearch() }
            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear and close search")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        // A fade only: a slide from the top edge would draw over the title
        // bar band, the very artifact the disclosure fix removed.
        .transition(.opacity)
    }

    // MARK: List

    /// A plain scroll of rows, not a `List`. The `.sidebar` List is an AppKit
    /// source list whose row height comes from the system "Sidebar icon size"
    /// through SwiftUI's own delegate — `defaultMinListRowHeight`,
    /// `controlSize` and the table's `rowHeight` were each tried and none
    /// moved a row. Owning the layout makes the row pitch ours to set, and
    /// retires the negative row insets that used to fight the List's indent.
    private var sessionList: some View {
        ScrollView(.vertical) {
            // A plain VStack, not Lazy: under `withAnimation`, a LazyVStack
            // animates children it re-creates from its own origin, so a
            // collapsing project's rows flew up over the header to the top
            // edge before they vanished. The rail is capped (projects and
            // rows per project), so laying every row out is cheap.
            VStack(alignment: .leading, spacing: 0) {
                if !model.pinnedSessions.isEmpty {
                    groupLabel("Pinned")
                    ForEach(model.pinnedSessions) { session in
                        SessionRow(session: session)
                            .padding(.leading, ProjectDisclosure.childInset)
                    }
                }

                // ONE displayProjects pass per body: every access refilters and
                // resorts all sessions, and this body re-runs on every publish.
                let allProjects = model.displayProjects
                let hidden = model.hiddenCount(allProjects)
                if allProjects.isEmpty && !model.isLoading {
                    Text(model.searchText.isEmpty ? "No sessions yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                let shown = showAllProjects ? allProjects : model.capped(allProjects)
                ForEach(shown) { project in
                    ProjectDisclosure(project: project, isFirst: project.id == shown.first?.id)
                }
                if model.searchText.isEmpty && hidden > 0 {
                    Button(showAllProjects
                           ? "Show fewer"
                           : "Show all projects (\(hidden) more)") {
                        showAllProjects.toggle()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        // With "Show scroll bars: Always" set in System Settings, AppKit gives
        // the scroll view a legacy scroller: a permanent ~15pt bar with a
        // track, running the full height beside every row. Setting
        // scrollerStyle on the NSScrollView does not stick (AppKit re-applies
        // the system style on layout), so the indicator is removed outright —
        // the sidebar is a short list you can see the extent of, not a
        // document you navigate by scroll position.
        .scrollIndicators(.never)
        .clipped()
        .background(SidebarScrollers())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    /// A group heading without a disclosure, in the project headers' language.
    private func groupLabel(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.leading, 4 + 12 + 6)   // the project label's column
        .padding(.trailing, 4)
        .frame(height: 28)
        .padding(.top, 12)
        // The List's Section used to announce this as a heading; the
        // stack has to say so itself.
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Footer

    /// A gear that opens a MENU — a bare gear button that jumped straight to
    /// a Settings tab read as broken (a gear promises choices). The menu pops
    /// UPWARD, right-aligned over the window: the gear sits in the window's
    /// bottom corner, and a default drop-down spilled outside the window.
    private var footer: some View {
        // One line. The bar earns its place as the edge the list stops at —
        // content scrolling clean off the window's bottom feels unfinished —
        // so it holds only what has to be always visible: the meters and the
        // gear. (A single-user app has nothing to say with an avatar.)
        HStack {
            UsageMeterView(usage: model.usage)
            Spacer()
            FooterGearMenu(model: model)
                .frame(width: 22, height: 22)
                .help("Settings and more")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 36)
    }
}

/// Compact subscription usage: one headline percentage per agent (the most
/// constrained window). Click for the full card — per-window severity bars —
/// which also refreshes. Renders NOTHING until a reader succeeds, so
/// machines without a subscription login never see it.
private struct UsageMeterView: View {
    @ObservedObject var usage: UsageMeterModel
    @State private var showingCard = false

    var body: some View {
        let claude = usage.claudeHeadlinePct
        let codex = usage.codexHeadlinePct
        // Numbers, or nothing. The footer is glanced at all day: a stale
        // number is easy to ignore, and anything that pulls the eye — a
        // glyph, a color — is not, least of all for something the user may
        // not be able to fix. What went wrong is in the card, opened on
        // purpose, and in the usage log file (UsageLog) for later.
        if claude != nil || codex != nil {
            HStack(spacing: 5) {
                if let claude {
                    HStack(spacing: 3) {
                        AgentBadge(agent: .claude, size: 10)
                        percent(claude)
                    }
                }
                if claude != nil && codex != nil {
                    Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                if let codex {
                    HStack(spacing: 3) {
                        AgentBadge(agent: .codex, size: 10)
                        percent(codex)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                usage.manualRefresh()   // the card should show fresh numbers
                showingCard = true
            }
            .help("Click to view the usage")
            .popover(isPresented: $showingCard, arrowEdge: .bottom) {
                UsageCard(usage: usage)
            }
        }
    }

    private func percent(_ pct: Int) -> some View {
        Text("\(pct)%")
            .font(.system(size: 11))
            .foregroundStyle(UsageSeverity.color(pct: Double(pct), resting: .secondary))
    }
}

/// ccmeter's severity bands: fine → orange at 80 → red at 95.
private enum UsageSeverity {
    static func color(pct: Double, resting: Color = .green) -> Color {
        if pct >= 95 { return .red }
        if pct >= 80 { return .orange }
        return resting
    }
}

/// The rich readout the tooltip could never be (tooltips are plain text):
/// a section per provider, a severity-colored bar per window.
private struct UsageCard: View {
    @ObservedObject var usage: UsageMeterModel
    @State private var spinDegrees = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Silence means live: the stale line appears only once the
            // reader has missed enough polls that the numbers can't be
            // trusted. Two definitive states are named at once, each with
            // its remedy: permission is one click away — the refresh control
            // is the one that may ask — and a rejected token needs a sign-in.
            let attention: String? = usage.claudeNeedsPermission
                ? "Temple needs permission to read the Claude Code sign-in. Refresh to allow."
                : usage.claudeSignInStale ? "Sign-in rejected. Run claude auth login." : nil
            if let claude = usage.claude {
                section(agent: .claude, name: "Claude", plan: claude.plan,
                        rows: claudeRows(claude),
                        footnote: attention.map { $0 + (usage.claudeUpdatedAt.map { " Read \(RelativeTime.string(from: $0))." } ?? "") }
                            ?? usage.claudeStaleSince.map {
                                "Couldn't refresh. Read \(RelativeTime.string(from: $0))."
                            },
                        showsRefresh: true,
                        footnoteWarns: attention != nil || usage.claudeStaleSince != nil)
            } else if let attention {
                // Started without figures: nothing to chart, still something to say.
                section(agent: .claude, name: "Claude", plan: nil, rows: [],
                        footnote: attention, showsRefresh: true, footnoteWarns: true)
            }
            let claudeShown = usage.claude != nil || attention != nil
            if claudeShown && usage.codex != nil {
                Divider()
            }
            if let codex = usage.codex {
                section(agent: .codex, name: "Codex", plan: codex.plan,
                        rows: codexRows(codex),
                        footnote: codex.capturedAt.map {
                            "As of the last Codex turn, \(RelativeTime.string(from: $0))"
                        },
                        showsRefresh: !claudeShown)
            }
        }
        .padding(16)
        .frame(width: 264)
    }

    /// The card's own refresh: the meter click already refreshes on the way
    /// in, but the card stays open while you watch a window drain. Lives IN
    /// the first section's header row, in the same trailing column as the
    /// percentages — an overlay can only eyeball that alignment; sharing the
    /// column makes it structural. The fetch usually finishes in
    /// milliseconds, so the arrow spins a full turn as the click's
    /// acknowledgment.
    private var refreshButton: some View {
        Button {
            // The one control that may raise a Keychain prompt: it is the
            // explicit ask, and the stale line it sits beside is what sent the
            // user here. Opening the card must not do this.
            usage.manualRefresh(retryingCredentials: true)
            withAnimation(.easeInOut(duration: 0.7)) { spinDegrees += 360 }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(spinDegrees))
                .frame(width: 18, height: 18, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Refresh now")
    }

    private func claudeRows(_ claude: ClaudeUsage) -> [(String, Double)] {
        var rows: [(String, Double)] = []
        if let window = claude.fiveHour { rows.append(("5-hour", window.pct)) }
        if let window = claude.weekly { rows.append(("Weekly", window.pct)) }
        for scope in claude.scoped { rows.append((scope.label, scope.pct)) }
        if let credits = claude.creditsPct { rows.append(("Credits", credits)) }
        return rows
    }

    private func codexRows(_ codex: CodexUsage) -> [(String, Double)] {
        var rows: [(String, Double)] = []
        if let window = codex.fiveHour { rows.append(("5-hour", window.pct)) }
        if let window = codex.weekly { rows.append(("Weekly", window.pct)) }
        return rows
    }

    @ViewBuilder
    private func section(agent: Agent, name: String, plan: String?,
                         rows: [(String, Double)], footnote: String?,
                         showsRefresh: Bool, footnoteWarns: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentBadge(agent: agent, size: 12)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                if let plan {
                    Text(plan.capitalized)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                if showsRefresh {
                    Spacer(minLength: 8)
                    refreshButton
                        .frame(width: 36, alignment: .trailing)
                }
            }
            ForEach(rows, id: \.0) { label, pct in
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                    UsageBar(pct: pct)
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(UsageSeverity.color(pct: pct, resting: .primary))
                        .frame(width: 36, alignment: .trailing)
                }
            }
            if let footnote {
                // Codex's as-of line is a fact about how its numbers work, so
                // it sits in tertiary with everything else that isn't asking
                // for attention. A failed refresh is not that: the rows above
                // it are wrong, and a note nobody reads is how this stayed
                // invisible in the first place.
                Text(footnote)
                    .font(.system(size: 10))
                    .foregroundStyle(footnoteWarns ? AnyShapeStyle(Color.orange)
                                                   : AnyShapeStyle(.tertiary))
            }
        }
    }
}

/// One window's fill against its cap — green until 80, orange until 95, red.
private struct UsageBar: View {
    let pct: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(UsageSeverity.color(pct: pct))
                    .frame(width: max(5, geo.size.width * min(pct, 100) / 100))
            }
        }
        .frame(height: 5)
    }
}

/// The footer gear: an AppKit button so its menu can pop UP-and-left from the
/// window's bottom corner (SwiftUI's Menu always drops down and happily
/// escapes the window). Anchoring the popup on its LAST item makes NSMenu
/// grow upward; the x offset right-aligns the menu with the gear.
private struct FooterGearMenu: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.popUp(_:))
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var model: AppModel

        init(model: AppModel) {
            self.model = model
        }

        @objc func popUp(_ sender: NSButton) {
            let menu = NSMenu()
            menu.addItem(item("Settings…", symbol: "gearshape", key: ",",
                              #selector(openSettings)))
            menu.addItem(item("Keyboard Shortcuts", symbol: "keyboard", key: "/",
                              #selector(openShortcuts)))
            menu.addItem(.separator())
            menu.addItem(item("About Temple", symbol: "info.circle", key: "",
                              #selector(openAbout)))
            // Anchor the LAST item just above the gear so the menu grows
            // upward, and shift left so its right edge meets the gear's.
            let anchor = NSPoint(x: sender.bounds.maxX - menu.size.width,
                                 y: sender.bounds.minY - 6)
            menu.popUp(positioning: menu.items.last, at: anchor, in: sender)
        }

        private func item(_ title: String, symbol: String?, key: String,
                          _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            return item
        }

        @objc private func openSettings() { model.openSessions.openSettings() }
        @objc private func openShortcuts() { model.toggleShortcuts() }
        @objc private func openAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    }
}

/// A project as a Codex-style disclosure group (default expanded) with a
/// per-project "Show more".
private struct ProjectDisclosure: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager
    let project: Project
    /// Only the dev-only fold hook reads this.
    var isFirst = false
    @State private var expanded = true
    @State private var headerHovering = false

    /// How many sessions this project currently shows. Grows a batch at a time —
    /// a project with 50+ sessions would otherwise dump all of them into the
    /// sidebar on one click, with no way back.
    @State private var limit = collapsedLimit

    private static let collapsedLimit = 6
    private static let batch = 10

    private var shownSessions: [AgentSession] {
        Array(project.sessions.prefix(limit))
    }

    private var hiddenCount: Int {
        max(0, project.sessions.count - limit)
    }

    /// Session rows indent one shallow step: the badge starts under the
    /// project label's first letter (header: 4pt padding + 12pt chevron column
    /// + 6pt gap = 22; row: this inset + its own 10pt padding), so the title
    /// sits one badge width inside the heading. Manual header + rows because
    /// DisclosureGroup's child outline indent is fixed and much deeper.
    static let childInset: CGFloat = 12

    /// Where a project dragged over THIS one would land: a line above the
    /// header (before) or under the last visible row (after). Read from the
    /// model's single slot so only one line exists in the whole rail.
    private var dropIndicator: Edge? {
        model.projectDropSlot?.path == project.path ? model.projectDropSlot?.edge : nil
    }
    @State private var headerHeight: CGFloat = 22

    private var hasFooterRow: Bool { hiddenCount > 0 || limit > Self.collapsedLimit }

    /// This project is the one being dragged: the whole group fades, not just
    /// its header — the thing in hand is the project.
    private var inHand: Bool { model.draggedProjectPath == project.path }

    var body: some View {
        header
        // The disclosure: rows leave the tree when collapsed — nothing is
        // built or laid out for a folded project — and the group clips, so
        // the reveal and the fold both happen inside the group's own box,
        // under its header. Departing rows keep their last frame while they
        // fade, and the shrinking clip swallows them from the bottom. (The
        // previous measure-then-frame approach kept collapsed rows alive at
        // zero height and painted one stale frame on every height change.)
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                rows
            }
        }
        .clipped()
        // Dev-only (WindowSnapshot): fold/unfold the first project so the
        // animation can be captured frame by frame without a click. Only the
        // first disclosure of a snapshot run subscribes; every other one gets
        // an empty publisher, so production pays nothing per project.
        .onReceive(WindowSnapshot.debugPublisher(for: .templeDebugToggleFirstProject, enabled: isFirst)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
    }

    @ViewBuilder
    private var rows: some View {
            ForEach(Array(shownSessions.enumerated()), id: \.element.id) { offset, session in
                SessionRow(session: session)
                    .padding(.leading, Self.childInset)
                    .opacity(inHand ? 0.4 : 1)
                    .transition(.opacity)
                    .onDrop(of: [Self.dragType], delegate: dropDelegate(row: session.id, edge: .bottom))
                    .overlay(alignment: .bottom) {
                        if dropIndicator == .bottom, !hasFooterRow, offset == shownSessions.count - 1 {
                            dropLine
                        }
                    }
            }
            if hasFooterRow {
                HStack(spacing: 10) {
                    if hiddenCount > 0 {
                        // The count is the whole label: it says how deep the
                        // project goes, so a click on a 53-session project is
                        // no surprise. Each click reveals one batch.
                        expandButton("Show \(hiddenCount) more") { limit += Self.batch }
                    }
                    if limit > Self.collapsedLimit {
                        expandButton("Show fewer") { limit = Self.collapsedLimit }
                    }
                }
                // Starts on the session title column, under the row text — a
                // continuation of the list, not a control of its own. Spans
                // the row so it drops (and draws its insertion line) across
                // the same width as a session row, not just under the button.
                .padding(.leading, Self.childInset + 31)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(inHand ? 0.4 : 1)
                .transition(.opacity)
                .onDrop(of: [Self.dragType], delegate: dropDelegate(row: "footer", edge: .bottom))
                .overlay(alignment: .bottom) {
                    if dropIndicator == .bottom { dropLine }
                }
            }
    }

    // MARK: Drag to reorder

    /// The drag payload is a private, in-process type — never plain text — so a
    /// drop that misses the rail cannot paste a path into a live terminal.
    static let dragType = UTType(exportedAs: "com.sriramb.temple.project-order")

    /// The insertion line: where the dragged project will land if released now.
    private var dropLine: some View {
        Capsule()
            .fill(Palette.accent)
            .frame(height: 2)
            .padding(.horizontal, 6)
    }

    /// `edge` is where a drop on this row lands the project: `.top` = before
    /// this project, `.bottom` = after it. nil lets the header decide by which
    /// half the pointer is in — the collapsed case, where the header is the
    /// only row this project has.
    private func dropDelegate(row: String, edge: Edge?) -> ProjectDropDelegate {
        ProjectDropDelegate(model: model, target: project.path, row: "\(project.path)#\(row)") { point in
            edge ?? (point.y < headerHeight / 2 ? .top : .bottom)
        }
    }

    /// Right-click a project header: the folder itself (the session row has its
    /// copies/reveal group; this is the project's), then put it away. Reordering
    /// is a drag — the header is the handle — so there are no Move items.
    @ViewBuilder
    private var headerContextMenu: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        if hasOpenTabs {
            // Named rather than merely greyed out, like the session row's item.
            Button("Close tabs to archive") {}
                .disabled(true)
        } else {
            Button("Archive project") {
                model.archiveProject(project.path, undoManager: undoManager)
            }
        }
    }

    private var hasOpenTabs: Bool {
        model.openSessions.tabs.contains { $0.kind == .session && $0.projectPath == project.path }
    }

    private func expandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .frame(height: 26)
    }

    private var header: some View {
        headerLabel
        // The group in hand fades: the chip under the pointer is the project
        // now, and the gap it leaves is where it came from.
        .opacity(inHand ? 0.4 : 1)
        .padding(.horizontal, 4)
        // The gap between groups belongs to the header — inside its hit
        // shape, its drop target and its measured height — so a project
        // dragged down the rail never crosses a dead band where the
        // insertion line blinks off. It also puts the "before this project"
        // line in the gap, where an insertion between groups reads right.
        .padding(.top, 12)
        // No hover pill: a filled pill under a rule-style heading fought the
        // rule. Hover shows the `+`; the label's tone lifts a step instead.
        .animation(.easeOut(duration: 0.12), value: headerHovering)
        // Whole row toggles the disclosure (name, icon, empty space) —
        // matching the chevron. The `+` overlay keeps its own action.
        .contentShape(Rectangle())
        .onHover { headerHovering = $0 }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
        .contextMenu { headerContextMenu }
        .overlay(alignment: .trailing) {
            // Quiet until the pointer is on the row, like Finder's "Hide".
            NewSessionMenu(projectPath: project.path)
                .opacity(headerHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: headerHovering)
        }
        // The header is the drag handle. Dropping on a header lands the
        // dragged project above it; when this project is collapsed, the lower
        // half of the header means below it instead (it has no body to drop on).
        .background(GeometryReader { geo in
            Color.clear.onAppear { headerHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, height in headerHeight = height }
        })
        .onDrag {
            model.beginProjectDrag(project.path)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.dragType.identifier, visibility: .ownProcess
            ) { completion in
                completion(Data(project.path.utf8), nil)
                return nil
            }
            return provider
        } preview: {
            // What follows the pointer. The default preview snapshots the whole
            // row — and with a flexible rule inside, sizes to nothing, so the
            // drag was invisible. A chip of its own, set like the header it
            // was lifted from, so the thing in hand looks like what you picked up.
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.panelBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairline))
            .fixedSize()
        }
        .onDrop(of: [Self.dragType], delegate: dropDelegate(row: "header", edge: expanded ? .top : nil))
        .overlay(alignment: .top) {
            if dropIndicator == .top { dropLine }
        }
        .overlay(alignment: .bottom) {
            if dropIndicator == .bottom, !expanded { dropLine }
        }
    }

    /// The group heading, in the launcher's section language: an uppercase,
    /// letter-spaced label trailed by a hairline rule — one vocabulary across
    /// the rail and the home pane. A small chevron leads it and rotates with
    /// the disclosure. No folder glyph: every entry here is a folder.
    private var headerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
            // Hand-rolled, not Label(_, systemImage:): a Label picks up the
            // sidebar label style, which dims with window key-state — making
            // project titles the ONLY thing in the app that reacts to focus
            // changes. Plain Text renders like the session rows and holds.
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.leading, 4)
                // The `+` lands over the rule's end on hover; leave it room.
                .padding(.trailing, headerHovering ? 22 : 0)
        }
        .frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }
}

/// One row of a project, as a drop target for another project's header. Every
/// row writes the model's single drop slot, so the insertion line appears
/// exactly once, on the edge the drop would use.
private struct ProjectDropDelegate: DropDelegate {
    let model: AppModel
    let target: String
    /// This row's identity, distinct from every other row of the same project.
    let row: String
    /// Which edge a pointer at this location (row coordinates) means.
    let edge: (CGPoint) -> Edge

    /// Called on every pointer move; the whole rail re-renders on a publish,
    /// so write only when the slot actually changes.
    private func show(_ info: DropInfo) {
        // No drag in flight (the drop already landed) — a straggling update
        // must not resurrect the line the drop just cleared.
        guard model.draggedProjectPath != nil else { return }
        let slot = AppModel.ProjectDropSlot(path: target, edge: edge(info.location))
        model.projectDropOwner = row
        if model.projectDropSlot != slot { model.projectDropSlot = slot }
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ProjectDisclosure.dragType])
            && model.draggedProjectPath != nil
            && model.draggedProjectPath != target
    }

    func dropEntered(info: DropInfo) { show(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        show(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Only clear our own line: entering the next row — including another
        // row of this same project — may already have claimed the slot, and
        // the exit for this one can arrive after that.
        guard model.projectDropOwner == row else { return }
        model.projectDropOwner = nil
        model.projectDropSlot = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let path = model.draggedProjectPath else { return false }
        model.endProjectDrag()
        // Updates queued before the mouse-up can land after this returns.
        DispatchQueue.main.async { model.endProjectDrag() }
        switch edge(info.location) {
        case .top: model.moveProject(path, before: target)
        default: model.moveProject(path, after: target)
        }
        return true
    }
}

/// The right-aligned `+` on a project row → an agent picker for THAT project
/// (UX §New session, per-project entry; rows in `NewSessionMenuItems`). Quiet
/// until hover; monochrome. Its own click target so it never toggles the
/// disclosure.
private struct NewSessionMenu: View {
    @EnvironmentObject var model: AppModel
    let projectPath: String
    @State private var hovering = false

    var body: some View {
        Menu {
            NewSessionMenuItems(projectPath: projectPath)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New session in \(model.projectName(projectPath))")
    }
}
