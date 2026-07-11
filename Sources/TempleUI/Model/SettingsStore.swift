import SwiftUI
import TempleCore
import TempleTerminalAPI

/// Theme mode (U10): System follows macOS live; Light/Dark override.
public enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    /// SwiftUI override; `nil` = follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    /// AppKit override for `NSApp.appearance`; `nil` = follow the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// User settings, surfaced in the Settings tab (U9) and persisted to
/// `UserDefaults`.
///
/// **Seam for Track C5.** Swap the `UserDefaults` backing for the DB later; the
/// published API is stable.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var fontSize: Double { didSet { persist() } }
    @Published public var fontFamily: String { didSet { persist() } }
    @Published public var defaultAgent: Agent { didSet { persist() } }
    @Published public var theme: ThemePreference { didSet { persist() } }
    @Published public var claudePath: String { didSet { persist() } }
    @Published public var codexPath: String { didSet { persist() } }
    /// Extra CLI arguments appended to every launch (new + resume).
    @Published public var claudeExtraArgs: String { didSet { persist() } }
    @Published public var codexExtraArgs: String { didSet { persist() } }

    private let defaults: UserDefaults
    private var loading = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 13
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? "SF Mono"
        defaultAgent = Agent(rawValue: defaults.string(forKey: Key.defaultAgent) ?? "") ?? .claude
        theme = ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        claudePath = defaults.string(forKey: Key.claudePath) ?? SettingsStore.autodetect("claude")
        codexPath = defaults.string(forKey: Key.codexPath) ?? SettingsStore.autodetect("codex")
        claudeExtraArgs = defaults.string(forKey: Key.claudeExtraArgs) ?? "--dangerously-skip-permissions"
        codexExtraArgs = defaults.string(forKey: Key.codexExtraArgs) ?? "--dangerously-bypass-approvals-and-sandbox"
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(fontFamily, forKey: Key.fontFamily)
        defaults.set(defaultAgent.rawValue, forKey: Key.defaultAgent)
        defaults.set(theme.rawValue, forKey: Key.theme)
        defaults.set(claudePath, forKey: Key.claudePath)
        defaults.set(codexPath, forKey: Key.codexPath)
        defaults.set(claudeExtraArgs, forKey: Key.claudeExtraArgs)
        defaults.set(codexExtraArgs, forKey: Key.codexExtraArgs)
    }

    /// Build a `TerminalAppearance` (U9 font + U10 resolved scheme) for surfaces.
    public func appearance(scheme: TerminalAppearance.ColorScheme) -> TerminalAppearance {
        TerminalAppearance(fontSize: fontSize,
                           fontFamily: fontFamily.isEmpty ? nil : fontFamily,
                           colorScheme: scheme)
    }

    /// Extra args for an agent, whitespace-split (empty → none). Inserted
    /// right after the binary so they precede subcommands (`codex ... resume`).
    public func extraArgs(for agent: Agent) -> [String] {
        let raw = agent == .claude ? claudeExtraArgs : codexExtraArgs
        return raw.split(separator: " ").map(String.init)
    }

    /// Binary path a launcher should use for an agent (U4 uses this later).
    public func binaryPath(for agent: Agent) -> String {
        switch agent {
        case .claude: return claudePath
        case .codex: return codexPath
        }
    }

    private static func autodetect(_ bin: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(bin)",
            "/usr/local/bin/\(bin)",
            "\(NSHomeDirectory())/.local/bin/\(bin)",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return bin  // rely on PATH
    }

    private enum Key {
        static let fontSize = "temple.settings.fontSize"
        static let fontFamily = "temple.settings.fontFamily"
        static let defaultAgent = "temple.settings.defaultAgent"
        static let theme = "temple.settings.theme"
        static let claudePath = "temple.settings.claudePath"
        static let codexPath = "temple.settings.codexPath"
        static let claudeExtraArgs = "temple.settings.claudeExtraArgs"
        static let codexExtraArgs = "temple.settings.codexExtraArgs"
    }
}
