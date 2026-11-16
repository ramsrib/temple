import Foundation

/// A working directory on one host, without resolving or normalizing its path.
public struct ProjectKey: Hashable, Codable, Sendable {
    public let host: HostID
    public let path: String

    public init(host: HostID, path: String) {
        self.host = host
        self.path = path
    }

    /// The folder's name, from the path's text. Not `URL(fileURLWithPath:)`:
    /// that asks the disk whether the path is a folder (an lstat), this is
    /// read by every project heading and label on every redraw, and a
    /// host's path is not on this Mac's disk to ask about.
    public var name: String { (path as NSString).lastPathComponent }
    public var displayName: String { host.isLocal ? name : "\(name) @\(host.rawValue)" }
}
