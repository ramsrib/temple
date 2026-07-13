import SwiftUI
import TempleCore

/// The Settings tab (U9): app-level, project-agnostic, no surface. Font/theme
/// changes propagate live to open terminals via `AppModel.applyAppearance()`.
///
/// Layout: a single centered column of grouped "cards" (macOS System Settings /
/// Linear feel) — a section label above each card, hairline-divided rows inside,
/// label + optional hint on the left, right-aligned control on the right.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    private var settings: SettingsStore { model.settings }

    /// Fixed leading label column so every control lines up across cards.
    private let labelColumn: CGFloat = 168

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                card("Terminal") {
                    settingRow("Font size") {
                        HStack(spacing: 12) {
                            Slider(value: Binding(get: { settings.fontSize },
                                                  set: { settings.fontSize = $0 }),
                                   in: 9...24, step: 1)
                            .frame(maxWidth: 220)
                            Text("\(Int(settings.fontSize)) pt")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    divider
                    settingRow("Font family") {
                        TextField("SF Mono", text: Binding(get: { settings.fontFamily },
                                                           set: { settings.fontFamily = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    }
                }

                card("Agents") {
                    settingRow("Default agent",
                               hint: "Used by ⌘T and new-session rows.") {
                        Picker("", selection: Binding(get: { settings.defaultAgent },
                                                      set: { settings.defaultAgent = $0 })) {
                            ForEach(Agent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }

                agentCard(.claude)
                agentCard(.codex)

                card("Appearance") {
                    settingRow("Theme") {
                        Picker("", selection: Binding(get: { settings.theme },
                                                      set: { settings.theme = $0 })) {
                            ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)   // center the column
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 40)
        }
        .thinScrollers()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Agents

    /// One agent's card: what Temple detected, everything else it found and why it
    /// won't use it, and the override for when the user disagrees.
    ///
    /// Detection is shown rather than hidden on purpose. The failure that led here
    /// — a stale `claude` from an old npm install, shadowing a current one — was
    /// invisible precisely because Temple picked a binary silently and no screen
    /// ever said which.
    private func agentCard(_ agent: Agent) -> some View {
        let resolution = model.toolchain.resolution(for: agent)
        let override = settings.overridePath(for: agent)
        let check = model.toolchain.overrideCheck(for: agent)
        return card(agent.displayName) {
            settingRow("Command",
                       hint: "Leave blank to use the detected one.") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField(resolution?.chosen?.path ?? agent.binaryName,
                              text: Binding(get: { settings.overridePath(for: agent) },
                                            set: { settings.setOverridePath($0, for: agent) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.toolchain.recheckUserSettings() }
                    // Your override runs, or it doesn't — either way you hear it
                    // from Settings, not from a tab that dies on launch.
                    if let check {
                        Label(check.failure ?? check.version ?? "runs",
                              systemImage: check.isUsable ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(check.isUsable ? Color.secondary : Color.red)
                        .lineLimit(2)
                        .help(check.details ?? "")
                    }
                }
                .frame(maxWidth: 300)
            }
            divider
            settingRow("Detected",
                       hint: override.isEmpty ? nil : "Overridden above — detection ignored.") {
                detectionStatus(resolution)
                    .opacity(override.isEmpty ? 1 : 0.45)
            }
            if let resolution, resolution.installs.count > 1 || resolution.installs.contains(where: { !$0.isUsable }) {
                divider
                settingRow("Also found") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(resolution.installs.filter { $0.path != resolution.chosen?.path }) { install in
                            installRow(install)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .trailing)
                }
            }
            divider
            settingRow("Arguments",
                       hint: "Passed to every launch (new + resume). Clear to disable.") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("", text: Binding(get: { settings.extraArgsText(for: agent) },
                                                set: { settings.setExtraArgsText($0, for: agent) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.toolchain.recheckUserSettings() }
                    // Only ever shown when the CLI *objected*. Silence here is not
                    // approval — `claude --version` ignores unknown flags entirely
                    // — so there is deliberately no "arguments OK" tick to trust.
                    if let complaint = model.toolchain.argumentComplaint(for: agent) {
                        Label(complaint.failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red)
                            .lineLimit(2)
                            .help(complaint.details ?? "")
                    }
                }
                .frame(maxWidth: 300)
            }
        }
    }

    @ViewBuilder
    private func detectionStatus(_ resolution: ToolchainResolution?) -> some View {
        HStack(spacing: 8) {
            if model.toolchain.isDetecting && resolution == nil {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let chosen = resolution?.chosen {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(chosen.path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                    if let version = chosen.version {
                        Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(resolution?.problem ?? "Not found")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                model.toolchain.detect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.toolchain.isDetecting)
            .help("Check again")
        }
        .frame(maxWidth: 300, alignment: .trailing)
    }

    /// A rejected (or merely unused) install — with the reason, because "we didn't
    /// pick this one" is useless without it.
    private func installRow(_ install: AgentInstall) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: install.isUsable ? "circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(install.isUsable ? Color.secondary : .orange)
                Text(install.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
            }
            Text(install.failure ?? install.version ?? "")
                .font(.system(size: 10))
                .foregroundStyle(install.isUsable ? Color.secondary : Color.orange)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .help(install.details ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold))
            Text("Preferences apply live to open terminals.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    // MARK: Building blocks

    /// A titled card: uppercase section label above a hairline-bordered,
    /// faint-filled group of rows.
    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Palette.surfaceFill, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
        }
    }

    /// A hairline divider between rows inside a card (inset from the edges).
    private var divider: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    /// One settings row: fixed-width label (with optional hint below) on the
    /// left, right-aligned control on the right, consistent vertical rhythm.
    private func settingRow<Content: View>(_ label: String,
                                           hint: String? = nil,
                                           @ViewBuilder control: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: labelColumn, alignment: .leading)

            Spacer(minLength: 12)

            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
