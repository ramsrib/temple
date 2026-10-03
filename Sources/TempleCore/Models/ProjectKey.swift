import Foundation

/// A working directory on one host, without resolving or normalizing its path.
public struct ProjectKey: Hashable, Codable, Sendable {
    public let host: HostID
    public let path: String

    public init(host: HostID, path: String) {
        self.host = host
        self.path = path
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var displayName: String { host.isLocal ? name : "\(name) @\(host.rawValue)" }
}
