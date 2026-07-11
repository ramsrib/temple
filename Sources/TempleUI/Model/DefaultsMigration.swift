import Foundation

/// Migrates settings from Temple's legacy bundle-identifier defaults domain.
public enum DefaultsMigration {
    public static let sentinelKey = "temple.migratedFromDevTempleDomain"
    public static let legacyBundleID = "dev.temple.Temple"

    /// Copies the legacy values once, then records completion in the target.
    public static func migrateIfNeeded(source: [String: Any], target: UserDefaults) {
        guard target.object(forKey: sentinelKey) == nil else { return }
        for (key, value) in source {
            target.set(value, forKey: key)
        }
        target.set(true, forKey: sentinelKey)
    }

    /// Migrates the legacy on-disk domain into the current app domain.
    public static func migrateStandardDomainIfNeeded() {
        let legacy = UserDefaults.standard.persistentDomain(forName: legacyBundleID) ?? [:]
        migrateIfNeeded(source: legacy, target: .standard)
    }
}
