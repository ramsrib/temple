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
                    divider
                    settingRow("Claude binary",
                               hint: "Absolute path — auto-detected if left as the default.") {
                        TextField("claude", text: Binding(get: { settings.claudePath },
                                                          set: { settings.claudePath = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 300)
                    }
                    divider
                    settingRow("Codex binary",
                               hint: "Absolute path — auto-detected if left as the default.") {
                        TextField("codex", text: Binding(get: { settings.codexPath },
                                                         set: { settings.codexPath = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 300)
                    }
                    divider
                    settingRow("Claude arguments",
                               hint: "Passed to every Claude launch (new + resume). Clear to disable.") {
                        TextField("", text: Binding(get: { settings.claudeExtraArgs },
                                                    set: { settings.claudeExtraArgs = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 300)
                    }
                    divider
                    settingRow("Codex arguments",
                               hint: "Passed to every Codex launch (new + resume). Clear to disable.") {
                        TextField("", text: Binding(get: { settings.codexExtraArgs },
                                                    set: { settings.codexExtraArgs = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 300)
                    }
                }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
