import os

/// `log stream --predicate 'subsystem == "com.sriramb.temple.remote"'`.
enum RemoteHostLog {
    static let ssh = Logger(subsystem: "com.sriramb.temple.remote", category: "ssh")
    static let test = Logger(subsystem: "com.sriramb.temple.remote", category: "test")
}
