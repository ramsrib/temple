import Foundation
import TempleTerminalAPI

/// What a shell in Temple sees when it asks which terminal it is in.
///
/// libghostty sets `TERM_PROGRAM=ghostty` (and its own version) for every PTY
/// it spawns, so anything reading it — an agent deciding which app to grant
/// Full Disk Access, a prompt theme — named the wrong app. libghostty applies
/// the surface config's environment last ("override any others"), so these
/// win. `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_BIN_DIR` and `TERM=xterm-ghostty`
/// are deliberately left alone: shell integration and the terminfo depend on
/// them, and the surface config can only add variables, never remove them.
enum TerminalIdentity {
    static let programName = "Temple"

    static var environment: [String: String] {
        ["TERM_PROGRAM": programName, "TERM_PROGRAM_VERSION": version]
    }

    /// The command as it is spawned: the identity filled in, the command's
    /// own variables left alone.
    static func apply(to command: TerminalCommand) -> TerminalCommand {
        var spawn = command
        spawn.env.merge(environment) { own, _ in own }
        return spawn
    }

    /// The bundle's marketing version. A bare SwiftPM binary (`make demo`,
    /// tests) has none; `0.0.0` is what the app build script falls back to.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
