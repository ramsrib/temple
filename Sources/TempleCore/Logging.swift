import os

enum TempleCoreLog {
    static let watcher = Logger(subsystem: "com.sriramb.temple.core", category: "watcher")
    static let cache = Logger(subsystem: "com.sriramb.temple.core", category: "cache")
    static let env = Logger(subsystem: "com.sriramb.temple.core", category: "env")
}
