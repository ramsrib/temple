import Foundation

/// A transcript path on its owning host; only local paths can become file URLs.
public struct TranscriptLocator: Hashable, Sendable {
    public let host: HostID
    public let path: String
    private let originalLocalURL: URL?

    public init(host: HostID, path: String) {
        self.host = host
        self.path = path
        self.originalLocalURL = nil
    }

    /// Retains the supplied URL, including a relative URL's base, for legacy callers.
    public init(localURL: URL) {
        precondition(localURL.isFileURL)
        self.host = .local
        self.path = localURL.path
        self.originalLocalURL = localURL
    }

    public var localURL: URL? {
        host.isLocal ? originalLocalURL ?? URL(fileURLWithPath: path) : nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host && lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(path)
    }
}
