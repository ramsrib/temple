import SwiftUI
import TempleCore

/// The Settings tab (U9): app-level, project-agnostic, no surface. Font/theme
/// changes propagate live to open terminals via `AppModel.applyAppearance()`.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    private var settings: SettingsStore { model.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold))

                section("Terminal") {
                    row("Font size") {
                        HStack(spacing: 10) {
                            Slider(value: Binding(get: { settings.fontSize },
                                                  set: { settings.fontSize = $0 }),
                                   in: 9...24, step: 1)
                            .frame(width: 180)
                            Text("\(Int(settings.fontSize)) pt")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    row("Font family") {
                        TextField("SF Mono", text: Binding(get: { settings.fontFamily },
                                                           set: { settings.fontFamily = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    }
                }

                section("Agents") {
                    row("Default agent") {
                        Picker("", selection: Binding(get: { settings.defaultAgent },
                                                      set: { settings.defaultAgent = $0 })) {
                            ForEach(Agent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    row("Claude binary") {
                        TextField("claude", text: Binding(get: { settings.claudePath },
                                                          set: { settings.claudePath = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    }
                    row("Codex binary") {
                        TextField("codex", text: Binding(get: { settings.codexPath },
                                                         set: { settings.codexPath = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                    }
                }

                section("Appearance") {
                    row("Theme") {
                        Picker("", selection: Binding(get: { settings.theme },
                                                      set: { settings.theme = $0 })) {
                            ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 120, alignment: .leading)
            content()
            Spacer()
        }
    }
}
