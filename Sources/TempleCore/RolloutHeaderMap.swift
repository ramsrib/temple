import Foundation

/// A rebuildable identity hint, never membership authority. Queue-confined by
/// SessionWatcher. Negative entries represent readable non-session headers only.
final class RolloutHeaderMap {
    static var defaultURL: URL { TempleState.directory.appendingPathComponent("rollout-headers.json") }
    private struct Entry: Codable {
        let signature: FileSignature
        let payloadID: String?
    }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [String: Entry]
    }
    private static let schemaVersion = 1
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var dirty = false

    init(url: URL) {
        self.url = url
        // Missing, corrupt, and incompatible maps all rebuild from real headers.
        if let data = try? Data(contentsOf: url),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.schemaVersion == Self.schemaVersion,
           envelope.entries.allSatisfy({ path, entry in
               path.hasPrefix("/") && entry.signature.size >= 0 &&
                   entry.signature.date.timeIntervalSince1970.isFinite && entry.payloadID != ""
           }) {
            entries = envelope.entries
        }
    }

    func payloadID(at file: URL, store: any IncrementalSessionStore) throws -> String? {
        let path = SessionPaths.normalized(file.path)
        let signature = try FileSignature(file)
        if let entry = entries[path], entry.signature == signature { return entry.payloadID }
        // Store under the PRE-read signature, as with member transcript parses.
        let id = try store.metadataSessionID(at: file)
        guard try FileSignature(file) == signature else { throw CocoaError(.fileReadUnknown) }
        entries[path] = Entry(signature: signature, payloadID: id)
        dirty = true
        return id
    }

    func save(retaining paths: Set<String>) {
        let retained = entries.filter { paths.contains($0.key) }
        if retained.count != entries.count { entries = retained; dirty = true }
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Envelope(schemaVersion: Self.schemaVersion, entries: entries))
                .write(to: url, options: .atomic)
            dirty = false
        } catch {
            TempleCoreLog.cache.error("failed to save rollout header map: \(String(describing: error), privacy: .public)")
        }
    }
}
