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
