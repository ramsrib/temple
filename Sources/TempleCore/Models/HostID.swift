import Foundation

/// A session's host. The empty raw value names this Mac.
public struct HostID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public static let local = HostID(rawValue: "")

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isLocal: Bool { self == .local }
}

public extension HostID {
    /// How a host is named in the interface: "this Mac" for the local host.
    var displayName: String { isLocal ? "this Mac" : rawValue }
}
