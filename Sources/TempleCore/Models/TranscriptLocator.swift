import Foundation

/// A transcript path on its owning host; only local paths can become file URLs.
///
/// Equal and hashed by `String`, so under Unicode canonical equivalence:
/// two spellings of one path that differ only in normalization are one
/// locator. That is what the local stores need (APFS folds the two into one
/// file, and an event's spelling must still find its member), and it is
/// kept for remote hosts by decision (ADR-036): the remote module compares
/// its own paths by bytes (`RemotePath`), a locator's `path` keeps the bytes
/// it was made from, and identity verification decides which file is a
/// session's. Don't make this byte-exact without reading that decision.
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
