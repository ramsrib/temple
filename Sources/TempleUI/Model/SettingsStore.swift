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
/// **A stored setting is a decision the user made.** Nothing Temple computes —
/// a detected binary, a resolved font, a default we inferred — is ever written
/// here. Store a guess next to a choice and they become the same bytes: later you
/// can't revisit the guess without risking someone's decision, and you're reduced
/// to migrations that try to divine your own past intent. That's the bug that made
/// Temple launch a stale `claude` (it persisted its own auto-detected path into
/// the very key an override lives in), and the reason detection now lives in
/// `ToolchainModel` and is recomputed every launch rather than saved.
///
/// The corollary, which the types enforce: **absent means undecided**, not
/// "unknown". An empty `claudePath` isn't missing data to be backfilled — it is
/// the user saying "you pick".
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var fontSize: Double { didSet { write(fontSize, Key.fontSize) } }
    @Published public var fontFamily: String { didSet { write(fontFamily, Key.fontFamily) } }
    @Published public var defaultAgent: Agent { didSet { write(defaultAgent.rawValue, Key.defaultAgent) } }
    @Published public var theme: ThemePreference { didSet { write(theme.rawValue, Key.theme) } }
    /// Empty = "detect it" (see `ToolchainModel`). Only ever set by the user.
    @Published public var claudePath: String { didSet { write(claudePath, Key.claudePath) } }
    @Published public var codexPath: String { didSet { write(codexPath, Key.codexPath) } }
    /// Extra CLI arguments appended to every launch (new + resume).
    @Published public var claudeExtraArgs: String { didSet { write(claudeExtraArgs, Key.claudeExtraArgs) } }
    @Published public var codexExtraArgs: String { didSet { write(codexExtraArgs, Key.codexExtraArgs) } }

    private let defaults: UserDefaults
    private var loading = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 14
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? "SF Mono"
        defaultAgent = Agent(rawValue: defaults.string(forKey: Key.defaultAgent) ?? "") ?? .claude
        theme = ThemePreference(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        codexPath = defaults.string(forKey: Key.codexPath) ?? ""
        claudeExtraArgs = defaults.string(forKey: Key.claudeExtraArgs) ?? "--dangerously-skip-permissions"
        codexExtraArgs = defaults.string(forKey: Key.codexExtraArgs) ?? "--dangerously-bypass-approvals-and-sandbox"
        loading = false
    }

    /// One setting, one key. The old `persist()` rewrote *every* key on *any*
    /// change, which is how an in-memory default (Temple's own guess at a binary
    /// path) laundered itself into persisted user data the first time someone
    /// dragged the font-size slider.
    private func write(_ value: Any, _ key: String) {
        guard !loading else { return }
        defaults.set(value, forKey: key)
    }

    /// Build a `TerminalAppearance` (U9 font + U10 resolved scheme) for surfaces.
    public func appearance(scheme: TerminalAppearance.ColorScheme) -> TerminalAppearance {
        TerminalAppearance(fontSize: fontSize,
                           fontFamily: fontFamily.isEmpty ? nil : fontFamily,
                           colorScheme: scheme)
    }

    /// Extra args for an agent, tokenized as a shell would (empty → none).
    /// Inserted right after the binary so they precede subcommands
    /// (`codex ... resume`).
    public func extraArgs(for agent: Agent) -> [String] {
        ShellWords.split(extraArgsText(for: agent))
    }

    /// The user's explicit choice of binary for an agent, or `""` for "detect it"
    /// — which is the default, and what `ToolchainModel` then answers.
    public func overridePath(for agent: Agent) -> String {
        agent == .claude ? claudePath : codexPath
    }

    public func setOverridePath(_ path: String, for agent: Agent) {
        switch agent {
        case .claude: claudePath = path
        case .codex: codexPath = path
        }
    }

    public func extraArgsText(for agent: Agent) -> String {
        agent == .claude ? claudeExtraArgs : codexExtraArgs
    }

    public func setExtraArgsText(_ text: String, for agent: Agent) {
        switch agent {
        case .claude: claudeExtraArgs = text
        case .codex: codexExtraArgs = text
        }
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
