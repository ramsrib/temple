import AppKit

/// T7: locate libghostty's runtime resources (terminfo, shell integration,
/// themes) and export `GHOSTTY_RESOURCES_DIR` before the first surface spawns.
///
/// Priority: explicit env → app bundle (`Contents/Resources/ghostty`, produced
/// by `Scripts/build-app.sh`) → a dev checkout root passed by the entry point
/// (`Vendor/ghostty/zig-out/share/ghostty`, produced by
/// `Scripts/build-ghostty.sh`).
public enum GhosttyResources {
    @discardableResult
    public static func configure(devCheckoutRoot: URL? = nil) -> String? {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return existing
        }
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
            candidates.append(bundled)
        }
        if let devCheckoutRoot {
            candidates.append(devCheckoutRoot.appendingPathComponent("Vendor/ghostty/zig-out/share/ghostty"))
        }
        for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
            setenv("GHOSTTY_RESOURCES_DIR", dir.path, 1)
            return dir.path
        }
        TempleTerminalLog.logger.error("no ghostty resources dir found; terminfo/shell-integration may be degraded")
        return nil
    }
}
