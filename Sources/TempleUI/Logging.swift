import os

enum TempleUILog {
    static let lifecycle = Logger(subsystem: "com.sriramb.temple.app", category: "lifecycle")
    static let launch = Logger(subsystem: "com.sriramb.temple.app", category: "launch")
    static let db = Logger(subsystem: "com.sriramb.temple.app", category: "db")
    static let reconcile = Logger(subsystem: "com.sriramb.temple.app", category: "reconcile")
    static let notifications = Logger(subsystem: "com.sriramb.temple.app", category: "notifications")
    static let drag = Logger(subsystem: "com.sriramb.temple.app", category: "drag")
}
