import SwiftUI
import TempleCore

/// The Settings tab: a page-style sibling of History, built from the same
/// parts as the sidebar, launcher and History — section rules, plain rows,
/// hairlines, agent badges, and the CLI's own words wherever something failed.
///
/// Agents first, because the two surfaces that send people here (the
/// launcher's toolchain banner and a tab's launch-failure header) are about an
/// agent; Appearance last.
///
/// Text fields edit a draft (`SettingsDrafts`) and commit on Return or when
/// focus leaves them; Esc reverts. Nothing re-probes or re-applies the terminal
/// appearance while typing.
///
/// Layout rules (AGENTS.md, the split view's titlebar inset): no `.fixedSize`,
/// `.allowsHitTesting`, `layoutPriority`, `List` or `Form` anywhere here. Text
/// wraps with an expanding frame.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    /// Observed here, not through `AppModel`: a committed field re-renders this
    /// page, not the window (see AppModel's settings subscriptions).
    @ObservedObject var settings: SettingsStore

    @State private var drafts = SettingsDrafts()
    @FocusState private var focused: SettingsField?
    /// The agent whose Command row is washed after a deep link.
    @State private var washed: Agent?
    @State private var fontVerdict: FontFamilyVerdict?
    /// The page's width, for the column (`pageColumn`, shared with History).
    @State private var width: CGFloat = 1000

    static let labelColumn: CGFloat = 168
    static let formWidth: CGFloat = 720
    static let fieldWidth: CGFloat = 420

    private enum Anchor: Hashable {
        case top
        case agent(Agent)
    }

    private var toolchain: ToolchainModel { model.toolchain }
    private var editor: SettingsEditor { SettingsEditor(store: settings, toolchain: model.toolchain) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.top, PageChrome.top)
                        .id(Anchor.top)
                    agentsSection
                    agentSection(.claude)
                    agentSection(.codex)
                    appearanceSection
                }
                .frame(maxWidth: Self.formWidth, alignment: .leading)
                .padding(.bottom, 40)
                // History's column, placed from the same page width, so the
                // two sibling tabs put their titles at the same x.
                .pageColumn(pageWidth: width)
            }
            .thinScrollers()
            .onAppear { land(proxy) }
            .onChange(of: model.openSessions.settingsFocus) { land(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .measuringPageWidth($width)
        // Leaving a field (click elsewhere, Tab) commits it.
        .onChange(of: focused) { old, new in
            if let old, old != new { commit(old) }
        }
        // Leaving the page is leaving the field.
        .onDisappear { commitAll() }
        .task(id: settings.fontFamily) {
            fontVerdict = FontFamilyCheck.verdict(for: settings.fontFamily)
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(title: "Settings", subtitle: subtitle) { checkedLine }
    }

    /// What Temple will launch for each agent: the page's answer in one line.
    private var subtitle: Text {
        guard let parts = toolchain.summary() else { return Text("Checking agents…") }
        return parts.enumerated().reduce(Text("")) { text, entry in
            let (index, part) = entry
            let piece = part.state == .broken
                ? Text(part.text).foregroundColor(.red)
                : Text(part.text)
            return index == 0 ? piece : text + Text(" · ") + piece
        }
    }

    /// "Checked 2 min ago · Check again ⌘R", or the scheduled retry while one
    /// is pending, so a verdict that changes by itself is seen to.
    private var checkedLine: some View {
        TimelineView(.periodic(from: .now, by: toolchain.nextRetryAt == nil ? 30 : 1)) { context in
            HStack(spacing: 4) {
                if toolchain.isDetecting {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                } else {
                    if let last = toolchain.lastChecked {
                        Text("Checked \(PageChrome.relative(last, now: context.date))")
                        Text("·")
                    }
                    if let next = toolchain.nextRetryAt {
                        Text("Checking again in \(max(1, Int(next.timeIntervalSince(context.date).rounded(.up))))s")
                    } else {
                        Button("Check again") { toolchain.detect() }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text("⌘R").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: Agents

    private var agentsSection: some View {
        section {
            SectionRule("Agents")
        } rows: {
            row("Default agent") {
                FlatSegmentedPicker(selection: Binding(get: { settings.defaultAgent },
                                                       set: { settings.defaultAgent = $0 }),
                                    options: Agent.allCases, label: { $0.displayName }, width: 220)
                hint("Started by ⌘T, folder launches and recent projects.")
            }
        }
    }

    /// One agent: what Temple will launch, answered in three rows.
    ///
    /// Detection is shown rather than hidden on purpose. The failure that led
    /// here — a stale `claude` from an old npm install, shadowing a current
    /// one — was invisible precisely because Temple picked a binary silently
    /// and no screen ever said which.
    private func agentSection(_ agent: Agent) -> some View {
        let overridden = !settings.overridePath(for: agent).isEmpty
        return section {
            SectionRule(agent.displayName) { AgentBadge(agent: agent, size: 12) }
        } rows: {
            row("Command") { commandControl(agent) }
                .background(alignment: .center) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.selectionFill)
                        .padding(.horizontal, -10)
                        .opacity(washed == agent ? 1 : 0)
                }
            divider
            row("Detected", note: overridden ? "Not used while a command is set." : nil) {
                detected(agent)
                    .opacity(overridden ? 0.45 : 1)
            }
            divider
            row("Arguments") { argumentsControl(agent) }
        }
        .id(Anchor.agent(agent))
    }

    // MARK: Command

    @ViewBuilder
    private func commandControl(_ agent: Agent) -> some View {
        let field = SettingsField.command(agent)
        let placeholder = toolchain.resolution(for: agent)?.chosen.map { Self.tilde($0.path) } ?? agent.binaryName
        textField(field, placeholder: placeholder, monospaced: true, clearable: true)
            .frame(maxWidth: Self.fieldWidth, alignment: .leading)

        if drafts.isEdited(field) {
            // The model's own rule made visible: a verdict belongs to the path
            // it was made about, so a draft gets none.
            quiet(text(field).isEmpty ? "Press Return to use the detected one" : "Press Return to check")
        } else if let verdict = toolchain.overrideVerdict(for: agent) {
            overrideVerdict(verdict, path: settings.overridePath(for: agent))
        } else {
            hint("Leave empty to use the one Temple detects.")
        }
    }

    @ViewBuilder
    private func overrideVerdict(_ verdict: OverrideVerdict, path: String) -> some View {
        switch verdict {
        case .checking:
            checking
        case .runs(let version):
            hint(["Runs", AgentInstall.versionNumber(in: version)].compactMap { $0 }.joined(separator: " · "))
                .help(version ?? "")
        case .doesNotRun(let failure, let details):
            problem("Doesn't run · \(failure)", color: .red, outputTitle: path, output: details)
            hint("Temple will still launch it. Clear the field to use the detected one.", top: 3)
        case .couldNotLaunch(let reason, let details):
            problem("Couldn't be launched · \(reason)", color: .red, outputTitle: path, output: details)
            hint("Temple will still launch it. Clear the field to use the detected one.", top: 3)
        }
    }

    // MARK: Detected

    @ViewBuilder
    private func detected(_ agent: Agent) -> some View {
        if let resolution = toolchain.resolution(for: agent) {
            VStack(alignment: .leading, spacing: 9) {
                if resolution.installs.isEmpty {
                    sectionLine("No \(agent.binaryName) on your PATH.")
                    Text("Install \(agent.displayName), or set its path above.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if resolution.chosen == nil {
                        sectionLine("Every \(agent.binaryName) on this Mac fails to run.")
                    }
                    // The shell's order, the winner marked rather than moved:
                    // the order *is* the information.
                    ForEach(resolution.installs) { install in
                        installLine(install, in: resolution)
                    }
                }
            }
            .padding(.top, 5)
        } else {
            // First launch: nothing landed yet. (A later Check again keeps the
            // old list; the header's trailing line shows the spinner.)
            checking.padding(.top, 0)
        }
    }

    private func sectionLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            warningGlyph
            Text(text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.red)
    }

    private func installLine(_ install: AgentInstall, in resolution: ToolchainResolution) -> some View {
        let chosen = install.path == resolution.chosen?.path
        let shadowed = resolution.shadowedFailures.contains { $0.path == install.path }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !install.isUsable {
                    warningGlyph.foregroundStyle(Color.orange)
                }
                Text(Self.tilde(install.path))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(install.path)
                if install.isUsable, let version = install.version {
                    // The number; the CLI's whole line is the tooltip.
                    Text(install.versionNumber ?? version)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(version)
                }
                Spacer(minLength: 8)
                Text(status(of: install, chosen: chosen))
                    .font(.system(size: 11, weight: chosen ? .medium : .regular))
                    .foregroundStyle(chosen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            if let failure = install.failure {
                VStack(alignment: .leading, spacing: 3) {
                    problem(failure, color: .orange, glyph: false, outputTitle: install.path, output: install.details,
                            top: 0)
                    if shadowed {
                        Text("Ahead on your PATH, so a plain terminal still gets this one.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 21)
            } else if chosen, !install.isOnPATH {
                Text("Not on the PATH your shell gives Temple; found in a usual place.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func status(of install: AgentInstall, chosen: Bool) -> String {
        if chosen { return "Temple uses this" }
        if !install.isUsable { return "Skipped" }
        return install.isOnPATH ? "Later on PATH" : "Not on PATH"
    }

    // MARK: Arguments

    @ViewBuilder
    private func argumentsControl(_ agent: Agent) -> some View {
        let field = SettingsField.arguments(agent)
        textField(field, placeholder: "", monospaced: true)
            .frame(maxWidth: Self.fieldWidth, alignment: .leading)

        if drafts.isEdited(field) {
            // A complaint is keyed to the exact arguments it was about, so a
            // draft drops it rather than leaving it standing.
            quiet("Press Return to apply")
        } else {
            // Only ever an objection. Silence is not approval — `claude
            // --bogus --version` exits 0 — so there is deliberately no state
            // here that could read as "arguments OK".
            if let complaint = toolchain.argumentComplaint(for: agent) {
                problem("\(agent.binaryName) rejects these · \(complaint.failure)", color: .red,
                        outputTitle: complaint.binary, output: complaint.details)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(settings.extraArgsText(for: agent).trimmingCharacters(in: .whitespaces).isEmpty
                     ? "No extra flags."
                     : "Added to every launch, new and resumed.")
                    .foregroundStyle(.secondary)
                if !settings.extraArgsAreShipped(for: agent) {
                    linkButton("Reset to default") { editor.resetArguments(agent, drafts: &drafts) }
                        .help(SettingsStore.shippedExtraArgs(for: agent))
                }
            }
            .font(.system(size: 11))
            .padding(.top, 6)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        section {
            SectionRule("Appearance")
        } rows: {
            row("Theme") {
                FlatSegmentedPicker(selection: Binding(get: { settings.theme },
                                                       set: { settings.theme = $0 }),
                                    options: ThemePreference.allCases, label: { $0.label }, width: 240)
            }
            divider
            row("Terminal font") { fontControl }
        }
    }

    @ViewBuilder
    private var fontControl: some View {
        HStack(spacing: 8) {
            textField(.fontFamily, placeholder: "JetBrains Mono (built in)", monospaced: false)
                .frame(maxWidth: 240, alignment: .leading)
            textField(.fontSize, placeholder: String(Int(SettingsStore.shippedFontSize)), monospaced: false,
                      centered: true)
                .frame(width: 44)
                // Up/down arrows step the size like the chevrons.
                .onKeyPress(.upArrow) { stepFontSize(by: 1); return .handled }
                .onKeyPress(.downArrow) { stepFontSize(by: -1); return .handled }
            Text("pt")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            // Two bare chevrons, not a Stepper: the native one was the only
            // bezeled control on a flat page. Applies per click, in 1pt steps.
            VStack(spacing: 0) {
                FontSizeChevron(systemName: "chevron.up", help: "Larger") { stepFontSize(by: 1) }
                FontSizeChevron(systemName: "chevron.down", help: "Smaller") { stepFontSize(by: -1) }
            }
        }
        if drafts.isEdited(.fontFamily) || drafts.isEdited(.fontSize) {
            quiet("Press Return to apply")
        } else if fontVerdict == .notInstalled {
            fontNotInstalled
        } else if focused == .fontFamily || focused == .fontSize {
            // Only while there is something to press Return in.
            hint("Applies to open terminals when you press Return.", top: 6)
        }
    }

    /// The detected layer applied to the font field: say what was found, and
    /// the terminal's fallback by name. A family typed this launch is flagged;
    /// one carried over from before (the old "SF Mono" default) is stated,
    /// quietly, with the way back: it is not something the user just did.
    @ViewBuilder
    private var fontNotInstalled: some View {
        let family = settings.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = "\(family) isn't installed, so the terminal uses JetBrains Mono (built in)."
        if settings.fontFamilyChosenThisLaunch {
            problem(sentence, color: .orange, outputTitle: nil, output: nil)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sentence)
                    .foregroundStyle(.secondary)
                linkButton("Use built in") {
                    drafts.revert(.fontFamily)
                    settings.resetFontFamily()
                }
            }
            .font(.system(size: 11))
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stepFontSize(by delta: Double) {
        drafts.revert(.fontSize)
        let size = settings.fontSize + delta
        guard SettingsEditor.fontSizeRange.contains(size) else { return }
        settings.fontSize = size
    }

    // MARK: Fields

    private func text(_ field: SettingsField) -> String {
        drafts.text(field, committed: editor.committed(field))
    }

    /// Temple's own field: the sidebar search field's shape, a graphite ring
    /// when focused.
    private func textField(_ field: SettingsField, placeholder: String, monospaced: Bool,
                           clearable: Bool = false, centered: Bool = false) -> some View {
        let binding = Binding(get: { text(field) },
                              set: { drafts.edit(field, to: $0, committed: editor.committed(field)) })
        return HStack(spacing: 6) {
            TextField("", text: binding, prompt: answersPlaceholder(field) ? nil : Text(placeholder))
                .textFieldStyle(.plain)
                .multilineTextAlignment(centered ? .center : .leading)
                // A Command field's placeholder is the detected path, an
                // answer rather than a hint, so it reads at secondary. A
                // prompt's own color is not honoured by the plain field (it
                // drew at the faint default either way), so the text sits
                // behind the transparent field instead; clicks still land in
                // the field.
                .background(alignment: .leading) {
                    if answersPlaceholder(field), binding.wrappedValue.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .font(monospaced ? .system(size: 12, design: .monospaced)
                                 : .system(size: field == .fontSize ? 12 : 13).monospacedDigit())
                .focused($focused, equals: field)
                .onSubmit { commit(field) }
                .onExitCommand { drafts.revert(field) }
            if clearable, !binding.wrappedValue.isEmpty {
                Button {
                    // Back to detection is the common exit: empty and commit
                    // in one click.
                    drafts.revert(field)
                    editor.write(field, "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear — use the one Temple detects")
            }
        }
        .padding(.leading, centered ? 6 : 9)
        .padding(.trailing, centered ? 6 : 8)
        .frame(height: 28)
        .background(Palette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 2)
                .padding(-2)
                .opacity(focused == field ? 1 : 0)
        }
    }

    /// Whether the field's placeholder is what Temple will use (the detected
    /// path) rather than a hint, and so reads at secondary.
    private func answersPlaceholder(_ field: SettingsField) -> Bool {
        if case .command = field { return true }
        return false
    }

    private func commit(_ field: SettingsField) {
        editor.commit(field, drafts: &drafts)
    }

    private func commitAll() {
        for field in [SettingsField.command(.claude), .arguments(.claude), .command(.codex), .arguments(.codex),
                      .fontFamily, .fontSize] {
            commit(field)
        }
    }

    // MARK: Deep link

    /// Land where the warning that sent us here points: that agent's section
    /// at the top, its Command row washed for a moment.
    private func land(_ proxy: ScrollViewProxy) {
        guard let request = model.openSessions.settingsFocus else { return }
        model.openSessions.consumeSettingsFocus(request)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(request.agent.map(Anchor.agent) ?? .top, anchor: .top)
            }
            guard let agent = request.agent else { return }
            washed = agent
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard washed == agent else { return }
                withAnimation(.easeOut(duration: 0.45)) { washed = nil }
            }
        }
    }

    // MARK: Building blocks

    private func section<Rule: View, Rows: View>(@ViewBuilder rule: () -> Rule,
                                                 @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rule()
            rows()
        }
        .padding(.top, 26)
    }

    /// One row: a 168pt label column, then the control column.
    private func row<Control: View>(_ label: String, note: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 5)
            .frame(width: Self.labelColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                control()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
    }

    private func hint(_ text: String, top: CGFloat = 6) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, top)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The transient "Press Return to…" line.
    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checking: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Checking…")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private var warningGlyph: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
    }

    /// A failure in someone else's words — the CLI's or the OS's — with the
    /// raw output one click away. Red when every launch fails, orange when
    /// Temple worked around it (the launcher banner's rule).
    private func problem(_ text: String, color: Color, glyph: Bool = true,
                         outputTitle: String?, output: String?, top: CGFloat = 6) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if glyph { warningGlyph }
            Text(text)
                .lineLimit(2)
                .textSelection(.enabled)
            if let output, !output.isEmpty {
                ShowOutputLink(title: outputTitle, output: output)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(color)
        .padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
    }

    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// "Show output": the CLI's raw output in a popover — selectable and copyable,
/// which a tooltip never was. Same popover for an override, a skipped install
/// and an argument complaint.
private struct ShowOutputLink: View {
    let title: String?
    let output: String
    @State private var presented = false

    var body: some View {
        Button("Show output") { presented.toggle() }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                OutputPopover(title: title, output: output)
            }
    }
}

private struct OutputPopover: View {
    let title: String?
    let output: String

    /// ~12 lines, then it scrolls.
    private var height: CGFloat {
        let wrapped = output.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 64).rounded(.up))) }
        return min(CGFloat(wrapped) * 15 + 4, 184)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let title {
                    Text(SettingsView.tilde(title))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(title)
                }
                Spacer(minLength: 8)
                Button("Copy") { copyToPasteboard(output) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
        }
        .padding(12)
        .frame(width: 460)
    }
}

/// One of the font size's stacked chevrons: 9pt, tertiary, secondary on hover.
private struct FontSizeChevron: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
