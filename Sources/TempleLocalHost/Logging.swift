import os

/// Same subsystem and category the source logged under while it lived in
/// TempleCore, so `log stream` filters keep working across the move.
enum LocalHostLog {
    static let watcher = Logger(subsystem: "com.sriramb.temple.core", category: "watcher")
}
